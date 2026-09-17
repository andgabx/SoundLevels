import XCTest
@testable import AudioMixerKit

final class ControllableAudioSessionTests: XCTestCase {
    func testVolumeClampsToValidRange() {
        var session = ControllableAudioSession(identity: "com.example.app", displayName: "Example")
        session.setVolume(5.0)
        XCTAssertEqual(session.volume, 1.0)

        session.setVolume(-2.0)
        XCTAssertEqual(session.volume, 0.0)
    }

    func testIsMutedAlwaysMatchesVolumeZeroAfterConstruction() {
        let silent = ControllableAudioSession(identity: "com.example.app", displayName: "Example", volume: 0)
        XCTAssertTrue(silent.isMuted)

        let audible = ControllableAudioSession(identity: "com.example.app", displayName: "Example", volume: 0.5)
        XCTAssertFalse(audible.isMuted)
    }

    func testIsMutedAlwaysMatchesVolumeZeroAfterMutation() {
        var session = ControllableAudioSession(identity: "com.example.app", displayName: "Example", volume: 0.8)

        session.setVolume(0)
        XCTAssertTrue(session.isMuted)

        session.setVolume(0.3)
        XCTAssertFalse(session.isMuted)
    }

    func testComparableSortsByDisplayNameThenIdentity() {
        let chrome = ControllableAudioSession(identity: "com.google.Chrome", displayName: "Google Chrome")
        let musicA = ControllableAudioSession(identity: "com.apple.Music.a", displayName: "Music")
        let musicB = ControllableAudioSession(identity: "com.apple.Music.b", displayName: "Music")

        let sorted = [chrome, musicB, musicA].sorted()

        XCTAssertEqual(sorted.map(\.identity), ["com.google.Chrome", "com.apple.Music.a", "com.apple.Music.b"])
    }
}
