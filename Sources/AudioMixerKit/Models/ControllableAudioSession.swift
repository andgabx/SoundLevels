import Foundation

public struct ControllableAudioSession: Identifiable, Equatable, Comparable {
    public var id: String { identity }

    public let identity: String
    public var displayName: String
    public private(set) var volume: Double
    public private(set) var isMuted: Bool
    public var isControllable: Bool
    public var lastSeenAt: Date

    public init(
        identity: String,
        displayName: String,
        volume: Double = 1.0,
        isControllable: Bool = true,
        lastSeenAt: Date = Date()
    ) {
        self.identity = identity
        self.displayName = displayName
        let clamped = ControllableAudioSession.clamp(volume)
        self.volume = clamped
        self.isMuted = clamped == 0
        self.isControllable = isControllable
        self.lastSeenAt = lastSeenAt
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    public mutating func setVolume(_ newVolume: Double) {
        let clamped = ControllableAudioSession.clamp(newVolume)
        volume = clamped
        isMuted = clamped == 0
    }

    public mutating func setMuted(_ muted: Bool) {
        isMuted = muted
    }
}

extension ControllableAudioSession {
    public static func == (lhs: ControllableAudioSession, rhs: ControllableAudioSession) -> Bool {
        lhs.identity == rhs.identity
            && lhs.displayName == rhs.displayName
            && lhs.volume == rhs.volume
            && lhs.isMuted == rhs.isMuted
            && lhs.isControllable == rhs.isControllable
    }

    public static func < (lhs: ControllableAudioSession, rhs: ControllableAudioSession) -> Bool {
        lhs.displayName == rhs.displayName
            ? lhs.identity < rhs.identity
            : lhs.displayName < rhs.displayName
    }
}
