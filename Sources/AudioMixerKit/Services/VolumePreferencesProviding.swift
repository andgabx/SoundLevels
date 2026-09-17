/// The internal seam between `CoreAudioSessionService` and durable storage of per-app
/// volume/mute state (Constitution Principle III). Owned and consulted only by
/// `CoreAudioSessionService` — see specs/002-volume-persistence/contracts/volume-preferences-providing.md.
public protocol VolumePreferencesProviding {
    /// Any previously persisted state for this identity, or `nil` if none exists.
    func persistedState(for identity: String) -> (volume: Double, isMuted: Bool)?

    /// Durably records this identity's current volume, overwriting any previous record.
    func setVolume(_ volume: Double, for identity: String)

    /// Durably records this identity's current mute state, overwriting any previous record.
    func setMuted(_ isMuted: Bool, for identity: String)
}
