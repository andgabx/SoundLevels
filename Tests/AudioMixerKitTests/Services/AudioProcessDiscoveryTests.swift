import XCTest
@testable import AudioMixerKit

final class AudioProcessDiscoveryTests: XCTestCase {
    // MARK: - appBundlePath(fromExecutablePath:)

    func testAppBundlePathFindsOutermostAppForNestedHelperBundle() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

        let appPath = AudioProcessDiscovery.appBundlePath(fromExecutablePath: path)

        XCTAssertEqual(appPath, "/Applications/Google Chrome.app")
    }

    func testAppBundlePathFindsSimpleAppBundle() {
        let path = "/Applications/Safari.app/Contents/MacOS/Safari"

        let appPath = AudioProcessDiscovery.appBundlePath(fromExecutablePath: path)

        XCTAssertEqual(appPath, "/Applications/Safari.app")
    }

    func testAppBundlePathReturnsNilWhenNoAppBundleInPath() {
        // e.g. Safari's WebKit GPU process — a shared framework-level XPC service, not inside
        // any single app's .app bundle (confirmed via manual testing).
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"

        XCTAssertNil(AudioProcessDiscovery.appBundlePath(fromExecutablePath: path))
    }

    // MARK: - friendlyFallbackName(fromBundleIdentifier:processID:)

    func testFriendlyFallbackNameUsesLastTwoBundleIDComponents() {
        let name = AudioProcessDiscovery.friendlyFallbackName(fromBundleIdentifier: "com.apple.WebKit.GPU", processID: 123)

        XCTAssertEqual(name, "WebKit GPU")
    }

    func testFriendlyFallbackNameFallsBackToPIDWhenNoBundleIdentifier() {
        let name = AudioProcessDiscovery.friendlyFallbackName(fromBundleIdentifier: nil, processID: 456)

        XCTAssertEqual(name, "pid:456")
    }
}
