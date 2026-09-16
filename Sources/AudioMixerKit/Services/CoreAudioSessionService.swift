import Combine
import CoreAudio
import AudioToolbox
import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

/// Real Core Audio backend for `AudioSessionProviding`, built on the public Process Tap API
/// (macOS 14.4+, research.md §1). Not unit-tested — real hardware/permission dialogs aren't
/// practical to simulate — validated manually via quickstart.md instead.
///
/// KNOWN LIMITATION: mute is real (see `LiveMutePipeline` below), but there is still no public
/// API for continuous per-process gain — only "silent" (muted) vs. "audible" (unmuted). True
/// continuous scaling would require the IOProc below to actually read the tap's captured samples,
/// scale them, and write them into `outOutputData` instead of leaving it silent. That's the next
/// step (and a good Obsidian mini-course topic).
public final class CoreAudioSessionService: AudioSessionProviding {
    /// The tap + private Aggregate Device + running IOProc that make a mute actually audible.
    /// Manual testing (2026-09-16) confirmed a `CATapDescription.muteBehavior` has NO audible
    /// effect until the tap is part of a live IO cycle — Core Audio only enforces it once the
    /// tap is actually running inside an Aggregate Device.
    private struct LiveMutePipeline {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    /// The live mute pipeline per session identity — only exists while that session is actually
    /// muted; unmuted sessions need no pipeline at all (natural passthrough).
    private var livePipelines: [String: LiveMutePipeline] = [:]
    /// Real Core Audio process object IDs currently grouped under each session identity (T034) —
    /// what the mute pipeline must tap, instead of an empty process list.
    private var processObjectIDsByIdentity: [String: [AudioObjectID]] = [:]
    /// Whether a tap could actually be created for an identity's processes, probed once per new
    /// identity (T036) — the closest real signal to "Core Audio reports no tappable stream"
    /// (FR-011), since there is no direct query property for it.
    private var tappabilityByIdentity: [String: Bool] = [:]

    public var permissionState: AnyPublisher<PermissionState, Never> {
        permissionSubject.eraseToAnyPublisher()
    }

    public var sessions: AnyPublisher<[ControllableAudioSession], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    public init() {}

    deinit {
        pollTimer?.invalidate()
        if #available(macOS 14.4, *) {
            for identity in livePipelines.keys {
                Self.tearDown(livePipelines[identity])
            }
        }
    }

    // MARK: - Permission (FR-010)

    public func requestPermission() {
        guard permissionSubject.value == .notDetermined else { return }
        guard #available(macOS 14.4, *) else {
            permissionSubject.value = .denied
            return
        }

