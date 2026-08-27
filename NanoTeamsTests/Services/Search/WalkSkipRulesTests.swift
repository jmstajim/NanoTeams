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

    // MARK: - Bundle extensions

    /// The rule that skips `.xcresult` cannot live in `skipped`: that set matches a bare name
    /// exactly, and result bundles are named by whoever produced them.
    ///
    /// Measured on the NanoTeams work folder: 76 474 files — **73% of everything the walk
    /// enumerated** — sat inside four `.xcresult` directories no rule matched. A sequential grep
    /// of that folder took 8.69 s with them and 0.73 s without, which is a larger factor than
    /// parallelising the scan buys.
    ///
    /// RED: put `"xcresult"` in `skipped` instead of `skippedBundleExtensions` → the first two
    /// assertions fail, because `latest.xcresult` is not the string `xcresult`.
    func testShouldSkip_resultBundles_areSkippedWhateverTheyAreNamed() {
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "latest.xcresult"))
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "Test-NanoTeams-2026.08.21_00-07-32-+0300.xcresult"))
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "Payload.xcappdata"))
        // Case-insensitive: a bundle produced on a case-insensitive volume can arrive spelled
        // either way, and half a rule is worse than none.
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "Latest.XCResult"))
    }

    /// The extension rule must not widen into anything a person would hand-author.
    ///
    /// RED: match with `hasSuffix("result")` instead of `pathExtension` → `myresult` and
    /// `test_results` start being skipped and the walk silently loses real directories.
    func testShouldSkip_ordinarySourceNames_areNotCaughtByTheExtensionRule() {
        for name in ["myresult", "test_results", "xcresult", "results.md", "xcresults",
                     "Fixtures.xcresult.md", "notes.xcappdata.txt"] {
            XCTAssertFalse(WalkSkipRules.shouldSkip(name: name),
                           "\(name) must stay walkable")
        }
    }

    /// The predicate is the whole rule, so it must still answer for the NAME half.
    ///
    /// RED: drop the `skipped.contains(name)` line from `shouldSkip` → every assertion here
    /// fails while the extension assertions above stay green, which is the half-migration this
    /// catches.
    func testShouldSkip_stillAnswersForTheNameSet() {
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: ".git"))
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "node_modules"))
        XCTAssertTrue(WalkSkipRules.shouldSkip(name: "DerivedData"))
        XCTAssertFalse(WalkSkipRules.shouldSkip(name: "src"))
        XCTAssertFalse(WalkSkipRules.shouldSkip(name: ".github"))
    }

    /// Every walk asks the predicate — none of them re-implements the question.
    ///
    /// This is the pin the migration exists for: the rule now has two halves, and a call site
    /// that kept asking `skipped.contains(name)` would get the name half and silently miss the
    /// extension half. `list_files` was the specimen — it held a COPY of the set, one layer
    /// further from a grep for the rule than the direct callers (CLAUDE.md #120).
    ///
    /// RED: change any walk back to `WalkSkipRules.skipped.contains(name)` → the offending file
    /// is named here.
    func testEveryWalkAsksThePredicate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NanoTeams").standardizedFileURL
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            // The declaration site is allowed to name its own property; nobody else is.
            guard url.lastPathComponent != "WalkSkipRules.swift" else { continue }
            if source.contains("WalkSkipRules.skipped.contains(") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 100,
                             "anti-vacuum: the scan must have read the production tree")
        XCTAssertEqual(offenders, [],
                       "these walks interrogate the name SET directly and therefore miss the "
                           + "extension rule; call `WalkSkipRules.shouldSkip(name:)` instead")
    }
}
