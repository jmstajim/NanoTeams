import XCTest
@testable import NanoTeams

/// Pins the persistence + reset behavior of `StoreConfiguration.dictationLocaleIdentifiers`.
/// Uses an in-memory storage backend so tests don't touch `UserDefaults.standard`.
@MainActor
final class DictationLocalesConfigTests: XCTestCase {

    final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        private var store: [String: Any] = [:]
        func string(forKey key: String) -> String? { store[key] as? String }
        func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
        func data(forKey key: String) -> Data? { store[key] as? Data }
        func object(forKey key: String) -> Any? { store[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    }

    var storage: InMemoryStorage!
    var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Default

    func testDefault_emptyArray() {
        XCTAssertEqual(config.dictationLocaleIdentifiers, [])
    }

    // MARK: - Persistence

    // The post-migration on-disk form is BCP-47 hyphenated. We re-derive the
    // expected value from Foundation rather than hard-coding a string so this
    // test remains valid if `.bcp47` semantics ever change for these locales.
    private static let canonicalRU = Locale(identifier: "ru_RU").identifier(.bcp47)
    private static let canonicalEN = Locale(identifier: "en_US").identifier(.bcp47)
    private static let canonicalDE = Locale(identifier: "de_DE").identifier(.bcp47)

    func testSet_persistsToStorage() {
        config.dictationLocaleIdentifiers = [Self.canonicalEN, Self.canonicalRU]
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            [Self.canonicalEN, Self.canonicalRU]
        )
    }

    func testSet_orderPreserved() {
        // Selection order is meaningful — leader selection in
        // DictationService uses it as a stable tie-breaker.
        config.dictationLocaleIdentifiers = [Self.canonicalRU, Self.canonicalEN, Self.canonicalDE]
        XCTAssertEqual(
            config.dictationLocaleIdentifiers,
            [Self.canonicalRU, Self.canonicalEN, Self.canonicalDE]
        )
    }

    // `async` to avoid the Xcode 26.3 CI `abort()` that fires when a sync
    // `@MainActor` test method constructs a `@MainActor` type as a local.
    // See CLAUDE.md Testing Conventions #7.
    func testReloadFromStorage_restoresValue() async {
        storage.set([Self.canonicalRU, Self.canonicalEN], forKey: UserDefaultsKeys.dictationLocales)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [Self.canonicalRU, Self.canonicalEN])
    }

    func testSet_emptyArray_persists() async {
        config.dictationLocaleIdentifiers = [Self.canonicalEN]
        config.dictationLocaleIdentifiers = []
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [])
    }

    // MARK: - Migration (legacy form → current BCP-47 canonical, with dedup)

    /// On macOS 26, Foundation's plain `Locale.identifier` PRESERVES the input
    /// form — `"ru_RU"` and `"ru-RU"` round-trip unchanged. The only way to
    /// canonicalize is `.identifier(.bcp47)`. Older builds (pre-macOS 26) and
    /// some `DictationTranscriber.supportedLocales` outputs use underscored
    /// form. If a legacy `"en_US"` survives in UserDefaults while the row's
    /// `model.id` becomes `"en-US"`, `contains(model.id)` returns false (UI
    /// shows English unchecked) but the provider still hands the legacy entry
    /// to the engine — transcribing in the "unselected" language. Migration
    /// canonicalizes on load via `.bcp47` so any pre-existing legacy entries
    /// become hyphenated before any view reads them.
    func testReloadFromStorage_normalizesLegacyUnderscoredToBCP47() async {
        storage.set(["ru_RU", "en_US"], forKey: UserDefaultsKeys.dictationLocales)

        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [Self.canonicalRU, Self.canonicalEN])
        // Migration is eager — the canonical form is written back so the
        // next load (and any external reader) sees the normalized array.
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            [Self.canonicalRU, Self.canonicalEN]
        )
    }

    /// User flow that produced the original bug: under the legacy `firstIndex(of:)`
    /// match, toggling on macOS 26 could not match a stored `"ru_RU"` against
    /// `model.id == "ru-RU"` and would APPEND `"ru-RU"` next to it, accumulating
    /// duplicate slots. After this commit, `.bcp47` normalization on load
    /// collapses both forms; dedup preserves the first-seen position.
    func testReloadFromStorage_dedupsAcrossForms_preservingOrder() async {
        storage.set(["ru_RU", "en_US", "ru-RU"], forKey: UserDefaultsKeys.dictationLocales)

        let reloaded = StoreConfiguration(storage: storage)

        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [Self.canonicalRU, Self.canonicalEN])
    }

    func testReloadFromStorage_alreadyCanonical_doesNotRewrite() async {
        // Round-trip safety: when storage is already canonical, init must not
        // perturb it (avoids a no-op write on every cold launch).
        storage.set([Self.canonicalRU], forKey: UserDefaultsKeys.dictationLocales)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [Self.canonicalRU])
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            [Self.canonicalRU]
        )
    }

    // MARK: - Reset

    func testResetToDefaults_clearsDictationLocales() async {
        config.dictationLocaleIdentifiers = [Self.canonicalRU, Self.canonicalEN]
        config.resetToDefaults()
        XCTAssertEqual(config.dictationLocaleIdentifiers, [])
        // Per CLAUDE.md "Adding a New StoreConfiguration Setting", reset must
        // both `removeObject` AND reassign the property. The reassignment's
        // `didSet` leaves the key present with `[]` — pin that so a future
        // refactor that drops the reassignment would fail here.
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.dictationLocales) as? [String],
            []
        )
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.dictationLocaleIdentifiers, [])
    }
}
