import XCTest
@testable import AudioMixerKit

final class ControllableAudioSessionTests: XCTestCase {
    func testVolumeClampsToValidRange() {
        var session = ControllableAudioSession(bundleIdentifier: "com.example.app", displayName: "Example")
        session.setVolume(5.0)
        XCTAssertEqual(session.volume, 1.0)

        session.setVolume(-2.0)
        XCTAssertEqual(session.volume, 0.0)
    }

    func testIsMutedAlwaysMatchesVolumeZeroAfterConstruction() {
        let silent = ControllableAudioSession(bundleIdentifier: "com.example.app", displayName: "Example", volume: 0)
        XCTAssertTrue(silent.isMuted)

        let audible = ControllableAudioSession(bundleIdentifier: "com.example.app", displayName: "Example", volume: 0.5)
        XCTAssertFalse(audible.isMuted)
    }

    func testIsMutedAlwaysMatchesVolumeZeroAfterMutation() {
        var session = ControllableAudioSession(bundleIdentifier: "com.example.app", displayName: "Example", volume: 0.8)

        session.setVolume(0)
        XCTAssertTrue(session.isMuted)

        session.setVolume(0.3)
        XCTAssertFalse(session.isMuted)
    }
}
