import AudioMixerKit

/// In-memory test double for `VolumePreferencesProviding` — lets a test inject known persisted
/// state without touching real `UserDefaults` at all.
final class FakeVolumePreferencesStore: VolumePreferencesProviding {
    private var storage: [String: (volume: Double, isMuted: Bool)] = [:]

    init(seed: [String: (volume: Double, isMuted: Bool)] = [:]) {
        storage = seed
    }

    func persistedState(for identity: String) -> (volume: Double, isMuted: Bool)? {
        storage[identity]
    }

    func setVolume(_ volume: Double, for identity: String) {
        var current = storage[identity] ?? (volume: volume, isMuted: false)
        current.volume = volume
        storage[identity] = current
    }

    func setMuted(_ isMuted: Bool, for identity: String) {
        var current = storage[identity] ?? (volume: 1.0, isMuted: isMuted)
        current.isMuted = isMuted
        storage[identity] = current
    }
}
