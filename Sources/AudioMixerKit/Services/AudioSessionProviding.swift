import Combine

/// The seam between the testable ViewModel/Model layer and the real Core Audio implementation
/// (Constitution Principle III). ViewModels depend only on this protocol, never on Core Audio
/// directly. See specs/001-per-app-volume-mixer/contracts/audio-session-providing.md.
///
/// Conforming implementations MUST publish `permissionState` and `sessions` on the main queue —
/// ViewModels assign published values directly on receipt with no additional dispatching.
public protocol AudioSessionProviding {
    /// Current permission state; the ViewModel observes this to decide whether to show
    /// PermissionRequiredView or the session list.
    var permissionState: AnyPublisher<PermissionState, Never> { get }

    /// Requests the system permission needed to discover/control other apps' audio.
    /// No-op if already `.granted` or `.denied`.
    func requestPermission()

    /// Emits the current list of audio-producing applications every time it changes.
    var sessions: AnyPublisher<[ControllableAudioSession], Never> { get }

    /// Sets the given application's volume (0.0...1.0). Implementations MUST update `isMuted`
    /// consistently with the Data Model state transitions.
    func setVolume(_ volume: Double, forBundleIdentifier id: String)

    /// Toggles mute for the given application without discarding its slider position.
    func setMuted(_ isMuted: Bool, forBundleIdentifier id: String)
}
