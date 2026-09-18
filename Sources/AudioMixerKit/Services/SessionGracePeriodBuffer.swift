import Foundation

public final class SessionGracePeriodBuffer {
    public static let defaultGracePeriod: TimeInterval = 3

    private var buffered: [String: ControllableAudioSession] = [:]
    private let gracePeriod: TimeInterval
    private let now: () -> Date

    public init(gracePeriod: TimeInterval = SessionGracePeriodBuffer.defaultGracePeriod, now: @escaping () -> Date = Date.init) {
        self.gracePeriod = gracePeriod
        self.now = now
    }

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
        return result.values.sorted()
    }
}
