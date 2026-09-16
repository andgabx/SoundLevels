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
/// KNOWN LIMITATION (confirmed via manual testing 2026-09-16): `setVolume`/`setMuted` only build a
/// `CATapDescription` with the desired `CATapMuteBehavior` — they never attach that tap to a
/// running Aggregate Device / `AudioDeviceIOProc`. Manual testing confirmed a tap that is never
/// actually pulled into a live IO cycle does NOT audibly mute the target process — Core Audio
/// appears to only enforce mute/gain on taps that are part of an active audio graph. Continuous
/// volume AND real mute both need the same fix: build an Aggregate Device around the tap, start
/// real IO on it (even if just to discard/re-mix the samples), and keep it running for as long as
/// the app should be controllable. This is the top candidate for your next hands-on Core Audio
/// session (and a good Obsidian mini-course topic).
public final class CoreAudioSessionService: AudioSessionProviding {
    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    /// AudioObjectID of the live mute/unmute tap per session identity, so it can be destroyed
    /// when no longer needed or when the session disappears.
    private var activeTaps: [String: AudioObjectID] = [:]
    /// Real Core Audio process object IDs currently grouped under each session identity (T034) —
    /// what `applyMuteBehavior` must tap, instead of an empty process list.
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
            for tapID in activeTaps.values {
                AudioHardwareDestroyProcessTap(tapID)
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
        // Best-effort: recreate the tap with the desired mute behavior. A production version
        // should keep the tap alive and update `muteBehavior` in place instead of recreating it
        // on every change — left as-is pending real-hardware iteration (see KNOWN LIMITATION).
        if let existingTap = activeTaps[identity] {
            AudioHardwareDestroyProcessTap(existingTap)
            activeTaps[identity] = nil
        }
        // T034: tap the identity's real process object IDs, not an empty list. Synthetic
        // (process-name-fallback) identities and identities with no known processes can't be
        // tapped for real.
        let objectIDs = processObjectIDsByIdentity[identity] ?? []
        guard !identity.hasPrefix("process:"), !objectIDs.isEmpty else {
            print("[AudioMixer] applyMuteBehavior(\(muted), \(identity)): no process object IDs known — skipping tap")
            return
        }

        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.muteBehavior = muted ? .muted : .unmuted
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        if status == noErr {
            activeTaps[identity] = tapID
            print("[AudioMixer] applyMuteBehavior(\(muted), \(identity)): tap \(tapID) created for objectIDs \(objectIDs)")
        } else {
            print("[AudioMixer] applyMuteBehavior(\(muted), \(identity)): AudioHardwareCreateProcessTap FAILED, status=\(status) for objectIDs \(objectIDs)")
        }
    }
}
