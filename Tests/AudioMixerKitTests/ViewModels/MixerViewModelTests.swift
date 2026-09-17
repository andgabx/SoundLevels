import XCTest
@testable import AudioMixerKit

final class MixerViewModelTests: XCTestCase {
    func testDeniedPermissionExposesNoSessionsAndPermissionRequiredState() {
        let fake = FakeAudioSessionProvider(
            permissionState: .denied,
            sessions: [ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")]
        )
        let viewModel = MixerViewModel(provider: fake)

        XCTAssertEqual(viewModel.rowViewModels.count, 0)
        XCTAssertEqual(viewModel.listState, .permissionRequired)
    }

    func testPermissionGrantedExposesCurrentSessions() {
        let fake = FakeAudioSessionProvider(
            permissionState: .granted,
            sessions: [ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")]
        )
        let viewModel = MixerViewModel(provider: fake)

        XCTAssertEqual(viewModel.rowViewModels.map(\.identity), ["com.apple.Music"])
        XCTAssertEqual(viewModel.listState, .sessions)
    }

    func testPermissionTransitioningFromDeniedToGrantedWhileRunningExposesSessions() {
        let fake = FakeAudioSessionProvider(
            permissionState: .denied,
            sessions: [ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")]
        )
        let viewModel = MixerViewModel(provider: fake)
        XCTAssertEqual(viewModel.listState, .permissionRequired)

        fake.simulatePermissionChange(.granted)

        XCTAssertEqual(viewModel.listState, .sessions)
        XCTAssertEqual(viewModel.rowViewModels.map(\.identity), ["com.apple.Music"])
    }

    func testPermissionRevokedWhileRunningClearsSessions() {
        let fake = FakeAudioSessionProvider(
            permissionState: .granted,
            sessions: [ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")]
        )
        let viewModel = MixerViewModel(provider: fake)
        XCTAssertEqual(viewModel.listState, .sessions)

        fake.simulatePermissionChange(.denied)

        XCTAssertEqual(viewModel.rowViewModels.count, 0)
        XCTAssertEqual(viewModel.listState, .permissionRequired)
    }

    func testEmptySessionsWhilePermissionGrantedExposesEmptyState() {
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [])
        let viewModel = MixerViewModel(provider: fake)

        XCTAssertEqual(viewModel.listState, .empty)
    }

    func testSessionAdditionAndRemovalUpdateRowViewModelsWithoutExplicitRefresh() {
        let musicSession = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [musicSession])
        let viewModel = MixerViewModel(provider: fake)
        XCTAssertEqual(viewModel.rowViewModels.map(\.identity), ["com.apple.Music"])

        let chromeSession = ControllableAudioSession(identity: "com.google.Chrome", displayName: "Chrome")
        fake.simulateSessionsChange([musicSession, chromeSession])
        XCTAssertEqual(Set(viewModel.rowViewModels.map(\.identity)), ["com.apple.Music", "com.google.Chrome"])

        fake.simulateSessionsChange([chromeSession])
        XCTAssertEqual(viewModel.rowViewModels.map(\.identity), ["com.google.Chrome"])
    }

    func testExistingRowViewModelInstanceIsReusedAcrossEmissionsSoInFlightStateSurvives() {
        let musicSession = ControllableAudioSession(identity: "com.apple.Music", displayName: "Music")
        let fake = FakeAudioSessionProvider(permissionState: .granted, sessions: [musicSession])
        let viewModel = MixerViewModel(provider: fake)
        let firstInstance = viewModel.rowViewModels.first

        fake.simulateSessionsChange([musicSession])

        XCTAssertTrue(viewModel.rowViewModels.first === firstInstance)
    }
}
