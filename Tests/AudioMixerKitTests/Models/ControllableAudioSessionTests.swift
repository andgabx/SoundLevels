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

    func testComparableSortsByDisplayNameThenBundleIdentifier() {
        let chrome = ControllableAudioSession(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
        let musicA = ControllableAudioSession(bundleIdentifier: "com.apple.Music.a", displayName: "Music")
        let musicB = ControllableAudioSession(bundleIdentifier: "com.apple.Music.b", displayName: "Music")

        let sorted = [chrome, musicB, musicA].sorted()

        XCTAssertEqual(sorted.map(\.bundleIdentifier), ["com.google.Chrome", "com.apple.Music.a", "com.apple.Music.b"])
    }
}
