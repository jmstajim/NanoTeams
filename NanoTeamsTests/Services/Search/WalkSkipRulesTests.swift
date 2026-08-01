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

    func testSkipRules_includesGeneratedTreesFromOtherEcosystems() {
        for name in ["__pycache__", "venv", ".venv", ".tox", ".mypy_cache", ".pytest_cache",
                     ".gradle", "Carthage", ".next", ".nuxt", ".turbo", ".parcel-cache",
                     ".cache", ".idea", ".vscode", ".terraform", "bower_components"] {
            XCTAssertTrue(WalkSkipRules.skipped.contains(name), "\(name) should be skipped")
        }
    }

    /// The negative half, and the one that matters most.
    ///
    /// Matching is by BARE NAME AT ANY DEPTH, so adding `build` would also skip `src/build/`,
    /// and `dist` would skip `Sources/dist/` — plausible hand-authored directories in real
    /// projects. Making generated output cheap is the binary gate's job (an 8 KB NUL sniff),
    /// not this list's. This test exists to stop the next person from "just adding dist too".
    func testSkipRules_excludesAmbiguousBuildOutputNames() {
        for name in ["build", "dist", "target", "out", "bin", "obj", "Debug", "Release"] {
            XCTAssertFalse(
                WalkSkipRules.skipped.contains(name),
                "'\(name)' is a plausible source directory name; skipping it by bare name at any "
                + "depth would silently hide real files"
            )
        }
    }

    /// Agent-instruction roots and skill source directories must stay reachable — five
    /// subsystems read this set, not just search.
    func testSkipRules_doesNotHideAgentInstructionOrSkillSources() {
        for name in [".github", ".claude", ".codex", ".cursor", ".gemini", ".windsurf",
                     ".opencode", ".codeium", ".cursorrules", ".windsurfrules"] {
            XCTAssertFalse(WalkSkipRules.skipped.contains(name),
                           "'\(name)' feeds AgentInstructionsScanner / AgentSkillsScanner")
        }
    }
}
