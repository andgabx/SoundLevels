import XCTest
@testable import AudioMixerKit

final class AudioProcessGroupingTests: XCTestCase {
    func testProcessesWithSameBundleIdentifierCollapseIntoOneSession() {
        let processes = [
            RawAudioProcess(processID: 1, bundleIdentifier: "com.google.Chrome", processName: "Google Chrome Helper"),
            RawAudioProcess(processID: 2, bundleIdentifier: "com.google.Chrome", processName: "Google Chrome Helper (Renderer)"),
            RawAudioProcess(processID: 3, bundleIdentifier: "com.google.Chrome", processName: "Google Chrome Helper (GPU)")
        ]

        let sessions = AudioProcessGrouping.group(processes: processes)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.bundleIdentifier, "com.google.Chrome")
        XCTAssertTrue(sessions.first?.isControllable ?? false)
    }

    func testProcessWithNoBundleIdentifierFallsBackToProcessNameSyntheticSession() {
        let processes = [
            RawAudioProcess(processID: 42, bundleIdentifier: nil, processName: "coreaudiod-helper")
        ]

        let sessions = AudioProcessGrouping.group(processes: processes)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.displayName, "coreaudiod-helper")
        XCTAssertFalse(session.isControllable, "Fallback sessions must render as uncontrollable (FR-011)")
        XCTAssertEqual(session.bundleIdentifier, AudioProcessGrouping.syntheticIdentity(forProcessName: "coreaudiod-helper"))
    }

    func testDifferentApplicationsProduceSeparateSessions() {
        let processes = [
            RawAudioProcess(processID: 1, bundleIdentifier: "com.apple.Music", processName: "Music"),
            RawAudioProcess(processID: 2, bundleIdentifier: "com.google.Chrome", processName: "Google Chrome")
        ]

        let sessions = AudioProcessGrouping.group(processes: processes)

        XCTAssertEqual(Set(sessions.map(\.bundleIdentifier)), Set(["com.apple.Music", "com.google.Chrome"]))
    }

    func testExistingSessionStateIsPreservedOnRegroup() {
        var known = ControllableAudioSession(bundleIdentifier: "com.apple.Music", displayName: "Music")
        known.setVolume(0.3)

        let processes = [
            RawAudioProcess(processID: 1, bundleIdentifier: "com.apple.Music", processName: "Music")
        ]

        let sessions = AudioProcessGrouping.group(processes: processes, existing: ["com.apple.Music": known])

        XCTAssertEqual(sessions.first?.volume, 0.3)
    }
}