        // Probing with a harmless, immediately-destroyed global tap is the documented way to
        // trigger (and observe the result of) the system's Process Tap permission prompt, since
        // there is no dedicated "request access" API for this capability.
        let probe = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(probe, &tapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            permissionSubject.value = .granted
            startPolling()
        } else {
            permissionSubject.value = .denied
        }
    }

    // MARK: - Discovery (FR-002, FR-005)

    private func startPolling() {
        pollTimer?.invalidate()
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refresh() {
        let processes = Self.fetchAudioProcesses()

        // Track each identity's real process object IDs (T034) so applyMuteBehavior can tap the
        // right processes instead of an empty list.
        var objectIDsByIdentity: [String: [AudioObjectID]] = [:]
        for process in processes {
            objectIDsByIdentity[AudioProcessGrouping.identity(for: process), default: []].append(process.processObjectID)
        }
        processObjectIDsByIdentity = objectIDsByIdentity

        let existingByIdentity = Dictionary(
            uniqueKeysWithValues: sessionsSubject.value.map { ($0.bundleIdentifier, $0) }
        )
        var grouped = AudioProcessGrouping.group(processes: processes, existing: existingByIdentity)

        // Refine isControllable with a real tappability probe (T036, FR-011) rather than only
        // "does this process have a bundle identifier" — probed once per identity, cached, since
        // repeatedly creating/destroying taps every poll cycle would be wasteful.
        for index in grouped.indices {
            let identity = grouped[index].bundleIdentifier
            guard grouped[index].isControllable else { continue }
            if tappabilityByIdentity[identity] == nil {
                tappabilityByIdentity[identity] = Self.probeTappability(objectIDsByIdentity[identity] ?? [])
            }
            grouped[index].isControllable = tappabilityByIdentity[identity] ?? false
        }

        sessionsSubject.value = graceBuffer.apply(grouped)
    }

    private static func fetchAudioProcesses() -> [RawAudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return []
        }

        return processIDs.compactMap { processObjectID -> RawAudioProcess? in
            guard Self.boolProperty(processObjectID, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let pid = Self.pidProperty(processObjectID, kAudioProcessPropertyPID)
            let rawBundleID = Self.stringProperty(processObjectID, kAudioProcessPropertyBundleID)
            // Multi-process apps (e.g. Chrome) report a DIFFERENT bundle ID per helper process
            // (confirmed via manual testing: "Google Chrome Helper" showed up as its own row,
            // separate from Chrome). Walk the process tree to find the actual owning application
            // so FR-002's "one row per app" grouping holds for these helpers too.
            let ownerBundleID = Self.ownerApplicationBundleIdentifier(forPID: pid) ?? rawBundleID
            let displayName = ownerBundleID.flatMap(Self.applicationName(forBundleIdentifier:))
                ?? Self.friendlyFallbackName(fromBundleIdentifier: rawBundleID, processID: pid)
            return RawAudioProcess(
                processObjectID: processObjectID,
                processID: pid,
                bundleIdentifier: ownerBundleID,
                processName: displayName,
                displayName: displayName
            )
        }
    }

    /// Attempts a real, immediately-destroyed tap on the given processes — the closest available
    /// signal to "is this actually tappable" (FR-011), since Core Audio has no direct query
    /// property for it.
    private static func probeTappability(_ objectIDs: [AudioObjectID]) -> Bool {
        guard #available(macOS 14.4, *), !objectIDs.isEmpty else { return false }
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return false }
        AudioHardwareDestroyProcessTap(tapID)
        return true
    }

    /// A readable fallback when no app bundle can be resolved at all (e.g. system helper
    /// processes like `com.apple.WebKit.GPU`) — the last one or two bundle ID components read
    /// better than the raw reverse-DNS string.
    private static func friendlyFallbackName(fromBundleIdentifier bundleID: String?, processID: pid_t) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "pid:\(processID)" }
        let tail = bundleID.split(separator: ".").suffix(2).joined(separator: " ")
        return tail.isEmpty ? bundleID : tail
    }

    #if canImport(AppKit)
    /// Walks the process tree from `pid` up to the first ancestor that `NSWorkspace` recognizes
    /// as a running application, returning its bundle identifier. Handles multi-process apps
    /// (Chrome, Electron apps, etc.) whose helper processes report their own bundle ID to Core
    /// Audio instead of their parent app's.
    private static func ownerApplicationBundleIdentifier(forPID pid: pid_t) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        var currentPID = pid
        var visited = Set<pid_t>()
        for _ in 0..<10 {
            if let app = runningApps.first(where: { $0.processIdentifier == currentPID }) {
                return app.bundleIdentifier
            }
            guard visited.insert(currentPID).inserted,
                  let parentPID = Self.parentProcessID(of: currentPID),
                  parentPID > 1, parentPID != currentPID
            else { break }
            currentPID = parentPID
        }
        return nil
    }

    private static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
    #else
    private static func ownerApplicationBundleIdentifier(forPID pid: pid_t) -> String? { nil }
    #endif

    #if canImport(AppKit)
    private static func applicationName(forBundleIdentifier bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// FR-002: the icon shown per row. `nil` falls back to the generic placeholder (Edge Cases).
    private static func applicationIcon(forBundleIdentifier bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    #else
    private static func applicationName(forBundleIdentifier bundleID: String) -> String? { nil }
    #endif

    private static func boolProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func pidProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    // MARK: - Control (FR-003/FR-004 — see KNOWN LIMITATION above)

    public func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setVolume(\(volume), \(id)): no controllable session found, ignoring")
            return
        }
        session.setVolume(volume)
        applyMuteBehavior(session.isMuted, forIdentity: id)
        publish(session)
    }

    public func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setMuted(\(isMuted), \(id)): no controllable session found, ignoring")
            return
        }
        session.setMuted(isMuted)
        applyMuteBehavior(session.isMuted, forIdentity: id)
        publish(session)
    }

    private func publish(_ session: ControllableAudioSession) {
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.bundleIdentifier == session.bundleIdentifier }) else { return }
        current[index] = session
        #if canImport(AppKit)
        if current[index].icon == nil {
            current[index].icon = Self.applicationIcon(forBundleIdentifier: session.bundleIdentifier)
        }
        #endif
        sessionsSubject.value = current
    }

    private func applyMuteBehavior(_ muted: Bool, forIdentity identity: String) {
        guard #available(macOS 14.4, *) else { return }

        guard muted else {
            // Unmuted = natural passthrough; no live pipeline needed at all.
            if let pipeline = livePipelines.removeValue(forKey: identity) {
                Self.tearDown(pipeline)
                print("[AudioMixer] \(identity): unmuted, live pipeline torn down")
            }
            return
        }

        // Already muted live — avoid rebuilding on every redundant call (e.g. repeated setVolume(0)).
        guard livePipelines[identity] == nil else { return }

        let objectIDs = processObjectIDsByIdentity[identity] ?? []
        guard !identity.hasPrefix("process:"), !objectIDs.isEmpty else {
            print("[AudioMixer] \(identity): no process object IDs known — skipping mute pipeline")
            return
        }

        guard let pipeline = Self.startLiveMutePipeline(forIdentity: identity, objectIDs: objectIDs) else { return }
        livePipelines[identity] = pipeline
        print("[AudioMixer] \(identity): live mute pipeline started (tap \(pipeline.tapID), aggregate \(pipeline.aggregateDeviceID))")
    }

    /// Builds a tap, wraps it in a private Aggregate Device, and starts a no-op `AudioDeviceIOProc`
    /// on it — the minimum needed for Core Audio to actually enforce `CATapMuted` (see class doc).
    @available(macOS 14.4, *)
    private static func startLiveMutePipeline(forIdentity identity: String, objectIDs: [AudioObjectID]) -> LiveMutePipeline? {
        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            print("[AudioMixer] \(identity): AudioHardwareCreateProcessTap failed")
            return nil
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioMixer-\(identity)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString]
            ]
        ]

        var aggregateDeviceID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID) == noErr else {
            print("[AudioMixer] \(identity): AudioHardwareCreateAggregateDevice failed")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, _, _, _, _ in
            // No-op: merely running IO is what makes Core Audio enforce this tap's muteBehavior.
        }
        guard ioStatus == noErr, let ioProcID else {
            print("[AudioMixer] \(identity): AudioDeviceCreateIOProcIDWithBlock failed, status=\(ioStatus)")
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            print("[AudioMixer] \(identity): AudioDeviceStart failed, status=\(startStatus)")
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        return LiveMutePipeline(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID)
    }

    @available(macOS 14.4, *)
    private static func tearDown(_ pipeline: LiveMutePipeline?) {
        guard let pipeline else { return }
        AudioDeviceStop(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioDeviceDestroyIOProcID(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioHardwareDestroyAggregateDevice(pipeline.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(pipeline.tapID)
    }
}
