import Foundation

struct PersistedVolumeSetting: Codable {
    var volume: Double
    var isMuted: Bool
}

public final class UserDefaultsVolumePreferencesStore: VolumePreferencesProviding {
    static let storageKey = "com.andersongabriel.SoundLevels.persistedVolumeSettings"

    private let defaults: UserDefaults
    private var cache: [String: PersistedVolumeSetting]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cache = Self.load(from: defaults)
    }

    public func persistedState(for identity: String) -> (volume: Double, isMuted: Bool)? {
        guard let setting = cache[identity] else { return nil }
        return (volume: setting.volume, isMuted: setting.isMuted)
    }

    public func setVolume(_ volume: Double, for identity: String) {
        let clamped = min(max(volume, 0.0), 1.0)
        var setting = cache[identity] ?? PersistedVolumeSetting(volume: clamped, isMuted: false)
        setting.volume = clamped
        cache[identity] = setting
        save()
    }

    public func setMuted(_ isMuted: Bool, for identity: String) {
        var setting = cache[identity] ?? PersistedVolumeSetting(volume: 1.0, isMuted: isMuted)
        setting.isMuted = isMuted
        cache[identity] = setting
        save()
    }

    private static func load(from defaults: UserDefaults) -> [String: PersistedVolumeSetting] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: PersistedVolumeSetting].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
