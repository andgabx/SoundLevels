import CoreAudio
import AudioToolbox
import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

enum AudioProcessDiscovery {
    static func fetchAudioProcesses() -> [RawAudioProcess] {
        var address = AudioObjectPropertyReading.address(kAudioHardwarePropertyProcessObjectList)

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
            guard pid != ownPID else { return nil }
            let rawBundleID = AudioObjectPropertyReading.stringProperty(processObjectID, kAudioProcessPropertyBundleID)
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

    static func friendlyFallbackName(fromBundleIdentifier bundleID: String?, processID: pid_t) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "pid:\(processID)" }
        let tail = bundleID.split(separator: ".").suffix(2).joined(separator: " ")
        return tail.isEmpty ? bundleID : tail
    }

    static func appBundlePath(fromExecutablePath path: String) -> String? {
        guard let appMarkerRange = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<appMarkerRange.upperBound].dropLast())
    }

    #if canImport(AppKit)
    private static func ownerApplicationBundleIdentifier(forPID pid: pid_t) -> String? {
        if let bundleID = Self.enclosingAppBundleIdentifier(forPID: pid) {
            return bundleID
        }

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
    private static var applicationNameCache: [String: String] = [:]
    private static var applicationIconCache: [String: NSImage] = [:]

    private static func applicationName(forBundleIdentifier bundleID: String) -> String? {
        if let cached = applicationNameCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        applicationNameCache[bundleID] = name
        return name
    }

    static func applicationIcon(forBundleIdentifier bundleID: String) -> NSImage? {
        if let cached = applicationIconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        applicationIconCache[bundleID] = icon
        return icon
    }
    #else
    private static func applicationName(forBundleIdentifier bundleID: String) -> String? { nil }
    #endif
}
