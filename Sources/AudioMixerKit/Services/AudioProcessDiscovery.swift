import CoreAudio
import AudioToolbox
import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

/// Discovers audio-producing processes via Core Audio and resolves each one back to a real
/// application (name, icon, bundle identifier) — the read-only, stateless half of talking to
/// Core Audio. Kept separate from `LiveVolumePipeline` (the stateful, write side) and from
/// `CoreAudioSessionService` (the orchestrator that owns polling/caching state).
enum AudioProcessDiscovery {
    static func fetchAudioProcesses() -> [RawAudioProcess] {
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
            guard AudioObjectPropertyReading.boolProperty(processObjectID, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let pid = AudioObjectPropertyReading.pidProperty(processObjectID, kAudioProcessPropertyPID)
            // SoundLevels's own live control pipelines run real output IO (that's what makes
            // mute/volume audible), which makes Core Audio report SoundLevels itself as "currently
            // producing audio" — confirmed via manual testing (it showed up as its own row).
            // Never list ourselves.
            guard pid != ownPID else { return nil }
            let rawBundleID = AudioObjectPropertyReading.stringProperty(processObjectID, kAudioProcessPropertyBundleID)
            // Multi-process apps (e.g. Chrome) report a DIFFERENT bundle ID per helper process
            // (confirmed via manual testing: "Google Chrome Helper" showed up as its own row,
            // separate from Chrome). Attribute it back to the owning application so FR-002's
            // "one row per app" grouping holds for these helpers too.
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
    @available(macOS 14.4, *)
    static func probeTappability(_ objectIDs: [AudioObjectID]) -> Bool {
        guard !objectIDs.isEmpty else { return false }
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return false }
        AudioHardwareDestroyProcessTap(tapID)
        return true
    }

    /// A readable fallback when no app bundle can be resolved at all (e.g. system helper
    /// processes like `com.apple.WebKit.GPU`) — the last one or two bundle ID components read
    /// better than the raw reverse-DNS string. Pure/testable — see AudioProcessDiscoveryTests.
    static func friendlyFallbackName(fromBundleIdentifier bundleID: String?, processID: pid_t) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "pid:\(processID)" }
        let tail = bundleID.split(separator: ".").suffix(2).joined(separator: " ")
        return tail.isEmpty ? bundleID : tail
    }

    /// Finds the outermost `.app` bundle containing the given executable path — the FIRST
    /// ".app/" is correct even when a helper's own nested `.app` lives inside it (e.g.
    /// "Google Chrome.app/.../Google Chrome Helper.app/..."). Pure string logic, separated from
    /// the `proc_pidpath` syscall in `enclosingAppBundleIdentifier` specifically so it's
    /// unit-testable — see AudioProcessDiscoveryTests. This exact logic caused two real bugs
    /// (Chrome Helper split into its own row; WebKit GPU unattributed) before being fixed.
    static func appBundlePath(fromExecutablePath path: String) -> String? {
        guard let appMarkerRange = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<appMarkerRange.upperBound].dropLast())
    }

    #if canImport(AppKit)
    /// Finds the application that "owns" a process, so multi-process apps group under one row
    /// (FR-002) instead of one row per helper.
    private static func ownerApplicationBundleIdentifier(forPID pid: pid_t) -> String? {
        // Primary strategy: find the .app bundle that physically contains the process's
        // executable on disk (e.g. Chrome's helpers live inside Google Chrome.app). This works
        // regardless of how the process was launched (fork/exec, like Chrome, or an XPC service
        // launched by launchd, like some system helpers) as long as it lives inside a real .app.
        if let bundleID = Self.enclosingAppBundleIdentifier(forPID: pid) {
            return bundleID
        }

        // Fallback: walk the process tree. Doesn't help XPC services launched directly by
        // launchd (their parent is launchd, not the requesting app) — confirmed via manual
        // testing with Safari's WebKit GPU process, a shared framework-level XPC service with no
        // enclosing .app of its own, which correctly stays its own row rather than being guessed.
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

    private static func enclosingAppBundleIdentifier(forPID pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        guard let appPath = Self.appBundlePath(fromExecutablePath: path) else { return nil }
        return Bundle(path: appPath)?.bundleIdentifier
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
    static func applicationIcon(forBundleIdentifier bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    #else
    private static func applicationName(forBundleIdentifier bundleID: String) -> String? { nil }
    #endif
}
