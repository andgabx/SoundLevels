import Combine

public final class AppVolumeViewModel: ObservableObject, Identifiable {
    public var id: String { identity }

    public let identity: String
    @Published public private(set) var displayName: String
    @Published public private(set) var volume: Double
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var isControllable: Bool

    private let provider: AudioSessionProviding
    private var cancellables = Set<AnyCancellable>()

    init(session: ControllableAudioSession, provider: AudioSessionProviding) {
        self.identity = session.identity
        self.displayName = session.displayName
        self.volume = session.volume
        self.isMuted = session.isMuted
        self.isControllable = session.isControllable
        self.provider = provider

        provider.sessions
            .compactMap { sessions in sessions.first { $0.identity == session.identity } }
            .sink { [weak self] session in
                self?.apply(session)
            }
            .store(in: &cancellables)
    }

    private func apply(_ session: ControllableAudioSession) {
        displayName = session.displayName
        volume = session.volume
        isMuted = session.isMuted
        isControllable = session.isControllable
    }

    public func setVolume(_ newVolume: Double) {
        guard isControllable else { return }
        provider.setVolume(newVolume, forBundleIdentifier: identity)
    }

    public func toggleMute() {
        guard isControllable else { return }
        provider.setMuted(!isMuted, forBundleIdentifier: identity)
    }
}
