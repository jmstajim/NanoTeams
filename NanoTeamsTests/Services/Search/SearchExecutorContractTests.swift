import XCTest
@testable import NanoTeams

/// Two invariants the paging rewrite has to hold, both found by review rather than by a failing
/// test — which is why they are pinned here rather than left to the characterization suite.
///
/// 1. **The walk terminates.** `.isDirectoryKey` follows symlinks, so `a/loop -> a` recursed
///    until the stack overflowed. On a zero-match query the budget never trips, so nothing else
///    bounded it.
///
/// 2. **The envelope never contradicts itself.** The model pages by re-issuing with `offset`
///    advanced by `count` and stops when `has_more` is absent, so `count`, `has_more` and
///    `total_matches` have to agree. They did not: list mode reported `count: 0` (there are no
///    content matches) beside a full page of names — "advance by zero", i.e. page forever — and
///    `total_matches: 0` beside `has_more: true`.
final class SearchExecutorContractTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(
        _ queries: [String], maxResults: Int = 20, offset: Int = 0
    ) async throws -> SearchExecutorOutput {
        try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: queries, maxResults: maxResults, offset: offset, internalDir: internalDir))
    }

    /// List mode: an all-empty query set means "enumerate files, don't grep".
    private func list(maxResults: Int = 20, offset: Int = 0) async throws -> SearchExecutorOutput {
        try await run([""], maxResults: maxResults, offset: offset)
    }

    // MARK: - Walk termination

    /// A symlink pointing at its own ancestor must not recurse forever. Without the guard this
    /// overflows the stack rather than failing an assertion, so a timeout is the safety net.
    func testSymlinkCycle_terminates() async throws {
        try write("a/real.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("a/loop"),
            withDestinationURL: tempDir.appendingPathComponent("a"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.map(\.path), ["a/real.swift"],
                       "the real file is found exactly once, not once per loop iteration")
    }

    /// A zero-match query is the dangerous case: the budget never trips, so the cycle guard is
    /// the only thing that ends the walk.
    func testSymlinkCycle_terminatesEvenWithNoMatchToStopOn() async throws {
        try write("a/real.swift", content: "unrelated\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("a/loop"),
            withDestinationURL: tempDir.appendingPathComponent("a"))

        let out = try await run(["zzz_absent"])
        XCTAssertTrue(out.matches.isEmpty)
    }

    /// The skip is reported. Silence would be indistinguishable from an empty subtree, which is
    /// the confusion `skipped` exists to prevent (no-silent-caps).
    func testSymlinkCycle_isReportedNotSwallowed() async throws {
        try write("a/real.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("a/loop"),
            withDestinationURL: tempDir.appendingPathComponent("a"))

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.skipped.contains { $0.reason.contains("symlink") },
                      "expected a symlink notice, got \(out.skipped)")
    }

    // MARK: - Symlinked directories are searched, but never outside the folder

    /// `URLResourceValues.isDirectory` describes the LINK, not its target — measured, not
    /// assumed. The pre-rewrite walk asked `fileExists(atPath:isDirectory:)`, which follows, so
    /// symlinked source trees were searched; prefetching resource values silently stopped
    /// searching them. This test is the pin for that regression.
    func testSymlinkedDirectory_isStillSearched() async throws {
        try write("real/deep/target.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("link"),
            withDestinationURL: tempDir.appendingPathComponent("real/deep"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.count, 1, "the file is reachable and must be found once")
    }

    /// Documents the observed platform behaviour the fix is built on, so a future Foundation
    /// change that starts following links shows up here rather than as a silent doubling.
    func testPlatform_isDirectoryKey_describesTheLinkNotItsTarget() throws {
        try write("real/x.txt", content: "x\n")
        let link = tempDir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: tempDir.appendingPathComponent("real"))

        let rv = try link.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(rv.isSymbolicLink, true)
        XCTAssertEqual(rv.isDirectory, false, "reports the link, not the directory it points to")

        var followed: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: link.path, isDirectory: &followed))
        XCTAssertTrue(followed.boolValue, "fileExists DOES follow — which is why the walk asks it")
    }

    /// The second half of the same platform behaviour, and the subtler one: even once you know
    /// the link points at a directory, enumerating THE LINK fails — `contentsOfDirectory(at:)`
    /// throws `ENOTDIR`, because a symlink URL is not a directory-path URL. The walk swallows
    /// that with `try?` and returns, so the subtree reads as EMPTY rather than as an error.
    /// This is why the walk descends into the RESOLVED target.
    func testPlatform_enumeratingASymlinkURL_throwsRatherThanListing() throws {
        try write("real/x.txt", content: "x\n")
        let link = tempDir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: tempDir.appendingPathComponent("real"))

        XCTAssertThrowsError(
            try fm.contentsOfDirectory(at: link, includingPropertiesForKeys: nil, options: []),
            "the link itself cannot be enumerated"
        ) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadUnknownError, "ENOTDIR")
        }

        let viaTarget = try fm.contentsOfDirectory(
            at: link.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [])
        XCTAssertEqual(viaTarget.count, 1, "…while the resolved target enumerates normally")
    }

    /// The tool is sandboxed to the work folder, and the walk is the one path that never
    /// consults `SandboxPathResolver` per entry. Following a link out of the folder would read
    /// files `read_file` would refuse to open.
    func testSymlinkOutsideTheWorkFolder_isNotFollowed() async throws {
        let outside = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try "NEEDLE\n".write(to: outside.appendingPathComponent("secret.txt"),
                             atomically: true, encoding: .utf8)

        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("escape"), withDestinationURL: outside)

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty,
                      "must not read outside the sandbox — got \(out.matches.map(\.path))")
        XCTAssertTrue(out.skipped.contains { $0.reason.contains("outside the work folder") },
                      "and must say so rather than look like an empty folder: \(out.skipped)")
    }

    /// A symlink to a single file outside the folder is refused for the same reason.
    func testSymlinkToFileOutsideTheWorkFolder_isNotRead() async throws {
        let outside = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try "NEEDLE\n".write(to: secret, atomically: true, encoding: .utf8)

        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("escape.txt"), withDestinationURL: secret)

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty, "got \(out.matches.map(\.path))")
    }

    /// `.nanoteams/internal` is hidden from every tool. The walk excludes it by RELATIVE path
    /// prefix, and that exclusion rests on an assumption following symlinks breaks: a link at
    /// `link -> .nanoteams/internal` has relative path `link`, which matches no prefix, while its
    /// target is legitimately inside the work folder. Without a second check the walk would read
    /// `workfolder.json`, `settings.json`, `teams.json` and every `task.json`.
    func testSymlinkIntoTheInternalDirectory_isNotFollowed() async throws {
        try "NEEDLE secret\n".write(
            to: internalDir.appendingPathComponent("workfolder.json"),
            atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("peek"), withDestinationURL: internalDir)

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty,
                      "internal state must stay hidden — got \(out.matches.map(\.path))")
    }

    /// Same hole, one file wide.
    func testSymlinkToAFileInsideTheInternalDirectory_isNotRead() async throws {
        try "NEEDLE secret\n".write(
            to: internalDir.appendingPathComponent("teams.json"),
            atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("teams.json"),
            withDestinationURL: internalDir.appendingPathComponent("teams.json"))

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty, "got \(out.matches.map(\.path))")
    }

    /// RELATIVE links are the common real shape (`shared -> ../shared`), and the only one the
    /// other tests here do not exercise — `createSymbolicLink(withDestinationURL:)` writes an
    /// absolute destination.
    func testRelativeSymlink_insideTheFolder_isFollowed() async throws {
        try write("pkg/real/a.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("pkg/alias").path,
            withDestinationPath: "real")

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.count, 1, "got \(out.matches.map(\.path))")
    }

    /// A relative link that climbs OUT of the folder is refused like an absolute one.
    func testRelativeSymlink_escapingTheFolder_isRefused() async throws {
        let outside = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try "NEEDLE\n".write(to: outside.appendingPathComponent("s.txt"),
                             atomically: true, encoding: .utf8)

        try fm.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("out").path,
            withDestinationPath: "../\(outside.lastPathComponent)")

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty, "got \(out.matches.map(\.path))")
    }

    /// Containment must be by path COMPONENT, not string prefix: a sibling whose name merely
    /// starts with the root's is outside. This repo has been bitten by exactly that shape
    /// (`/Users/alex/NanoTeams` vs `/Users/alex/NanoTeamsPrivate`).
    func testSymlinkToASiblingWhoseNamePrefixesTheRoot_isRefused() async throws {
        let sibling = tempDir.deletingLastPathComponent()
            .appendingPathComponent(tempDir.lastPathComponent + "Extra", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sibling) }
        try "NEEDLE\n".write(to: sibling.appendingPathComponent("s.txt"),
                             atomically: true, encoding: .utf8)

        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("neighbour"), withDestinationURL: sibling)

        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty,
                      "a name-prefix sibling is NOT inside the folder — got \(out.matches.map(\.path))")
    }

    /// A symlink to a file inside the folder is a normal candidate.
    func testSymlinkToFileInsideTheFolder_isSearched() async throws {
        try write("real.txt", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("alias.txt"),
            withDestinationURL: tempDir.appendingPathComponent("real.txt"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.count, 2, "both names are real, distinct candidate paths")
        XCTAssertEqual(Set(out.matches.map(\.path)), ["alias.txt", "real.txt"])
    }

    /// The guard has to survive nesting — a link inside a directory reached through a link.
    func testSymlinkInsideASymlinkedDirectory_isHandled() async throws {
        try write("real/inner/x.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("real/back"),
            withDestinationURL: tempDir.appendingPathComponent("real"))
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("top"),
            withDestinationURL: tempDir.appendingPathComponent("real"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.count, 1, "got \(out.matches.map(\.path))")
    }

    /// List mode walks the same code path; a symlinked directory must not double the roster.
    func testListMode_symlinkedDirectory_appearsOnce() async throws {
        try write("real/a.swift", content: "x\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("alias"),
            withDestinationURL: tempDir.appendingPathComponent("real"))

        let out = try await list(maxResults: 50)
        let paths = out.filenameMatches.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "no duplicates: \(paths)")
        XCTAssertEqual(paths.filter { $0.hasSuffix("a.swift") }.count, 1, "\(paths)")
    }

    /// A dangling link is skipped without erroring — the behaviour `fileExists` gave before.
    func testDanglingSymlink_isSkippedQuietly() async throws {
        try write("real.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("broken"),
            withDestinationURL: tempDir.appendingPathComponent("does_not_exist"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.map(\.path), ["real.swift"])
    }

    /// Two DISTINCT directories that happen to share a name are both walked — the guard keys on
    /// the canonical path, not the name.
    func testWalk_distinctDirectoriesWithTheSameName_areBothWalked() async throws {
        try write("x/sub/a.swift", content: "NEEDLE\n")
        try write("y/sub/b.swift", content: "NEEDLE\n")

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(Set(out.matches.map(\.path)), ["x/sub/a.swift", "y/sub/b.swift"])
    }

    /// A symlink to a SIBLING subtree is not a cycle. It is visited once — via whichever path the
    /// walk reaches first — and the canonical-path guard is what stops the second visit from
    /// double-reporting the same file under two names.
    func testWalk_symlinkToSiblingSubtree_isNotDoubleCounted() async throws {
        try write("real/a.swift", content: "NEEDLE\n")
        try fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("alias"),
            withDestinationURL: tempDir.appendingPathComponent("real"))

        let out = try await run(["NEEDLE"])
        XCTAssertEqual(out.matches.count, 1,
                       "same underlying file, so one match — got \(out.matches.map(\.path))")
    }

    // MARK: - Envelope self-consistency

    /// The core contradiction: a saturated list-mode search reported `total_matches: 0` next to
    /// `truncated == true`. `total_matches` must be absent whenever another page exists.
    func testListMode_saturated_reportsNoTotal() async throws {
        for i in 0..<30 { try write("f\(i).swift", content: "x\n") }

        let out = try await list(maxResults: 5)
        XCTAssertTrue(out.truncated, "30 files, page of 5 — there is more")
        XCTAssertNil(out.totalMatches,
                     "a total beside has_more is a contradiction; got \(String(describing: out.totalMatches))")
    }

    /// Same invariant stated over the whole space this suite can reach: the two fields are never
    /// both present, in either mode, at any page size.
    func testTotalAndHasMore_areNeverBothPresent() async throws {
        for i in 0..<12 { try write("f\(i).swift", content: "NEEDLE\n") }

        for size in [1, 5, 11, 12, 13, 50] {
            for offset in [0, 5, 20] {
                for out in await [try run(["NEEDLE"], maxResults: size, offset: offset),
                                  try list(maxResults: size, offset: offset)] {
                    XCTAssertFalse(out.truncated && out.totalMatches != nil,
                                   "size=\(size) offset=\(offset)")
                }
            }
        }
    }

    /// When the walk really did complete, list mode reports the exact roster size — the previous
    /// shape reported 0 here, because it counted content matches in a mode that has none.
    func testListMode_complete_reportsTheRosterTotal() async throws {
        for i in 0..<4 { try write("f\(i).swift", content: "x\n") }

        let out = try await list(maxResults: 50)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.totalMatches, out.filenameMatches.count)
        XCTAssertEqual(out.filenameMatches.count, 4)
    }

    /// `count` must be the size of the list `offset` walks, or the caller advances by zero and
    /// re-requests the same page forever.
    func testListMode_pageCountCountsNames_notContentMatches() async throws {
        for i in 0..<30 { try write("f\(i).swift", content: "x\n") }

        let out = try await list(maxResults: 5)
        XCTAssertTrue(out.matches.isEmpty, "list mode greps nothing")
        XCTAssertEqual(out.pageCount, 5, "advancing offset by this must make progress")
        XCTAssertEqual(out.pageCount, out.filenameMatches.count)
    }

    /// The property that makes paging terminate: whenever another page is promised, this page
    /// carried enough results to reach it.
    func testWheneverHasMoreIsSet_pageCountIsNonZero() async throws {
        for i in 0..<30 { try write("f\(i).swift", content: "NEEDLE\n") }

        for size in [1, 3, 7, 29] {
            for offset in stride(from: 0, to: 30, by: size) {
                for out in await [try run(["NEEDLE"], maxResults: size, offset: offset),
                                  try list(maxResults: size, offset: offset)] {
                    if out.truncated {
                        XCTAssertGreaterThan(out.pageCount, 0, "size=\(size) offset=\(offset)")
                    }
                }
            }
        }
    }

    /// Walking list mode by `count` visits every file exactly once.
    func testListMode_pagingByCount_partitionsTheRoster() async throws {
        for i in 0..<17 { try write(String(format: "f%02d.swift", i), content: "x\n") }

        var seen: [String] = []
        var offset = 0
        for _ in 0..<20 {
            let out = try await list(maxResults: 5, offset: offset)
            seen += out.filenameMatches.map(\.path)
            guard out.truncated else { break }
            XCTAssertGreaterThan(out.pageCount, 0)
            offset += out.pageCount
        }
        XCTAssertEqual(seen.count, 17)
        XCTAssertEqual(Set(seen).count, 17, "no duplicates across pages")
    }

    // MARK: - Filename matches in content mode

    /// Names accompany page 1 only. Paging them in lockstep with content was unsound: `count`
    /// counts content matches, so a corpus with more name hits than content hits re-showed the
    /// same names on every page.
    func testContentMode_filenameMatches_doNotRepeatOnLaterPages() async throws {
        // 4 content matches, 12 name matches — the shape that used to duplicate.
        for i in 0..<12 { try write("NEEDLE_\(i).swift", content: "unrelated\n") }
        for i in 0..<4 { try write("body\(i).txt", content: "NEEDLE\n") }

        let first = try await run(["NEEDLE"], maxResults: 2, offset: 0)
        let second = try await run(["NEEDLE"], maxResults: 2, offset: 2)

        XCTAssertFalse(first.filenameMatches.isEmpty, "names ride along with page 1")
        XCTAssertTrue(second.filenameMatches.isEmpty,
                      "and are not repeated on page 2 — got \(second.filenameMatches.map(\.path))")
    }

    /// A cut filename list is announced rather than silently trimmed.
    func testContentMode_filenameMatchesCut_emitsAWarning() async throws {
        for i in 0..<12 { try write("NEEDLE_\(i).swift", content: "unrelated\n") }

        let out = try await run(["NEEDLE"], maxResults: 3)
        XCTAssertEqual(out.filenameMatches.count, 3)
        XCTAssertTrue(out.warnings.contains { $0.contains("filename_matches") },
                      "expected a cap notice, got \(out.warnings)")
    }

    /// No cut, no warning — the notice must not fire on a complete list.
    func testContentMode_filenameMatchesComplete_emitsNoWarning() async throws {
        for i in 0..<3 { try write("NEEDLE_\(i).swift", content: "unrelated\n") }

        let out = try await run(["NEEDLE"], maxResults: 50)
        XCTAssertEqual(out.filenameMatches.count, 3)
        XCTAssertTrue(out.warnings.isEmpty, "got \(out.warnings)")
    }

    // MARK: - Degenerate pages

    /// Paging past the end is not an error — it is a caller that walked off the end.
    func testListMode_offsetBeyondEnd_isAnEmptyPageNotAnError() async throws {
        for i in 0..<3 { try write("f\(i).swift", content: "x\n") }

        let out = try await list(maxResults: 5, offset: 500)
        XCTAssertTrue(out.filenameMatches.isEmpty)
        XCTAssertEqual(out.pageCount, 0)
        XCTAssertFalse(out.truncated, "nothing beyond the end to promise")
        XCTAssertNil(out.totalMatches, "offset > 0 never claims an exact total")
    }

    /// Smallest legal page. `collectBudget` is 2 here, so the off-by-one in the "one past the
    /// page" probe would show up as either a missing `has_more` or a doubled page.
    func testPageSizeOne_pagesOneAtATime() async throws {
        for i in 0..<3 { try write("f\(i).swift", content: "NEEDLE\n") }

        var seen: [String] = []
        var offset = 0
        for _ in 0..<10 {
            let out = try await run(["NEEDLE"], maxResults: 1, offset: offset)
            XCTAssertLessThanOrEqual(out.matches.count, 1)
            seen += out.matches.map(\.path)
            guard out.truncated else { break }
            offset += out.pageCount
        }
        XCTAssertEqual(Set(seen).count, 3, "\(seen)")
    }

    /// A page that exactly exhausts the corpus must not promise another one.
    func testPageExactlyFull_doesNotPromiseAnotherPage() async throws {
        for i in 0..<5 { try write("f\(i).swift", content: "NEEDLE\n") }

        let out = try await run(["NEEDLE"], maxResults: 5)
        XCTAssertEqual(out.matches.count, 5)
        XCTAssertFalse(out.truncated, "exactly 5 of 5 — nothing beyond")
        XCTAssertEqual(out.totalMatches, 5)
    }

    /// Warnings are for real cuts only; an ordinary search must carry none.
    func testOrdinarySearch_carriesNoWarnings() async throws {
        try write("a.swift", content: "NEEDLE\n")

        let out = try await run(["NEEDLE"], maxResults: 50)
        XCTAssertTrue(out.warnings.isEmpty, "got \(out.warnings)")
    }

    /// Page 2+ omits filename matches, so it must not warn about capping them either.
    func testContentModeLaterPage_carriesNoFilenameWarning() async throws {
        for i in 0..<12 { try write("NEEDLE_\(i).swift", content: "NEEDLE\n") }

        let out = try await run(["NEEDLE"], maxResults: 3, offset: 3)
        XCTAssertTrue(out.filenameMatches.isEmpty)
        XCTAssertTrue(out.warnings.isEmpty, "nothing was cut on this page: \(out.warnings)")
    }

    /// Zero results is a complete search, not an unknown one.
    func testNoMatches_reportsAnExactTotalOfZero() async throws {
        try write("a.swift", content: "unrelated\n")

        let out = try await run(["zzz_absent"])
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.totalMatches, 0)
        XCTAssertEqual(out.pageCount, 0)
    }

    /// An empty work folder is the same shape, with nothing to walk.
    func testEmptyWorkFolder_isAComplete_emptyResult() async throws {
        let out = try await run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.totalMatches, 0)
    }

    // MARK: - The per-query cap is a boundary too

    /// With N queries each bucket is capped at `ceil(budget / N)`, so one prolific term can be
    /// cut while the combined page is nowhere near full. That is still a cut, so the exact total
    /// must be withheld — otherwise it reports "how many we bothered to collect".
    func testPerQueryCapHit_withholdsTheExactTotal() async throws {
        // 40 matches for one term; the other four terms match nothing.
        try write("many.swift", content: String(repeating: "ALPHA\n", count: 40))

        let queries = ["ALPHA", "zzz_b", "zzz_c", "zzz_d", "zzz_e"]
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: queries, maxResults: 30, internalDir: internalDir))

        // ceil(31 / 5) = 7, so ALPHA is capped at 7 while the page holds 30.
        XCTAssertLessThan(out.matches.count, 30, "the page is not full")
        XCTAssertFalse(out.truncated)
        XCTAssertNil(out.totalMatches,
                     "a bucket was cut, so 'exact total' would be a lie — got \(String(describing: out.totalMatches))")
    }

    /// Single query: the cap equals the whole budget, so a complete search still reports a total.
    func testSingleQuery_completeSearch_stillReportsTheExactTotal() async throws {
        try write("some.swift", content: String(repeating: "ALPHA\n", count: 6))

        let out = try await run(["ALPHA"], maxResults: 30)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.totalMatches, 6)
    }
}
