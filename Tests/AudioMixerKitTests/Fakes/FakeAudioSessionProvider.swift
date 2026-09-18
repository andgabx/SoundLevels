import Combine
import AudioMixerKit

final class FakeAudioSessionProvider: AudioSessionProviding {
    private let permissionSubject: CurrentValueSubject<PermissionState, Never>
    private let sessionsSubject: CurrentValueSubject<[ControllableAudioSession], Never>

    private(set) var requestPermissionCallCount = 0
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
        guard let index = current.firstIndex(where: { $0.identity == id }) else { return }
        guard current[index].isControllable else { return }
        current[index].setVolume(volume)
        sessionsSubject.value = current
    }

    func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        recordedCalls.append((id, "setMuted", isMuted ? 1 : 0))
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.identity == id }) else { return }
        guard current[index].isControllable else { return }
        current[index].setMuted(isMuted)
        sessionsSubject.value = current
    }

    func simulatePermissionChange(_ state: PermissionState) {
        permissionSubject.value = state
    }

    func simulateSessionsChange(_ newSessions: [ControllableAudioSession]) {
        sessionsSubject.value = newSessions
    }
}
