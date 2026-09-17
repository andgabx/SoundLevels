import Foundation

/// Applies the brief-pause grace period (Edge Cases; spec.md fixes this at 3 seconds) so a
/// session isn't dropped the instant a raw snapshot momentarily omits it. Kept as a small, pure,
/// unit-testable helper since `CoreAudioSessionService` itself isn't unit-tested (real hardware).
public final class SessionGracePeriodBuffer {
    public static let defaultGracePeriod: TimeInterval = 3

    private var buffered: [String: ControllableAudioSession] = [:]
    private let gracePeriod: TimeInterval
    private let now: () -> Date

    public init(gracePeriod: TimeInterval = SessionGracePeriodBuffer.defaultGracePeriod, now: @escaping () -> Date = Date.init) {
        self.gracePeriod = gracePeriod
        self.now = now
    }

    /// Merges a fresh raw snapshot with the buffer: sessions present in `incoming` get
    /// `lastSeenAt` refreshed; sessions absent from `incoming` are retained (with their last
    /// known state) until they've been missing longer than the grace period, then dropped.
    public func apply(_ incoming: [ControllableAudioSession]) -> [ControllableAudioSession] {
        let currentTime = now()
        var result: [String: ControllableAudioSession] = [:]

        for session in incoming {
            var refreshed = session
            refreshed.lastSeenAt = currentTime
            result[session.identity] = refreshed
        }

        for (identity, previous) in buffered where result[identity] == nil {
            if currentTime.timeIntervalSince(previous.lastSeenAt) < gracePeriod {
                result[identity] = previous
            }
        }

        buffered = result
        // Dictionary iteration order isn't stable — without sorting here too, the ordering fix in
        // AudioProcessGrouping.group() would be undone every time this buffer is applied on top
        // of it (confirmed via manual testing: rows kept reshuffling despite that earlier fix).
        // ControllableAudioSession's Comparable conformance is the single source of truth for
        // row order — same comparator AudioProcessGrouping uses, no duplication.
        return result.values.sorted()
    }
}
