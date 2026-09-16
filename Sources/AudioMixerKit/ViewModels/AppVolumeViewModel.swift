import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Owns a single application's slider/mute state (Constitution Principle II). One instance per
/// listed application, sourced from and delegating to an injected `AudioSessionProviding`.
public final class AppVolumeViewModel: ObservableObject, Identifiable {
    public var id: String { bundleIdentifier }

    public let bundleIdentifier: String
    @Published public private(set) var displayName: String
    @Published public private(set) var volume: Double
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var isControllable: Bool
    #if canImport(AppKit)
    @Published public private(set) var icon: NSImage?
    #endif

    private let provider: AudioSessionProviding

    init(session: ControllableAudioSession, provider: AudioSessionProviding) {
        self.bundleIdentifier = session.bundleIdentifier
        self.displayName = session.displayName
        self.volume = session.volume
        self.isMuted = session.isMuted
        self.isControllable = session.isControllable
        self.provider = provider
        #if canImport(AppKit)
        self.icon = session.icon
        #endif
    }

    /// Applied when `MixerViewModel` receives a fresh emission for this same application (US3).
    func updateSession(_ session: ControllableAudioSession) {
        displayName = session.displayName
        volume = session.volume
        isMuted = session.isMuted
        isControllable = session.isControllable
        #if canImport(AppKit)
        icon = session.icon
        #endif
    }

    /// Slider intent (FR-003/FR-004): 0 mutes, >0 unmutes. No-op if `isControllable == false`
    /// (FR-011) or for any other application's state (FR-007) — enforced by the provider.
    public func setVolume(_ newVolume: Double) {
        guard isControllable else { return }
        provider.setVolume(newVolume, forBundleIdentifier: bundleIdentifier)
    }

    /// Dedicated mute-toggle intent (FR-004/US2): never mutates the displayed `volume`.
    public func toggleMute() {
        guard isControllable else { return }
        provider.setMuted(!isMuted, forBundleIdentifier: bundleIdentifier)
    }
}
