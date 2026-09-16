import Foundation
import AppKit

/// Represents one running application currently producing (or very recently producing) audio,
/// aggregating all of that application's audio-producing processes into a single controllable
/// unit. See specs/001-per-app-volume-mixer/data-model.md.
public struct ControllableAudioSession: Identifiable, Equatable, Comparable {
    public var id: String { bundleIdentifier }

    public let bundleIdentifier: String
    public var displayName: String
    public var icon: NSImage?
    public private(set) var volume: Double
    public private(set) var isMuted: Bool
    public var isControllable: Bool
    public private(set) var lastNonZeroVolume: Double
    public var lastSeenAt: Date

    public init(
        bundleIdentifier: String,
        displayName: String,
        icon: NSImage? = nil,
        volume: Double = 1.0,
        isControllable: Bool = true,
        lastSeenAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.icon = icon
        let clamped = ControllableAudioSession.clamp(volume)
        self.volume = clamped
        self.isMuted = clamped == 0
        self.isControllable = isControllable
        self.lastNonZeroVolume = clamped > 0 ? clamped : 1.0
        self.lastSeenAt = lastSeenAt
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    /// Slider-driven volume change (FR-003/FR-004): 0 mutes, >0 unmutes and remembers the level.
    public mutating func setVolume(_ newVolume: Double) {
        let clamped = ControllableAudioSession.clamp(newVolume)
        volume = clamped
        isMuted = clamped == 0
        if clamped > 0 {
            lastNonZeroVolume = clamped
        }
    }

    /// Dedicated mute-toggle intent (FR-004/US2): never mutates the displayed `volume`.
    public mutating func setMuted(_ muted: Bool) {
        if muted {
            if volume > 0 {
                lastNonZeroVolume = volume
            }
            isMuted = true
        } else {
            isMuted = false
        }
    }
}

extension ControllableAudioSession {
    public static func == (lhs: ControllableAudioSession, rhs: ControllableAudioSession) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.displayName == rhs.displayName
            && lhs.volume == rhs.volume
            && lhs.isMuted == rhs.isMuted
            && lhs.isControllable == rhs.isControllable
            && lhs.lastNonZeroVolume == rhs.lastNonZeroVolume
    }

    /// Popover row order (FR-002/FR-005): alphabetically by display name, then by bundle
    /// identifier as a stable tiebreak. Single source of truth — `AudioProcessGrouping` and
    /// `SessionGracePeriodBuffer` both used to duplicate this comparator; one layer's ordering
    /// fix was silently undone by the other's independent Dictionary→array conversion until both
    /// were unified here.
    public static func < (lhs: ControllableAudioSession, rhs: ControllableAudioSession) -> Bool {
        lhs.displayName == rhs.displayName
            ? lhs.bundleIdentifier < rhs.bundleIdentifier
            : lhs.displayName < rhs.displayName
    }
}
