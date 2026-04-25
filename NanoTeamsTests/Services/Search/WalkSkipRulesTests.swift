import XCTest
@testable import NanoTeams

/// Verifies the shared skip-rule constant. If somebody changes the set
/// without thinking through the consequences (e.g. dropping `node_modules`),
/// these tests fail and force a deliberate choice.
final class WalkSkipRulesTests: XCTestCase {

    func testSkipRules_includesGitFolders() {
        XCTAssertTrue(WalkSkipRules.skipped.contains(".git"))
        XCTAssertTrue(WalkSkipRules.skipped.contains(".svn"))
        XCTAssertTrue(WalkSkipRules.skipped.contains(".hg"))
    }

    func testSkipRules_includesBuildFolders() {
        XCTAssertTrue(WalkSkipRules.skipped.contains(".build"))
        XCTAssertTrue(WalkSkipRules.skipped.contains("DerivedData"))
        XCTAssertTrue(WalkSkipRules.skipped.contains(".swiftpm"))
    }

    func testSkipRules_includesEcosystemDependencyFolders() {
        XCTAssertTrue(WalkSkipRules.skipped.contains("node_modules"))
        XCTAssertTrue(WalkSkipRules.skipped.contains("Pods"))
        XCTAssertTrue(WalkSkipRules.skipped.contains("vendor"))
        XCTAssertTrue(WalkSkipRules.skipped.contains("third_party"))
    }

    func testSkipRules_includesMacOSNoise() {
        XCTAssertTrue(WalkSkipRules.skipped.contains(".DS_Store"))
    }

    func testSkipRules_doesNotIncludeUsefulDotfiles() {
        // These are explicit non-targets — they're useful project metadata
        // that the LLM should still see when listing a folder.
        XCTAssertFalse(WalkSkipRules.skipped.contains(".gitignore"))
        XCTAssertFalse(WalkSkipRules.skipped.contains(".env"))
        XCTAssertFalse(WalkSkipRules.skipped.contains(".eslintrc"))
        XCTAssertFalse(WalkSkipRules.skipped.contains(".github"))
    }

    func testSkipRules_doesNotIncludeRegularFolders() {
        // Sanity: nothing common is silently skipped.
        XCTAssertFalse(WalkSkipRules.skipped.contains("src"))
        XCTAssertFalse(WalkSkipRules.skipped.contains("lib"))
        XCTAssertFalse(WalkSkipRules.skipped.contains("test"))
        XCTAssertFalse(WalkSkipRules.skipped.contains("tests"))
        XCTAssertFalse(WalkSkipRules.skipped.contains("docs"))
    }
}
