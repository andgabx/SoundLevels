import XCTest
@testable import AudioMixerKit

final class AppVolumeViewModelTests: XCTestCase {
    private func makeViewModel(
        session: ControllableAudioSession,
        otherSessions: [ControllableAudioSession] = [],
        fake: FakeAudioSessionProvider? = nil
    ) -> (AppVolumeViewModel, FakeAudioSessionProvider) {
        let provider = fake ?? FakeAudioSessionProvider(permissionState: .granted, sessions: [session] + otherSessions)
        let viewModel = AppVolumeViewModel(session: session, provider: provider)
        return (viewModel, provider)
    }

    func testSetVolumeZeroSetsMuted() {
        let session = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _) = makeViewModel(session: session)

        viewModel.setVolume(0)

        XCTAssertTrue(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0)
    }

    func testSetVolumeAboveZeroUnmutesAndUpdatesLastNonZeroVolume() {
        let session = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0)
        let (viewModel, _) = makeViewModel(session: session)

        viewModel.setVolume(0.7)

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.7)
    }

    func testSetVolumeAndSetMutedAreNoOpsWhenNotControllable() {
        var session = ControllableAudioSession(identity: "com.example.daemon", displayName: "daemon", volume: 0.5)
        session.isControllable = false
        let (viewModel, fake) = makeViewModel(session: session)

        viewModel.setVolume(0.9)
        viewModel.toggleMute()

        XCTAssertEqual(viewModel.volume, 0.5, "FR-011: no-op for uncontrollable sessions")
        XCTAssertTrue(fake.recordedCalls.isEmpty, "Provider should not even be asked to mutate an uncontrollable session")
    }

    func testSetVolumeForOneAppNeverMutatesAnotherApp() {
        let music = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0.5)
        let chrome = ControllableAudioSession(identity: "com.google.Chrome", displayName: "Chrome", volume: 0.5)
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [music, chrome])
        let musicViewModel = AppVolumeViewModel(session: music, provider: fake)
        let chromeViewModel = AppVolumeViewModel(session: chrome, provider: fake)

        musicViewModel.setVolume(0.1)

        XCTAssertEqual(musicViewModel.volume, 0.1)
        XCTAssertEqual(chromeViewModel.volume, 0.5, "FR-007: changing one app's volume must not affect another's")
        XCTAssertTrue(fake.recordedCalls.allSatisfy { $0.bundleIdentifier == "com.apple.Music" })
    }

    func testToggleMuteWhileVolumeAboveZeroPreservesVolumeAndSilencesAudio() {
        let session = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _) = makeViewModel(session: session)

        viewModel.toggleMute()

        XCTAssertTrue(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.6, "US2: toggling mute must not move the slider")
    }

    func testToggleMuteOffRestoresAudioAtTheUnchangedVolume() {
        let session = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _) = makeViewModel(session: session)

        viewModel.toggleMute()
        viewModel.toggleMute()

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.6)
    }

    func testUpdatesIndependentlyWithoutAnyMixerViewModelAlive() {
        let session = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music", volume: 0.5)
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [session])
        let viewModel = AppVolumeViewModel(session: session, provider: fake)

        viewModel.setVolume(0.2)

        XCTAssertEqual(viewModel.volume, 0.2)
    }
}
