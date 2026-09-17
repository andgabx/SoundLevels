import Foundation

/// Represents one running application currently producing (or very recently producing) audio,
/// aggregating all of that application's audio-producing processes into a single controllable
/// unit. See specs/001-per-app-volume-mixer/data-model.md.
///
/// Deliberately UI-framework-independent (Constitution I) — icon resolution lives at the View
/// layer (`AppVolumeRowView`, via `AudioProcessDiscovery.applicationIcon`), not here.
public struct ControllableAudioSession: Identifiable, Equatable, Comparable {
    public var id: String { identity }

    /// Stable identity key — the real bundle identifier when resolvable, else a synthetic
    /// `process:<name>` key (`AudioProcessGrouping.identity(for:)`); doubles as the row's unique
    /// ID; source of grouping (research.md §3).
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

    /// Slider-driven volume change (FR-003/FR-004): 0 mutes, >0 unmutes.
    public mutating func setVolume(_ newVolume: Double) {
        let clamped = ControllableAudioSession.clamp(newVolume)
        volume = clamped
        isMuted = clamped == 0
    }

    /// Dedicated mute-toggle intent (FR-004/US2): never mutates the displayed `volume`.
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

    /// Popover row order (FR-002/FR-005): alphabetically by display name, then by identity as a
    /// stable tiebreak. Single source of truth — `AudioProcessGrouping` and
    /// `SessionGracePeriodBuffer` both used to duplicate this comparator; one layer's ordering
    /// fix was silently undone by the other's independent Dictionary→array conversion until both
    /// were unified here.
    public static func < (lhs: ControllableAudioSession, rhs: ControllableAudioSession) -> Bool {
        lhs.displayName == rhs.displayName
            ? lhs.identity < rhs.identity
            : lhs.displayName < rhs.displayName
    }
}
