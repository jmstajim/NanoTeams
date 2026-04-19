import XCTest
@testable import NanoTeams

/// Guards `AppVersion.compare` / `shouldReconcile` against accidental regressions.
/// These helpers drive the version-bump reconcile in `migrateIfNeeded` AND the
/// app-update card newer-tag decision — a bad compare here silently breaks both.
final class AppVersionTests: XCTestCase {

    // MARK: - shouldReconcile

    func testShouldReconcile_emptyStored_alwaysTrue() {
        XCTAssertTrue(AppVersion.shouldReconcile(from: "", to: "1.0.0"))
        XCTAssertTrue(AppVersion.shouldReconcile(from: "", to: "0.0.1"))
    }

    func testShouldReconcile_olderToNewer_true() {
        XCTAssertTrue(AppVersion.shouldReconcile(from: "1.0.0", to: "1.0.1"))
        XCTAssertTrue(AppVersion.shouldReconcile(from: "1.9.9", to: "2.0.0"))
        XCTAssertTrue(AppVersion.shouldReconcile(from: "0.9", to: "1.0"))
    }

    func testShouldReconcile_sameVersion_false() {
        XCTAssertFalse(AppVersion.shouldReconcile(from: "1.0.0", to: "1.0.0"))
        XCTAssertFalse(AppVersion.shouldReconcile(from: "2.3.4", to: "2.3.4"))
    }

    func testShouldReconcile_newerToOlder_false_downgradeGuard() {
        // Downgrade must not re-run reconcile — otherwise newer bundled content
        // already on disk would be silently rewritten to older defaults.
        XCTAssertFalse(AppVersion.shouldReconcile(from: "2.0.0", to: "1.9.0"))
        XCTAssertFalse(AppVersion.shouldReconcile(from: "1.0.1", to: "1.0.0"))
    }

    // MARK: - compare

    func testCompare_basicSemver() {
        XCTAssertLessThan(AppVersion.compare("1.0.0", "1.0.1"), 0)
        XCTAssertGreaterThan(AppVersion.compare("1.0.1", "1.0.0"), 0)
        XCTAssertEqual(AppVersion.compare("1.2.3", "1.2.3"), 0)
    }

    func testCompare_vPrefixStripped() {
        XCTAssertEqual(AppVersion.compare("v1.2.3", "1.2.3"), 0)
        XCTAssertEqual(AppVersion.compare("V1.0.0", "1.0.0"), 0)
        XCTAssertLessThan(AppVersion.compare("v1.0.0", "v1.0.1"), 0)
    }

    func testCompare_differentComponentCount_treatsMissingAsZero() {
        // "1.2" vs "1.2.0" — both mean version 1.2; shouldn't flag a mismatch.
        XCTAssertEqual(AppVersion.compare("1.2", "1.2.0"), 0)
        XCTAssertEqual(AppVersion.compare("v1.2", "1.2.0"), 0)
        XCTAssertLessThan(AppVersion.compare("1.2", "1.2.1"), 0)
    }

    func testCompare_nonNumericSuffixIgnored() {
        // Pre-release markers don't carry useful ordering info for a simple
        // install-update gate. `1.0.0-beta` behaves like `1.0.0`.
        XCTAssertEqual(AppVersion.compare("1.0.0-beta", "1.0.0"), 0)
        XCTAssertEqual(AppVersion.compare("1.0.0-rc.1", "1.0.0"), 0)
        XCTAssertLessThan(AppVersion.compare("1.0.0-beta", "1.0.1"), 0)
    }

    func testCompare_missingNumericFallsTozero() {
        XCTAssertEqual(AppVersion.compare("abc", "xyz"), 0)
    }

    /// A segment like `"2a3"` collapses to its leading digits (`2`) — anything
    /// after the first non-digit is dropped. Guards against a future "smart"
    /// numeric parser breaking the documented contract.
    func testCompare_partialNumericSegment_truncatesAtFirstNonDigit() {
        XCTAssertLessThan(AppVersion.compare("1.2a3", "1.3"), 0)
        XCTAssertEqual(AppVersion.compare("1.2a3", "1.2"), 0)
        XCTAssertGreaterThan(AppVersion.compare("1.9x9", "1.2"), 0)
    }
}
