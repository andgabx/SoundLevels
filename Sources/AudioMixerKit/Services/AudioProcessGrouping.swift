import Foundation

/// One audio-producing process as reported by the real Core Audio backend, before grouping.
public struct RawAudioProcess {
    /// The Core Audio object ID for this process — needed to build a real tap (see
    /// `CoreAudioSessionService`). `0` for processes that only exist in tests/fakes.
    public let processObjectID: UInt32
    public let processID: Int32
    /// `nil` when Core Audio can't resolve an owning application bundle for this process.
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

/// Groups raw per-process audio info into one `ControllableAudioSession` per application
/// (FR-002). Processes with no resolvable bundle identifier fall back to a synthetic session
/// keyed by process name, shown as an uncontrollable row rather than excluded (FR-011, spec
/// Assumptions) — this satisfies SC-004's "every audio-producing app appears" guarantee.
public enum AudioProcessGrouping {
    /// The identity key a process groups under: its bundle identifier, or a synthetic
    /// process-name-keyed identity when none is resolvable. Shared with `CoreAudioSessionService`
    /// so it can map the same identity back to real Core Audio process object IDs.
    public static func identity(for process: RawAudioProcess) -> String {
        process.bundleIdentifier ?? syntheticIdentity(forProcessName: process.processName)
    }

    /// - Parameter existing: Previously known sessions, keyed by identity, so volume/mute state
    ///   already in progress isn't reset when the same application is regrouped.
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
            if var known = existing[identity] {
                known.lastSeenAt = Date()
                return known
            }
            let displayName = representative.displayName ?? representative.processName
            return ControllableAudioSession(
                bundleIdentifier: identity,
                displayName: displayName,
                isControllable: representative.bundleIdentifier != nil
            )
        }

        // Dictionary iteration order is not stable across calls — without sorting, the popover's
        // row order would visibly shuffle on every poll cycle even when nothing changed.
        return sessions.sorted { lhs, rhs in
            lhs.displayName == rhs.displayName
                ? lhs.bundleIdentifier < rhs.bundleIdentifier
                : lhs.displayName < rhs.displayName
        }
    }

    static func syntheticIdentity(forProcessName processName: String) -> String {
        "process:\(processName)"
    }
}
