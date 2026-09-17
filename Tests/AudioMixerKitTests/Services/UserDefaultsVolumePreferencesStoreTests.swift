import XCTest
@testable import AudioMixerKit

final class UserDefaultsVolumePreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UserDefaultsVolumePreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPersistedStateForNeverWrittenIdentityReturnsNil() {
        let store = UserDefaultsVolumePreferencesStore(defaults: defaults)
        XCTAssertNil(store.persistedState(for: "com.example.NeverTouched"))
    }

    func testWrittenVolumeIsReadableBackAndDoesNotLeakToOtherIdentities() {
        let store = UserDefaultsVolumePreferencesStore(defaults: defaults)

        store.setVolume(0.3, for: "com.apple.Music")

        XCTAssertEqual(store.persistedState(for: "com.apple.Music")?.volume, 0.3)
        XCTAssertNil(store.persistedState(for: "com.google.Chrome"), "FR-004: must not leak to other identities")
    }

    func testSetMutedDoesNotAlterSeparatelyPersistedVolume() {
        let store = UserDefaultsVolumePreferencesStore(defaults: defaults)

        store.setVolume(0.6, for: "com.apple.Music")
        store.setMuted(true, for: "com.apple.Music")

        let state = store.persistedState(for: "com.apple.Music")
        XCTAssertEqual(state?.volume, 0.6)
        XCTAssertEqual(state?.isMuted, true)
    }

    func testStateWrittenByOneInstanceIsReadableByAFreshInstance() {
        let firstInstance = UserDefaultsVolumePreferencesStore(defaults: defaults)
        firstInstance.setVolume(0.45, for: "com.apple.Music")

        let secondInstance = UserDefaultsVolumePreferencesStore(defaults: defaults)

        XCTAssertEqual(secondInstance.persistedState(for: "com.apple.Music")?.volume, 0.45,
                       "FR-005: must survive a relaunch, simulated here as a fresh instance over the same storage")
    }

    func testEmptyOrMalformedStorageBehavesLikeNeverPersisted() {
        defaults.set(Data("not valid json".utf8), forKey: UserDefaultsVolumePreferencesStore.storageKey)

        let store = UserDefaultsVolumePreferencesStore(defaults: defaults)

        XCTAssertNil(store.persistedState(for: "com.apple.Music"), "FR-006: malformed data must not throw or crash")
    }

    func testVolumeIsClampedBeforeBeingPersisted() {
        let store = UserDefaultsVolumePreferencesStore(defaults: defaults)

        store.setVolume(5.0, for: "com.apple.Music")
        XCTAssertEqual(store.persistedState(for: "com.apple.Music")?.volume, 1.0)

        store.setVolume(-2.0, for: "com.apple.Music")
        XCTAssertEqual(store.persistedState(for: "com.apple.Music")?.volume, 0.0)
    }
}
