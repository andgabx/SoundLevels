public protocol VolumePreferencesProviding {
    func persistedState(for identity: String) -> (volume: Double, isMuted: Bool)?

    func setVolume(_ volume: Double, for identity: String)

    func setMuted(_ isMuted: Bool, for identity: String)
}
