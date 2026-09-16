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
public final class CoreAudioSessionService: AudioSessionProviding {
    /// The tap + private Aggregate Device (tap + real output sub-device) + running IOProc that
    /// makes both mute AND continuous volume audible. Manual testing (2026-09-16) confirmed
    /// `CATapDescription.muteBehavior` alone has NO audible effect until the tap is part of a
    /// live IO cycle — Core Audio only enforces it once the tap is actually running inside an
    /// Aggregate Device. To get continuous gain (not just mute), the tap is always set `.muted`
    /// once this pipeline exists (stopping the app's direct passthrough to hardware entirely),
    /// and the IOProc itself reads the tap's captured samples, scales them by `box.volume`
    /// (silence if `box.isMuted`), and writes the result to the real output device included in
    /// the same aggregate — making this pipeline the sole path by which that app's audio reaches
    /// the speakers while it's active.
    private final class VolumeBox {
        var volume: Double
        var isMuted: Bool
        init(volume: Double, isMuted: Bool) {
            self.volume = volume
            self.isMuted = isMuted
        }
    }

    private struct LiveControlPipeline {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let box: VolumeBox
    }

    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    /// The live mute pipeline per session identity — only exists while that session is actually
    /// muted; unmuted sessions need no pipeline at all (natural passthrough).
    private var livePipelines: [String: LiveControlPipeline] = [:]
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

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return processIDs.compactMap { processObjectID -> RawAudioProcess? in
            guard Self.boolProperty(processObjectID, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let pid = Self.pidProperty(processObjectID, kAudioProcessPropertyPID)
            // AudioMixer's own live control pipelines run real output IO (that's what makes
            // mute/volume audible), which makes Core Audio report AudioMixer itself as "currently
            // producing audio" — confirmed via manual testing (it showed up as its own row).
            // Never list ourselves.
            guard pid != ownPID else { return nil }
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

    // MARK: - Control (FR-003/FR-004)

    public func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setVolume(\(volume), \(id)): no controllable session found, ignoring")
            return
        }
        session.setVolume(volume)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        publish(session)
    }

    public func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setMuted(\(isMuted), \(id)): no controllable session found, ignoring")
            return
        }
        session.setMuted(isMuted)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
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

    /// Routes an app's audio through our own live pipeline whenever it needs anything other than
    /// its natural, unmodified volume — silence if muted, `volume`-scaled samples otherwise.
    /// Tears the pipeline down entirely once back at natural (unmuted, volume 1.0) so an
    /// untouched app's audio needs no interception at all.
    private func applyControl(volume: Double, isMuted: Bool, forIdentity identity: String) {
        guard #available(macOS 14.4, *) else { return }

        let needsPipeline = isMuted || volume < 1.0
        guard needsPipeline else {
            if let pipeline = livePipelines.removeValue(forKey: identity) {
                Self.tearDown(pipeline)
                print("[AudioMixer] \(identity): back to natural volume, live pipeline torn down")
            }
            return
        }

        if let existing = livePipelines[identity] {
            existing.box.volume = volume
            existing.box.isMuted = isMuted
            return
        }

        let objectIDs = processObjectIDsByIdentity[identity] ?? []
        guard !identity.hasPrefix("process:"), !objectIDs.isEmpty else {
            print("[AudioMixer] \(identity): no process object IDs known — skipping control pipeline")
            return
        }

        guard let pipeline = Self.startLiveControlPipeline(
            forIdentity: identity,
            objectIDs: objectIDs,
            initialVolume: volume,
            initialMuted: isMuted
        ) else { return }
        livePipelines[identity] = pipeline
        print("[AudioMixer] \(identity): live control pipeline started (tap \(pipeline.tapID), aggregate \(pipeline.aggregateDeviceID))")
    }

    /// Builds a tap (always `.muted`, since this pipeline becomes the sole path to the speakers
    /// once it exists), wraps it in a private Aggregate Device alongside the real default output
    /// device, and starts an `AudioDeviceIOProc` that scales the tap's captured samples by
    /// `box.volume` and writes them to that real device — this is what makes both mute AND
    /// continuous volume audible (see class doc).
    @available(macOS 14.4, *)
    private static func startLiveControlPipeline(
        forIdentity identity: String,
        objectIDs: [AudioObjectID],
        initialVolume: Double,
        initialMuted: Bool
    ) -> LiveControlPipeline? {
        guard let outputDeviceUID = Self.defaultOutputDeviceUID() else {
            print("[AudioMixer] \(identity): couldn't resolve the default output device UID")
            return nil
        }

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
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
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

        // Defensive: only attempt sample-accurate scaling if the tap's format is exactly what we
        // expect (Linear PCM, Float32). If it's anything else, fall back to silence rather than
        // risk writing garbage/loud noise from a misinterpreted buffer.
        let tapFormat = Self.tapStreamFormat(tapID)
        let canScaleSamples = tapFormat?.mFormatID == kAudioFormatLinearPCM
            && (tapFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
            && tapFormat?.mBitsPerChannel == 32
        if !canScaleSamples {
            print("[AudioMixer] \(identity): tap format isn't Float32 PCM (\(String(describing: tapFormat))) — muting only, no gain scaling")
        }

        let box = VolumeBox(volume: initialVolume, isMuted: initialMuted)

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, outOutputData, _ in
            guard canScaleSamples else { return }
            let muted = box.isMuted
            let gain = Float(max(0.0, min(1.0, box.volume)))
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            for i in 0..<min(inputBuffers.count, outputBuffers.count) {
                guard let inData = inputBuffers[i].mData, let outData = outputBuffers[i].mData else { continue }
                let sampleCount = min(inputBuffers[i].mDataByteSize, outputBuffers[i].mDataByteSize) / 4
                let input = inData.assumingMemoryBound(to: Float.self)
                let output = outData.assumingMemoryBound(to: Float.self)
                for sample in 0..<Int(sampleCount) {
                    output[sample] = muted ? 0 : input[sample] * gain
                }
            }
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

        return LiveControlPipeline(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID, box: box)
    }

    @available(macOS 14.4, *)
    private static func tearDown(_ pipeline: LiveControlPipeline?) {
        guard let pipeline else { return }
        AudioDeviceStop(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioDeviceDestroyIOProcID(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioHardwareDestroyAggregateDevice(pipeline.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(pipeline.tapID)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return Self.stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}
