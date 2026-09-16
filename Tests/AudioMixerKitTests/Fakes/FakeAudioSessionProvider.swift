import Combine
import AudioMixerKit

/// Script-driven, in-memory test double for `AudioSessionProviding` so ViewModel tests can
/// simulate any permission state or session-list change without real hardware.
/// See specs/001-per-app-volume-mixer/contracts/audio-session-providing.md.
final class FakeAudioSessionProvider: AudioSessionProviding {
    private let permissionSubject: CurrentValueSubject<PermissionState, Never>
    private let sessionsSubject: CurrentValueSubject<[ControllableAudioSession], Never>

    private(set) var requestPermissionCallCount = 0
    /// Records every setVolume/setMuted call so tests can assert cross-session isolation (FR-007).
    private(set) var recordedCalls: [(bundleIdentifier: String, kind: String, value: Double)] = []

    init(
        permissionState: PermissionState = .granted,
        sessions: [ControllableAudioSession] = []
    ) {
        permissionSubject = CurrentValueSubject(permissionState)
        sessionsSubject = CurrentValueSubject(sessions)
    }

    var permissionState: AnyPublisher<PermissionState, Never> {
        permissionSubject.eraseToAnyPublisher()
    }

    var sessions: AnyPublisher<[ControllableAudioSession], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    func requestPermission() {
        requestPermissionCallCount += 1
    }

    func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        recordedCalls.append((id, "setVolume", volume))
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.bundleIdentifier == id }) else { return }
        guard current[index].isControllable else { return }
        current[index].setVolume(volume)
        sessionsSubject.value = current
    }

    func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        recordedCalls.append((id, "setMuted", isMuted ? 1 : 0))
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.bundleIdentifier == id }) else { return }
        guard current[index].isControllable else { return }
        current[index].setMuted(isMuted)
        sessionsSubject.value = current
    }

    // MARK: - Test helpers (simulate external changes)

    func simulatePermissionChange(_ state: PermissionState) {
        permissionSubject.value = state
    }

    func simulateSessionsChange(_ newSessions: [ControllableAudioSession]) {
        sessionsSubject.value = newSessions
    }
}
