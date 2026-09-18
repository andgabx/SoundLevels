import Foundation

public struct RawAudioProcess {
    public let processObjectID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String?
    public let processName: String
    public let displayName: String?

    public init(
        processObjectID: UInt32 = 0,
        processID: Int32,
        bundleIdentifier: String?,
        processName: String,
        displayName: String? = nil
    ) {
        self.processObjectID = processObjectID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.displayName = displayName
    }
}

public enum AudioProcessGrouping {
    public static func identity(for process: RawAudioProcess) -> String {
        process.bundleIdentifier ?? syntheticIdentity(forProcessName: process.processName)
    }

    public static func group(
        processes: [RawAudioProcess],
        existing: [String: ControllableAudioSession] = [:]
    ) -> [ControllableAudioSession] {
        var byIdentity: [String: [RawAudioProcess]] = [:]
        for process in processes {
            byIdentity[identity(for: process), default: []].append(process)
        }

        let sessions = byIdentity.map { identity, group -> ControllableAudioSession in
            let representative = group[0]
            let displayName = representative.displayName ?? representative.processName
            if var known = existing[identity] {
                known.lastSeenAt = Date()
                known.displayName = displayName
                return known
            }
            return ControllableAudioSession(
                identity: identity,
                displayName: displayName,
                isControllable: representative.bundleIdentifier != nil
            )
        }

        return sessions.sorted()
    }

    static func syntheticIdentity(forProcessName processName: String) -> String {
        "process:\(processName)"
    }
}
