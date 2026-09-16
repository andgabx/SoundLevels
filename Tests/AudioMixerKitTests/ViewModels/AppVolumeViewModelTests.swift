import XCTest
@testable import AudioMixerKit

final class AppVolumeViewModelTests: XCTestCase {
    /// Also returns the `MixerViewModel` — it owns the Combine subscription that routes provider
    /// updates back into the row view model, so callers MUST keep it alive for the test's scope.
    private func makeViewModel(
        session: ControllableAudioSession,
        otherSessions: [ControllableAudioSession] = [],
        fake: FakeAudioSessionProvider? = nil
    ) -> (AppVolumeViewModel, FakeAudioSessionProvider, MixerViewModel) {
        let provider = fake ?? FakeAudioSessionProvider(permissionState: .granted, sessions: [session] + otherSessions)
        let mixer = MixerViewModel(provider: provider)
        let rowViewModel = mixer.rowViewModels.first(where: { $0.bundleIdentifier == session.bundleIdentifier })!
        return (rowViewModel, provider, mixer)
    }

    func testSetVolumeZeroSetsMuted() {
        let session = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _, mixer) = makeViewModel(session: session)
        _ = mixer

        viewModel.setVolume(0)

        XCTAssertTrue(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0)
    }

    func testSetVolumeAboveZeroUnmutesAndUpdatesLastNonZeroVolume() {
        let session = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music", volume: 0)
        let (viewModel, _, mixer) = makeViewModel(session: session)
        _ = mixer

        viewModel.setVolume(0.7)

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.7)
    }

    func testSetVolumeAndSetMutedAreNoOpsWhenNotControllable() {
        var session = ControllableAudioSession(bundleIdentifier: "com.example.daemon", displayName: "daemon", volume: 0.5)
        session.isControllable = false
        let (viewModel, fake, mixer) = makeViewModel(session: session)
        _ = mixer

        viewModel.setVolume(0.9)
        viewModel.toggleMute()

        XCTAssertEqual(viewModel.volume, 0.5, "FR-011: no-op for uncontrollable sessions")
        XCTAssertTrue(fake.recordedCalls.isEmpty, "Provider should not even be asked to mutate an uncontrollable session")
    }

    func testSetVolumeForOneAppNeverMutatesAnotherApp() {
        let music = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music", volume: 0.5)
        let chrome = ControllableAudioSession(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", volume: 0.5)
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [music, chrome])
        let mixer = MixerViewModel(provider: fake)
        let musicViewModel = mixer.rowViewModels.first(where: { $0.bundleIdentifier == "com.apple.Music" })!
        let chromeViewModel = mixer.rowViewModels.first(where: { $0.bundleIdentifier == "com.google.Chrome" })!

        musicViewModel.setVolume(0.1)

        XCTAssertEqual(musicViewModel.volume, 0.1)
        XCTAssertEqual(chromeViewModel.volume, 0.5, "FR-007: changing one app's volume must not affect another's")
        XCTAssertTrue(fake.recordedCalls.allSatisfy { $0.bundleIdentifier == "com.apple.Music" })
    }

    func testToggleMuteWhileVolumeAboveZeroPreservesVolumeAndSilencesAudio() {
        let session = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _, mixer) = makeViewModel(session: session)
        _ = mixer

        viewModel.toggleMute()

        XCTAssertTrue(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.6, "US2: toggling mute must not move the slider")
    }

    func testToggleMuteOffRestoresAudioAtTheUnchangedVolume() {
        let session = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music", volume: 0.6)
        let (viewModel, _, mixer) = makeViewModel(session: session)
        _ = mixer

        viewModel.toggleMute() // mute on
        viewModel.toggleMute() // mute off

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertEqual(viewModel.volume, 0.6)
    }
}
