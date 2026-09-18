import Combine

public protocol AudioSessionProviding {
    var permissionState: AnyPublisher<PermissionState, Never> { get }

    func requestPermission()

    var sessions: AnyPublisher<[ControllableAudioSession], Never> { get }

    func setVolume(_ volume: Double, forBundleIdentifier id: String)

    func setMuted(_ isMuted: Bool, forBundleIdentifier id: String)
}
