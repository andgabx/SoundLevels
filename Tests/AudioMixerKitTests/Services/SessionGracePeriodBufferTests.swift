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

    func testOutputOrderIsDeterministicRegardlessOfInputOrder() {
        let buffer = SessionGracePeriodBuffer(gracePeriod: 3, now: Date.init)
        let chrome = ControllableAudioSession(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
        let music = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music")
        let spotify = ControllableAudioSession(bundleIdentifier: "com.spotify.client", displayName: "Spotify")

        let first = buffer.apply([chrome, music, spotify]).map(\.bundleIdentifier)
        let second = buffer.apply([spotify, chrome, music]).map(\.bundleIdentifier)
        let third = buffer.apply([music, spotify, chrome]).map(\.bundleIdentifier)

        let expected = ["com.google.Chrome", "com.apple.Music", "com.spotify.client"]
        XCTAssertEqual(first, expected)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }
}
