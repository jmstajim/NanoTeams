import XCTest

@testable import NanoTeams

/// `Theme.migrateLegacyAppearanceIfNeeded` carries the user's pre-consolidation
/// appearance pick (`appAppearance`: "system" / "light" / "dark") into the unified
/// `activeTheme` key, and is called once from `NanoTeamsApp.init`.
///
/// It shipped 2026-06-21 with no test and no date. Both gaps are the same gap: an
/// obligation nothing watches. The date arrived 2026-09-05 (`TODO(2026-Q4)`, DEBTS.md
/// D-32), and this suite is the other half — the migration is now committed to until
/// that quarter, so what it promises has to be falsifiable.
///
/// Storage is an in-memory double, never `UserDefaults.standard`: the test target runs
/// parallel host processes sharing one bundle-identifier defaults domain, so a write here
/// would reach every other worker (DEBTS.md D-4, and the reason `Theme._storage` exists).
final class ThemeAppearanceMigrationTests: XCTestCase {

    private var storage: InMemoryConfigurationStorage!

    override func setUp() {
        super.setUp()
        storage = InMemoryConfigurationStorage()
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    // MARK: - The three mapped values

    /// "dark" maps to `.terminal`, not to some `.dark` case — Terminal IS the canonical
    /// dark theme after the consolidation, and a wrong target here silently reskins every
    /// install that had picked Dark.
    ///
    /// RED: change `case "dark": mapped = .terminal` to `mapped = .system` → this fails
    /// naming the stored raw value.
    func testDark_becomesTerminal() {
        storage.set("dark", forKey: UserDefaultsKeys.appAppearance)

        XCTAssertTrue(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))

        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.activeTheme),
                       Theme.terminal.rawValue)
    }

    /// RED: change `case "system": mapped = .system` to `mapped = .terminal` → this fails.
    func testSystemAndLight_mapToThemselves() {
        storage.set("system", forKey: UserDefaultsKeys.appAppearance)
        XCTAssertTrue(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))
        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.activeTheme),
                       Theme.system.rawValue)

        let light = InMemoryConfigurationStorage()
        light.set("light", forKey: UserDefaultsKeys.appAppearance)
        XCTAssertTrue(Theme.migrateLegacyAppearanceIfNeeded(defaults: light))
        XCTAssertEqual(light.string(forKey: UserDefaultsKeys.activeTheme),
                       Theme.light.rawValue)
    }

    // MARK: - The three refusals

    /// Idempotence is the whole safety property: the migration runs on EVERY launch, so a
    /// missing guard would overwrite the user's current theme with a legacy pick they
    /// changed months ago.
    ///
    /// RED: drop the `guard defaults.string(forKey: activeTheme) == nil` line → the stored
    /// theme is clobbered back to Terminal and this fails.
    func testAnAlreadySetActiveTheme_isNeverOverwritten() {
        storage.set(Theme.parchment.rawValue, forKey: UserDefaultsKeys.activeTheme)
        storage.set("dark", forKey: UserDefaultsKeys.appAppearance)

        XCTAssertFalse(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))

        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.activeTheme),
                       Theme.parchment.rawValue)
    }

    /// The common case by far: a fresh install has neither key. Writing anything here would
    /// pin every new user to a theme nobody chose.
    ///
    /// RED: replace the legacy `guard let` with `let legacy = … ?? "dark"` → a key appears
    /// and this fails.
    func testNoLegacyValue_writesNothing() {
        XCTAssertFalse(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))

        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.activeTheme))
    }

    /// An unrecognised legacy value must leave the slot EMPTY rather than fall back to a
    /// theme, so `Theme.current`'s own `?? defaultTheme` stays the single place the default
    /// is decided.
    ///
    /// RED: change `default: mapped = nil` to `default: mapped = .terminal` → a key appears
    /// and this fails.
    func testUnknownLegacyValue_writesNothing() {
        storage.set("midnight", forKey: UserDefaultsKeys.appAppearance)

        XCTAssertFalse(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))

        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.activeTheme))
    }

    // MARK: - Running twice

    /// The call site runs this on every launch, so "one-shot" is a property of the code,
    /// not of the caller. Second run must be a no-op even though the legacy key survives.
    ///
    /// RED: drop the `activeTheme == nil` guard → the second call returns `true` and this
    /// fails on the return value.
    func testSecondLaunch_isANoOp() {
        storage.set("light", forKey: UserDefaultsKeys.appAppearance)
        XCTAssertTrue(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage))

        XCTAssertFalse(Theme.migrateLegacyAppearanceIfNeeded(defaults: storage),
                       "the migration must not fire twice")
        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.activeTheme),
                       Theme.light.rawValue)
    }
}
