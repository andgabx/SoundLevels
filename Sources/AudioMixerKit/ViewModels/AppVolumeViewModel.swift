import Combine

/// Owns a single application's slider/mute state (Constitution Principle II). One instance per
/// listed application. Subscribes to `provider.sessions` directly (filtered to its own
/// `identity`) rather than depending on `MixerViewModel` to push updates — so it keeps
/// receiving state as long as it and the provider are alive, with no implicit dependency on
/// `MixerViewModel`'s lifetime (T040; that implicit dependency was the exact cause of the retain
/// bug hit while first writing this type's tests).
///
/// Deliberately UI-framework-independent (Constitution I) — icon resolution lives at the View
/// layer (`AppVolumeRowView`), not here.
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

    /// Slider intent (FR-003/FR-004): 0 mutes, >0 unmutes. No-op if `isControllable == false`
    /// (FR-011) or for any other application's state (FR-007) — enforced by the provider.
    public func setVolume(_ newVolume: Double) {
        guard isControllable else { return }
        provider.setVolume(newVolume, forBundleIdentifier: identity)
    }

    /// Dedicated mute-toggle intent (FR-004/US2): never mutates the displayed `volume`.
    public func toggleMute() {
        guard isControllable else { return }
        provider.setMuted(!isMuted, forBundleIdentifier: identity)
    }
}
