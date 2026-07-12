import XCTest
@testable import NanoTeams

final class FilenameMatcherTests: XCTestCase {

    // MARK: - Basic match semantics

    func testSubstring_matchesBasename() {
        let matches = FilenameMatcher.match(
            candidates: ["Services/Search/SearchExecutor.swift", "Domain/Role.swift"],
            queries: ["Executor"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "Services/Search/SearchExecutor.swift")
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    func testSubstring_matchesPathOnly_whenBasenameDoesNot() {
        let matches = FilenameMatcher.match(
            candidates: ["Services/Search/Foo.swift", "Domain/Bar.swift"],
            queries: ["Search"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "Services/Search/Foo.swift")
        XCTAssertEqual(matches[0].matched_on, .path,
            "Query hit a parent directory in the path, not the basename")
    }

    func testSubstring_caseInsensitive() {
        let matches = FilenameMatcher.match(
            candidates: ["Services/Team/TeamEngine.swift"],
            queries: ["TEAMENGINE"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testEmptyQueries_returnNoMatches() {
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "b.swift"],
            queries: [],
            limit: 10
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testWhitespaceOnlyQueries_returnNoMatches() {
        // A naive substring matcher would treat "   " as a match against
        // every path. The cleaner trims and skips so the LLM can pass the
        // raw literal query alongside its tokens (some are blank) without
        // accidentally matching the entire tree.
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "b.swift"],
            queries: ["   ", "\n\t"],
            limit: 10
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testZeroLimit_returnsEmpty() {
        let matches = FilenameMatcher.match(
            candidates: ["foo.swift"],
            queries: ["foo"],
            limit: 0
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testNegativeLimit_returnsEmpty() {
        let matches = FilenameMatcher.match(
            candidates: ["foo.swift"],
            queries: ["foo"],
            limit: -5
        )
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Sort order

    func testBasenameMatches_sortBeforePathMatches() {
        // "Search" appears as both a basename token (in `Search.swift`)
        // and as a parent directory (in `Services/Search/Foo.swift`).
        // Basename hits MUST come first regardless of input order.
        let matches = FilenameMatcher.match(
            candidates: [
                "Services/Search/Foo.swift",   // path match
                "Domain/Search.swift",         // basename match
                "Services/Search/Bar.swift",   // path match
            ],
            queries: ["Search"],
            limit: 10
        )
        XCTAssertEqual(matches.map(\.path), [
            "Domain/Search.swift",        // basename, alpha-sorted within bucket
            "Services/Search/Bar.swift",  // path, alpha-sorted within bucket
            "Services/Search/Foo.swift",
        ])
    }

    func testTiesWithinBucket_sortLexicographically() {
        let matches = FilenameMatcher.match(
            candidates: [
                "z/zebra.swift",
                "a/alpha.swift",
                "m/middle.swift",
            ],
            queries: [".swift"],  // matches all three basenames
            limit: 10
        )
        XCTAssertEqual(matches.map(\.path), [
            "a/alpha.swift",
            "m/middle.swift",
            "z/zebra.swift",
        ])
    }

    // MARK: - Dedup

    func testDuplicateCandidatePath_appearsOnce() {
        let matches = FilenameMatcher.match(
            candidates: ["foo.swift", "foo.swift", "foo.swift"],
            queries: ["foo"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testMatchedByMultipleQueryTerms_appearsOnce() {
        let matches = FilenameMatcher.match(
            candidates: ["TeamEngine.swift"],
            queries: ["Team", "Engine", "TeamEngine"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Limit

    func testLimit_capsBasenameThenPath() {
        let matches = FilenameMatcher.match(
            candidates: [
                "a/foo.swift",     // basename
                "b/foo.swift",     // basename
                "foo/bar.swift",   // path-only ("foo" is the parent, basename is bar)
            ],
            queries: ["foo"],
            limit: 2
        )
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { $0.matched_on == .basename },
            "Basename matches must fill the budget before path matches")
    }

    // MARK: - Glob match

    func testGlob_starWildcard_matchesByExtension() {
        let matches = FilenameMatcher.match(
            candidates: [
                "a/foo.swift",
                "a/bar.m",
                "Sources/baz.swift",
            ],
            queries: ["*.swift"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.path)),
                       ["a/foo.swift", "Sources/baz.swift"])
    }

    func testGlob_caseInsensitiveByDefault() {
        // Filename glob should be case-insensitive — users and LLMs query
        // *.Swift, FOO*, etc. expecting case-folded behavior.
        let matches = FilenameMatcher.match(
            candidates: ["foo.swift", "Bar.SWIFT"],
            queries: ["*.SWIFT"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 2)
    }

    func testGlob_uncompilablePattern_failsClosed() {
        let matches = FilenameMatcher.match(
            candidates: ["foo.swift", "bar.swift"],
            queries: [GlobMatcher._testUncompilableGlobSentinel],
            limit: 10
        )
        XCTAssertTrue(matches.isEmpty,
            "An uncompilable glob query must match nothing, never the entire tree.")
    }

    // MARK: - Multi-language / cross-script (relevant to expand pipeline)

    func testCyrillicQuery_matchesCyrillicPath() {
        let matches = FilenameMatcher.match(
            candidates: ["docs/руководство.md", "docs/Guide.md"],
            queries: ["руководство"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "docs/руководство.md")
    }

    func testCyrillicBasename_caseInsensitiveAcrossScript() {
        // Russian text uses different lowercase rules than ASCII; ensure
        // `localizedCaseInsensitiveContains` folds Cyrillic case correctly.
        let matches = FilenameMatcher.match(
            candidates: ["docs/Прокрутка.md"],
            queries: ["прокрутка"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    // MARK: - Special characters in paths

    func testPathWithSpaces_matchesByBasename() {
        let matches = FilenameMatcher.match(
            candidates: ["docs/My Notes.md", "docs/other.md"],
            queries: ["notes"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "docs/My Notes.md")
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    func testPathWithDotsAndDashes_treatedAsLiterals() {
        // Substring path: the dots and dashes in the candidate are not
        // treated as wildcards because the query has no `*`.
        let matches = FilenameMatcher.match(
            candidates: ["src/foo-bar.test.swift"],
            queries: ["foo-bar.test"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testPathWithParentheses_substringMatch() {
        let matches = FilenameMatcher.match(
            candidates: ["build/app (copy).log"],
            queries: ["(copy)"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testHiddenDotfile_matchesAsBasename() {
        // .gitignore is a legitimate file the LLM may want to find.
        let matches = FilenameMatcher.match(
            candidates: [".gitignore", "Sources/foo.swift"],
            queries: ["gitignore"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, ".gitignore")
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    // MARK: - Root-level files (basename == path)

    func testRootLevelFile_basenameIsPath() {
        let matches = FilenameMatcher.match(
            candidates: ["Package.swift"],
            queries: ["Package"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matched_on, .basename,
            "A file at the root has basename == path; the basename branch must win.")
    }

    // MARK: - Glob: literal-only patterns and edge cases

    func testGlob_starOnly_matchesEverything() {
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "b.md", "deep/nested/c.txt"],
            queries: ["*"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 3,
            "A bare `*` glob matches every basename.")
    }

    func testGlob_multipleWildcards_anchored() {
        let matches = FilenameMatcher.match(
            candidates: [
                "src/AuthHelper.swift",
                "src/AuthHelperTests.swift",
                "src/Helper.swift",
                "src/AuthGuard.swift",
            ],
            queries: ["*Helper*.swift"],
            limit: 10
        )
        XCTAssertEqual(Set(matches.map(\.path)),
                       ["src/AuthHelper.swift", "src/AuthHelperTests.swift", "src/Helper.swift"],
            "`*Helper*.swift` matches anything containing `Helper` and ending in `.swift`.")
    }

    func testGlob_questionMarkIsNotWildcard() {
        // Only `*` is a wildcard. `?` should be matched literally.
        let matches = FilenameMatcher.match(
            candidates: ["readme?.md", "readmeA.md"],
            queries: ["readme?.md"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "readme?.md")
    }

    func testGlob_anchoredFullMatch_notSubstring() {
        // Globs are anchored — `*.swift` matches the whole basename, not a
        // substring of the path. So `Other.swift.bak` is NOT matched.
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "Other.swift.bak"],
            queries: ["*.swift"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "a.swift")
    }

    func testGlob_matchesPath_whenBasenameDoesNot() {
        // The matcher tries basename first, then full path. A glob that
        // requires a path separator can only match against the path.
        let matches = FilenameMatcher.match(
            candidates: ["Sources/Search/Foo.swift", "Sources/Other.swift"],
            queries: ["*Search*"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "Sources/Search/Foo.swift")
        XCTAssertEqual(matches[0].matched_on, .path,
            "Glob hit only the parent directory in the full path.")
    }

    // MARK: - Mixed glob + non-glob queries in one call

    func testMixedQueries_globAndSubstring_bothApply() {
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "README.md", "Helpers.swift"],
            queries: ["*.md", "Help"],
            limit: 10
        )
        XCTAssertEqual(Set(matches.map(\.path)),
                       ["README.md", "Helpers.swift"],
            "Glob and substring queries can both contribute matches in one call.")
    }

    // MARK: - Boundary: limit edges

    func testLimitOne_singleResult() {
        let matches = FilenameMatcher.match(
            candidates: ["alpha.swift", "beta.swift", "gamma.swift"],
            queries: [".swift"],
            limit: 1
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "alpha.swift",
            "Limit 1 must take the first basename hit lexicographically.")
    }

    func testLimitLargerThanMatchCount_returnsAll() {
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "b.swift"],
            queries: [".swift"],
            limit: 1000
        )
        XCTAssertEqual(matches.count, 2,
            "When limit exceeds available matches, return all of them.")
    }

    // MARK: - Empty / invalid input shapes

    func testEmptyCandidates_returnEmpty() {
        let matches = FilenameMatcher.match(
            candidates: [],
            queries: ["anything"],
            limit: 10
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testCandidateWithEmptyPath_doesNotCrash() {
        // Defensive: an empty-string candidate must not crash the basename
        // extraction or the substring check.
        let matches = FilenameMatcher.match(
            candidates: ["", "real.swift"],
            queries: ["real"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].path, "real.swift")
    }

    func testQueryEqualsBasename_basenameMatch() {
        // Exact basename equality is still a substring containment.
        let matches = FilenameMatcher.match(
            candidates: ["Package.swift"],
            queries: ["Package.swift"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    // MARK: - Query order priority

    func testMultipleBasenameMatches_dedupedAcrossQueries() {
        // Same file matches via two different query terms (one literal,
        // one expanded). It must appear exactly once.
        let matches = FilenameMatcher.match(
            candidates: ["UserManager.swift"],
            queries: ["user", "manager"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testFirstQueryWins_whenBothMatchBasename() {
        // Both "Auth" and "Helper" hit `AuthHelper.swift`'s basename.
        // Either order produces one match (deduped) — the matcher doesn't
        // expose query attribution, only the matched_on tag.
        let matches = FilenameMatcher.match(
            candidates: ["AuthHelper.swift"],
            queries: ["Auth", "Helper"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matched_on, .basename)
    }

    // MARK: - Path-only attribution

    func testPathHitNotPromotedByLaterBasenameQuery() {
        // The matcher iterates queries per candidate and breaks on the
        // first basename hit. If an earlier query hit only the path but a
        // later query hits the basename, the basename hit wins.
        let matches = FilenameMatcher.match(
            candidates: ["Services/Search/Foo.swift"],
            queries: ["Services", "Foo"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].matched_on, .basename,
            "Even though `Services` hit only the path first, `Foo` hits the basename and wins.")
    }

    // MARK: - Candidate-list dedup within a single call

    func testRepeatedCandidates_dedupedByPath() {
        let matches = FilenameMatcher.match(
            candidates: ["a.swift", "b.swift", "a.swift", "a.swift"],
            queries: [".swift"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.path)), ["a.swift", "b.swift"])
    }

    // MARK: - Preserves input path verbatim

    func testForwardSlashPathsPreserved() {
        // Inputs use forward-slash relative paths (the project's wire
        // convention). The matcher must not normalize or alter them.
        let matches = FilenameMatcher.match(
            candidates: ["NanoTeams/Services/Search/SearchExecutor.swift"],
            queries: ["SearchExecutor"],
            limit: 10
        )
        XCTAssertEqual(matches.first?.path,
                       "NanoTeams/Services/Search/SearchExecutor.swift")
    }

    // MARK: - Glob edge cases

    func testGlob_doubleStar_collapsesToSingleAnyPath() {
        // `**` is not a path-segment-aware wildcard here — both `*`s collapse
        // to `.*`, which is equivalent to a single `*`. Pinning this so a
        // future shell-style `**` implementation can't silently change
        // behavior for queries that already contain `**`.
        let matches = FilenameMatcher.match(
            candidates: [
                "src/foo.swift",
                "src/sub/bar.swift",
                "main.swift",
            ],
            queries: ["**.swift"],
            limit: 10
        )
        XCTAssertEqual(matches.count, 3,
                       "`**.swift` matches all .swift files because each `*` is `.*`")
    }

    func testGlob_starSpansSlash_matchesAcrossDirectories() {
        // The anchored `*` in `GlobMatcher` is `.*`, which DOES match `/`.
        // Pin this behavior so a future change to "segment-bounded glob"
        // can't silently regress this contract.
        let matches = FilenameMatcher.match(
            candidates: [
                "src/sub/Deep.swift",
                "Deep.swift",
            ],
            queries: ["src/*.swift"],
            limit: 10
        )
        // Both candidates can match: `src/*.swift` against the basename
        // `Deep.swift` fails (no leading `src/`), so the matcher falls
        // through to the full path. `src/.*\.swift` matches `src/sub/Deep.swift`
        // because `*` spans `/`. The flat candidate `Deep.swift` does not start
        // with `src/`.
        let paths = matches.map(\.path)
        XCTAssertTrue(paths.contains("src/sub/Deep.swift"),
                      "`src/*.swift` must span `/` to match nested files; got \(paths)")
        XCTAssertFalse(paths.contains("Deep.swift"),
                       "Top-level `Deep.swift` does not match `src/*.swift`")
    }

    // MARK: - GlobMatcher.validate

    func testGlobValidate_compileablePattern_doesNotThrow() {
        // Sanity check the validator doesn't reject ordinary patterns.
        XCTAssertNoThrow(try GlobMatcher.validate(glob: "*.swift"))
        XCTAssertNoThrow(try GlobMatcher.validate(glob: "Foo*Bar.txt"))
    }

    func testGlobValidate_uncompilable_throwsTypedInvalidFileGlob() {
        XCTAssertThrowsError(
            try GlobMatcher.validate(glob: GlobMatcher._testUncompilableGlobSentinel)
        ) { err in
            guard let searchErr = err as? SearchExecutorError,
                  case .invalidFileGlob(let pattern, _) = searchErr
            else {
                XCTFail("expected SearchExecutorError.invalidFileGlob, got \(err)")
                return
            }
            XCTAssertEqual(pattern, GlobMatcher._testUncompilableGlobSentinel)
        }
    }

    // MARK: - matchAll (roster / empty-query list mode)

    func testMatchAll_returnsEveryCandidateAsBasename() {
        // Roster mode: the walk already glob-filtered candidates, so every one
        // is a hit — tagged `.basename` (the glob is basename-oriented).
        let matches = FilenameMatcher.matchAll(
            candidates: ["scenes/Player.gd", "enemies/Slime.gd"],
            limit: 10
        )
        XCTAssertEqual(matches.map(\.path), ["enemies/Slime.gd", "scenes/Player.gd"])
        XCTAssertTrue(matches.allSatisfy { $0.matched_on == .basename })
    }

    func testMatchAll_sortsLexicographically() {
        let matches = FilenameMatcher.matchAll(
            candidates: ["z/zebra.gd", "a/alpha.gd", "m/middle.gd"],
            limit: 10
        )
        XCTAssertEqual(matches.map(\.path), ["a/alpha.gd", "m/middle.gd", "z/zebra.gd"])
    }

    func testMatchAll_dedupesByPath() {
        let matches = FilenameMatcher.matchAll(
            candidates: ["a.gd", "a.gd", "b.gd", "a.gd"],
            limit: 10
        )
        XCTAssertEqual(matches.map(\.path), ["a.gd", "b.gd"])
    }

    func testMatchAll_respectsLimit_afterSort() {
        // Cap applies AFTER the lexicographic sort, so the smallest paths win.
        let matches = FilenameMatcher.matchAll(
            candidates: ["c.gd", "a.gd", "b.gd"],
            limit: 2
        )
        XCTAssertEqual(matches.map(\.path), ["a.gd", "b.gd"])
    }

    func testMatchAll_zeroLimit_returnsEmpty() {
        XCTAssertTrue(FilenameMatcher.matchAll(candidates: ["a.gd"], limit: 0).isEmpty)
    }

    func testMatchAll_negativeLimit_returnsEmpty() {
        XCTAssertTrue(FilenameMatcher.matchAll(candidates: ["a.gd"], limit: -3).isEmpty)
    }

    func testMatchAll_emptyCandidates_returnsEmpty() {
        XCTAssertTrue(FilenameMatcher.matchAll(candidates: [], limit: 10).isEmpty)
    }
}
