import XCTest
@testable import AudioMixerKit

final class SessionGracePeriodBufferTests: XCTestCase {
    func testSessionMissingWithinGracePeriodIsRetained() {
        var currentTime = Date(timeIntervalSince1970: 0)
        let buffer = SessionGracePeriodBuffer(gracePeriod: 3, now: { currentTime })

        let music = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music")
        _ = buffer.apply([music])

        currentTime = currentTime.addingTimeInterval(1.5) // brief pause, still within 3s
        let result = buffer.apply([])

        XCTAssertEqual(result.map(\.bundleIdentifier), ["com.apple.Music"])
    }

    func testSessionMissingLongerThanGracePeriodIsDropped() {
        var currentTime = Date(timeIntervalSince1970: 0)
        let buffer = SessionGracePeriodBuffer(gracePeriod: 3, now: { currentTime })

        let music = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music")
        _ = buffer.apply([music])

        currentTime = currentTime.addingTimeInterval(3.5) // longer than the grace period
        let result = buffer.apply([])

        XCTAssertTrue(result.isEmpty)
    }

    func testSessionReappearingWithinGracePeriodResetsTheClock() {
        var currentTime = Date(timeIntervalSince1970: 0)
        let buffer = SessionGracePeriodBuffer(gracePeriod: 3, now: { currentTime })

        let music = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music")
        _ = buffer.apply([music])

        currentTime = currentTime.addingTimeInterval(2)
        _ = buffer.apply([music]) // reappears, lastSeenAt refreshed

        currentTime = currentTime.addingTimeInterval(2) // 2s since reappearance, still < 3s
        let result = buffer.apply([])

        XCTAssertEqual(result.map(\.bundleIdentifier), ["com.apple.Music"])
    }
}
