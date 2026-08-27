import XCTest
@testable import NanoTeams

final class SearchIndexServiceTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ relPath: String, bytes: [UInt8]) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
    }

    private func makeService() -> SearchIndexService {
        SearchIndexService(workFolderRoot: tempDir, internalDir: internalDir, fileManager: .default)
    }

    // MARK: - Build / Load

    func testBuild_indexesSwiftFile() async throws {
        try write("Scroll.swift", content: "class ScrollView { func makeScrollView() {} }")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("scrollview"))
        XCTAssertTrue(index.tokens.contains("scroll"))
        XCTAssertTrue(index.tokens.contains("view"))
        XCTAssertTrue(index.tokens.contains("makescrollview"))
    }

    func testBuild_indexesFilenameStems() async throws {
        // Binary file with distinctive filename — only the name should land in vocabulary.
        try writeBytes("UniqueIdentifier.bin", bytes: [0xFF, 0xFE])
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("uniqueidentifier"))
        XCTAssertTrue(index.tokens.contains("unique"))
        XCTAssertTrue(index.tokens.contains("identifier"))
    }

    // MARK: - I4: corrupt on-disk index surfaces a load error

    /// A corrupt `search_index.json` must NOT silently look like "first launch"
    /// to the user. The service rebuilds from scratch (correct recovery) but
    /// also records the load failure so the coordinator can surface it in the
    /// UI — otherwise the user can't tell why their index keeps regenerating.
    func testLoadFromDisk_corruptJSON_surfacesLoadError() async throws {
        // Plant a malformed JSON file at the exact path the service reads.
        let indexFile = internalDir.appendingPathComponent(
            "search_index.json", isDirectory: false
        )
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try "not json at all".write(to: indexFile, atomically: true, encoding: .utf8)

        let service = makeService()
        _ = await service.loadOrBuild()
        let loadError = await service.lastLoadError

        XCTAssertNotNil(loadError,
                        "Corrupt JSON must surface via `lastLoadError`, not collapse to nil.")
    }

    // MARK: - B2: walk-error visibility

    /// When a subdirectory is unreadable (permission denied, bad symlink), the
    /// walk must surface the error via `lastIndexWarnings` so the coordinator
    /// can publish it to the UI and the user understands WHY the index is
    /// sparser than expected — instead of a silent truncation.
    func testBuild_unreadableSubdir_recordsWalkWarning() async throws {
        try write("A.swift", content: "class Foo {}")
        let blocked = tempDir.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "secret".write(to: blocked.appendingPathComponent("x.txt"),
                           atomically: true, encoding: .utf8)
        // Strip all permissions on the subdir — contentsOfDirectory throws EACCES.
        chmod(blocked.path, 0o000)
        defer { chmod(blocked.path, 0o700) }

        let service = makeService()
        let index = await service.loadOrBuild()
        let warnings = await service.lastIndexWarnings

        XCTAssertEqual(index.files.count, 1, "Readable A.swift still indexed.")
        XCTAssertFalse(warnings.isEmpty,
                       "Unreadable subdir must surface at least one walk warning — got: \(warnings)")
    }

    /// Guard against the related B2 case: a work-folder walk that yields zero
    /// files (everything filtered out or unreadable) must still record a
    /// warning when any I/O error was observed — don't cache a clean-looking
    /// empty index.
    func testBuild_emptyResultAfterWalkErrors_surfacesWarning() async throws {
        // Only content is an unreadable subdir — walk yields zero files AND
        // hits an error. Without the warning, the resulting empty index would
        // be indistinguishable from "root is truly empty".
        let blocked = tempDir.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "secret".write(to: blocked.appendingPathComponent("x.txt"),
                           atomically: true, encoding: .utf8)
        chmod(blocked.path, 0o000)
        defer { chmod(blocked.path, 0o700) }

        let service = makeService()
        let index = await service.loadOrBuild()
        let warnings = await service.lastIndexWarnings

        XCTAssertEqual(index.files.count, 0)
        XCTAssertFalse(warnings.isEmpty,
                       "Empty-walk-after-error must not masquerade as a clean empty root.")
    }

    func testBuild_skipsInternalDir() async throws {
        try write(".nanoteams/internal/search_index.json", content: "class SecretType {}")
        try write("A.swift", content: "class Foo {}")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertEqual(index.files.first?.path, "A.swift")
        XCTAssertFalse(index.tokens.contains("secrettype"))
    }

    func testBuild_respectsTextSizeCap() async throws {
        // Synthesize a > 1MB text file. Contents should NOT contribute tokens,
        // but the filename stem still should.
        let big = String(repeating: "hugevocabbody ", count: 80_000) // ≈ 1.1 MB
        try write("BigFile.swift", content: big)
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        // Filename tokens survive
        XCTAssertTrue(index.tokens.contains("bigfile"))
        XCTAssertTrue(index.tokens.contains("big"))
        XCTAssertTrue(index.tokens.contains("file"))
        // Content token should NOT be in vocabulary
        XCTAssertFalse(index.tokens.contains("hugevocabbody"))
    }

    func testBuild_skipsNodeModules() async throws {
        try write("node_modules/pkg/module.js", content: "class InsideNodeModules {}")
        try write("app.js", content: "class AppHost {}")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("apphost"))
        XCTAssertFalse(index.tokens.contains("insidenodemodules"))
    }

    func testBuild_indexesAttachmentsUnderNanoteams() async throws {
        // `.nanoteams/tasks/{id}/attachments/` is LLM-visible user content —
        // the walker must traverse into it even though it lives under the
        // `.nanoteams/` subtree (only `internal/` is hidden).
        try write(".nanoteams/tasks/42/attachments/snippet.swift",
                  content: "class AttachedWidget {}")
        try write("Main.swift", content: "class Root {}")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 2, "Both attachment and top-level file must index.")
        XCTAssertTrue(index.tokens.contains("attachedwidget"),
                      "Body tokens from attachment content must be in vocabulary.")
        XCTAssertTrue(index.tokens.contains("root"))
    }

    func testBuild_skipsNanoteamsGitignore() async throws {
        // `.nanoteams/.gitignore` is bookkeeping written by
        // `NTMSRepository.ensureLayout`. It would otherwise surface
        // "gitignore" as a token in every open folder.
        try write(".nanoteams/.gitignore", content: "internal/\n")
        try write("App.swift", content: "class Widget {}")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertEqual(index.files.first?.path, "App.swift")
        XCTAssertFalse(index.tokens.contains("gitignore"))
    }

    // MARK: - Postings round-trip

    func testPostings_mapTokenToFileIDs() async throws {
        try write("A.swift", content: "scroll")
        try write("B.swift", content: "scroll view")
        try write("C.swift", content: "view")
        let service = makeService()
        let index = await service.loadOrBuild()
        // All three files should have at least one posting.
        XCTAssertEqual(index.files.count, 3)
        let scrollIDs = index.postings["scroll"] ?? []
        let viewIDs = index.postings["view"] ?? []
        XCTAssertEqual(Set(scrollIDs).count, 2) // A, B
        XCTAssertEqual(Set(viewIDs).count, 2) // B, C
        // Sorted ascending
        XCTAssertEqual(scrollIDs, scrollIDs.sorted())
    }

    /// A file's content tokens must belong to THAT file.
    ///
    /// The invariant the parallel rebuild rests on, and the one the suite did not have: passes
    /// are dispatched `concurrency` at a time and arrive in COMPLETION order, so the merge folds
    /// them back by candidate index. Get that wrong and every posting list still has the right
    /// SHAPE — the same tokens, the same number of files per token — while pointing at the wrong
    /// files. Measured: reversing the fold left the whole 93-case index suite green.
    ///
    /// The fixture is deliberately ASYMMETRIC (distinct token per file, and sizes spanning two
    /// orders of magnitude so a big early file finishes after a small later one). A symmetric
    /// one is what hid this: `A:scroll, B:scroll+view, C:view` reversed is
    /// `A:view, B:scroll+view, C:scroll`, which has identical per-token counts.
    ///
    /// RED: fold the passes in any order but candidate order (`zip(candidates, passes.reversed())`)
    /// → every `files(containing:)` here names the wrong file.
    func testPostings_attributeTokensToTheFileTheyCameFrom() async throws {
        // Sizes vary ~500x so completion order cannot track walk order.
        let filler = String(repeating: "padding token noise here\n", count: 500)
        try write("a_first.swift", content: "let alphaonly = 1\n" + filler)
        try write("b_second.swift", content: "let betaonly = 2\n")
        try write("c_third.swift", content: "let gammaonly = 3\n" + filler)
        try write("d_fourth.swift", content: "let deltaonly = 4\n")

        let service = makeService()
        let index = await service.loadOrBuild()

        XCTAssertEqual(index.files.count, 4, "anti-vacuum: all four must be indexed")
        for (token, expected) in [("alphaonly", "a_first.swift"), ("betaonly", "b_second.swift"),
                                  ("gammaonly", "c_third.swift"), ("deltaonly", "d_fourth.swift")] {
            let owners = await service.files(containing: [token])
            XCTAssertEqual(owners, [expected],
                           "'\(token)' must map to \(expected) and nothing else")
        }
    }

    func testFilesContaining_unionDedupSorted() async throws {
        try write("A.swift", content: "scroll")
        try write("B.swift", content: "scroll view")
        try write("C.swift", content: "view")
        let service = makeService()
        _ = await service.loadOrBuild()
        let paths = await service.files(containing: ["scroll", "view"])
        // A + B + C = 3 unique
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths, paths.sorted())
    }

    func testFilesContaining_emptyLookup_returnsEmpty() async throws {
        try write("A.swift", content: "scroll")
        let service = makeService()
        _ = await service.loadOrBuild()
        let paths = await service.files(containing: ["doesnotexist"])
        XCTAssertEqual(paths, [])
    }

    // MARK: - Signature-based rebuild detection

    func testSignatureDrift_fileAdded_reportsMismatch() async throws {
        try write("A.swift", content: "one")
        let service = makeService()
        let index = await service.loadOrBuild()
        try write("B.swift", content: "two")
        let matches = await service.matchesFolder(signature: index.signature)
        XCTAssertFalse(matches, "A new file should cause signature mismatch.")
    }

    func testSignatureDrift_fileSizeChanged_reportsMismatch() async throws {
        try write("A.swift", content: "one")
        let service = makeService()
        let index = await service.loadOrBuild()
        try write("A.swift", content: "one two three four") // same name, larger
        let matches = await service.matchesFolder(signature: index.signature)
        XCTAssertFalse(matches, "Size change should cause signature mismatch.")
    }

    // MARK: - Round-trip via disk

    func testPersistence_roundTrip() async throws {
        try write("A.swift", content: "hello world scrollview")
        let service = makeService()
        let first = await service.loadOrBuild()
        // Creating a fresh service should read the on-disk file.
        let service2 = makeService()
        let second = await service2.loadOrBuild()
        XCTAssertEqual(first.files, second.files)
        XCTAssertEqual(first.tokens, second.tokens)
        XCTAssertEqual(first.signature, second.signature)
    }

    // MARK: - Clear

    func testClear_removesOnDiskFile() async throws {
        try write("A.swift", content: "hello")
        let service = makeService()
        _ = await service.loadOrBuild()
        let indexFile = internalDir.appendingPathComponent("search_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))
        await service.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexFile.path))
        let clearError = await service.lastClearError
        XCTAssertNil(clearError, "Successful clear must leave lastClearError nil.")
    }

    /// Without surfaced clear errors, a locked / read-only on-disk index
    /// silently survives `clear()`. The next `loadOrBuild` reads the stale
    /// copy and the user — who explicitly clicked "Clear → Rebuild" — sees
    /// the OLD index with no signal of why.
    func testClear_failure_surfacesLastClearError() async throws {
        try write("A.swift", content: "hello")
        let service = makeService()
        _ = await service.loadOrBuild()
        let indexFile = internalDir.appendingPathComponent("search_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))

        // Lock the parent directory: chmod 0o500 strips the write bit so
        // `removeItem` fails with EACCES on macOS. Restore in defer so the
        // tearDown can clean up.
        chmod(internalDir.path, 0o500)
        defer { chmod(internalDir.path, 0o700) }

        await service.clear()
        let clearError = await service.lastClearError
        XCTAssertNotNil(clearError,
                        "Failed removeItem must surface via lastClearError, not silently succeed.")
    }

    func testClear_noOnDiskFile_isNotAnError() async {
        // Calling clear() on a fresh service (no index ever built) must NOT
        // set lastClearError — there's nothing to remove and that's not a
        // failure mode.
        let service = makeService()
        await service.clear()
        let clearError = await service.lastClearError
        XCTAssertNil(clearError, "clear() with no on-disk file must not be an error.")
    }

    // MARK: - Symlink cycle detection

    /// Without cycle detection in `walkRecursive`, a symlink pointing at an
    /// ancestor (`a/loop -> a/`) infinite-recurses and stack-overflows the
    /// walker — `fileManager.fileExists(isDirectory:)` follows symlinks, so
    /// the loop reports as a directory and we descend into it forever. Real
    /// users with synced folders (Dropbox, iCloud) hit this. The walker must
    /// detect the cycle, record a warning, and complete.
    func testWalk_symlinkCycle_terminatesAndRecordsWarning() async throws {
        try write("A.swift", content: "class Foo {}")
        let nested = tempDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "class Bar {}".write(
            to: nested.appendingPathComponent("Bar.swift"),
            atomically: true, encoding: .utf8
        )
        // nested/loop -> nested/  (cycle)
        let loopURL = nested.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loopURL, withDestinationURL: nested)

        // Race-bound the test: if cycle detection is broken, the walker
        // infinite-recurses synchronously inside the actor and never returns.
        // We can't truly time-bound a sync stack-overflow path from outside,
        // but reaching the assertion at all means the walker terminated.
        let service = makeService()
        let index = await service.loadOrBuild()

        // A.swift + nested/Bar.swift = 2 real files. The cycle should NOT
        // produce duplicate or extra file entries.
        XCTAssertEqual(index.files.count, 2,
                       "Real files indexed; cycle didn't introduce phantom entries.")
        XCTAssertTrue(index.tokens.contains("foo"))
        XCTAssertTrue(index.tokens.contains("bar"))

        let warnings = await service.lastIndexWarnings
        XCTAssertTrue(warnings.contains { $0.contains("symlink cycle") },
                      "Cycle skip must surface as a walk warning — got: \(warnings)")
    }

    /// A symlink to a sibling (NOT cyclical) should still be followed once.
    /// Confirms the cycle guard doesn't over-prune harmless symlinks.
    func testWalk_symlinkToSibling_indexesTargetOnce() async throws {
        try write("real/A.swift", content: "class RealOne {}")
        // mirror -> real/
        let mirrorURL = tempDir.appendingPathComponent("mirror")
        let realURL = tempDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: mirrorURL, withDestinationURL: realURL)

        let service = makeService()
        let index = await service.loadOrBuild()

        // The target IS reachable through both `real/` and `mirror/`. Both
        // canonicalize to the same path, so the second visit is skipped as a
        // cycle. We end up with one file entry — correct.
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("realone"))
    }

    /// A symlink to a FILE is indexed under the link's path, with the TARGET's size and mTime.
    ///
    /// Sibling of `testWalk_symlinkToSibling_indexesTargetOnce`, which links to a DIRECTORY —
    /// and the two take different arms: for a directory the prefetched `.fileSizeKey` is nil and
    /// the walk descends, for a file it is the number the `IndexSignature` is built from. The
    /// signature is why this matters: taking the LINK's size (a few bytes of path) instead of
    /// the target's would make every walk disagree with the last and rebuild forever.
    ///
    /// RED: return the LINK's resource values instead of resolving (drop the `isSymbolicLink`
    /// arm of `entryAttributes`) → `size` is the link's, not the 4 000-byte target's.
    func testWalk_symlinkToFile_indexesTargetSizeUnderTheLinkPath() async throws {
        let body = String(repeating: "x", count: 4000)
        try write("real.swift", content: body)
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("alias.swift"),
            withDestinationURL: tempDir.appendingPathComponent("real.swift"))

        let service = makeService()
        let index = await service.loadOrBuild()

        let alias = try XCTUnwrap(index.files.first { $0.path == "alias.swift" },
                                  "the link must be indexed under its OWN path: "
                                      + "\(index.files.map(\.path))")
        let real = try XCTUnwrap(index.files.first { $0.path == "real.swift" })
        XCTAssertEqual(alias.size, real.size,
                       "the link must carry its TARGET's size, not the path's length")
        XCTAssertGreaterThan(alias.size, 3000, "anti-vacuum: the target is the big one")
        XCTAssertEqual(alias.mTime, real.mTime)
    }

    // MARK: - Per-file I/O failure surfacing

    /// A file the walk can stat but cannot READ contributes its filename tokens and a correct
    /// roster entry — and says so — rather than vanishing or arriving empty in silence.
    ///
    /// `chmod 0o000` blocks the read, not the stat, and that distinction is the whole test: the
    /// entry's mTime and size are real, so the `IndexSignature` stays honest, while the content
    /// pass fails and must leave a trace. The version this replaces asserted on the ATTRIBUTE
    /// read instead, and stat does not fail for a 0o000 file — so it took its
    /// "nothing to assert" branch on every non-root machine, which is every machine.
    ///
    /// RED: swallow the `catch` in `indexOne` without appending a warning → the warning
    /// assertion fails while the token assertions stay green, which is the silent half.
    func testBuild_unreadableFileContents_indexesFilenameTokensAndWarns() async throws {
        try write("A.swift", content: "class Foo {}")
        try write("secretive.swift", content: "class HiddenSymbol {}")
        let secret = tempDir.appendingPathComponent("secretive.swift")
        chmod(secret.path, 0o000)
        defer { chmod(secret.path, 0o600) }
        // Root can read anything, so the arrangement itself has to be verified.
        try XCTSkipIf((try? Data(contentsOf: secret)) != nil,
                      "running as root — the read did not fail, so nothing here is exercised")

        let service = makeService()
        let index = await service.loadOrBuild()
        let warnings = await service.lastIndexWarnings
        let contentTokens = await service.files(containing: ["hiddensymbol"])
        let nameTokens = await service.files(containing: ["secretive"])

        XCTAssertTrue(index.files.contains { $0.path == "secretive.swift" },
                      "the entry must survive: its mTime and size read fine, and dropping it "
                          + "would move the signature")
        XCTAssertTrue(contentTokens.isEmpty, "its content could not be read, so it has no "
            + "content tokens")
        XCTAssertFalse(nameTokens.isEmpty, "its filename tokens are still indexable")
        XCTAssertTrue(warnings.contains { $0.contains("content read failed") },
                      "the omission must be written down, not silent — got: \(warnings)")
    }

    // MARK: - Actor serializes concurrent calls

    func testConcurrent_loadOrBuild_serializesViaActor() async throws {
        try write("A.swift", content: "hello scrollview")
        let service = makeService()
        // Spawn two concurrent builds; the actor must serialize them.
        async let a = service.loadOrBuild()
        async let b = service.loadOrBuild()
        let (first, second) = await (a, b)
        XCTAssertEqual(first.files, second.files)
        XCTAssertEqual(first.tokens, second.tokens)
    }

    // MARK: - Single-flight

    /// Two callers arriving at once must produce ONE walk of the tree, not two.
    ///
    /// The actor used to buy this for free: `loadOrBuild` was synchronous, so
    /// `matchesFolder` → `rebuildIndex()` → `cached = fresh` could not be interleaved. Actor
    /// REENTRANCY is exactly what that reading misses — the moment the rebuild can suspend, a
    /// second caller wedges in, sees `cached == nil`, and walks the whole tree again.
    ///
    /// `generatedAt` is the observation, and it is exact rather than statistical: it comes from
    /// `MonotonicClock`, which guarantees each call a value strictly greater than the last. Two
    /// builds therefore CANNOT stamp the same instant, so equality here is proof of one build.
    ///
    /// Deterministic despite the concurrency: from actor entry to `inFlightBuild = build` there
    /// is no suspension point, so whichever caller wins the race has claimed the slot before it
    /// suspends, and the other necessarily finds it.
    ///
    /// RED: delete the `if !force, let existing = inFlightBuild` join → the two indices carry
    /// different `generatedAt`.
    func testLoadOrBuild_concurrentCallers_shareOneBuild() async throws {
        for i in 0..<40 { try write("pkg\(i % 4)/f\(i).swift", content: "let token\(i) = \(i)\n") }
        let service = makeService()

        async let first = service.loadOrBuild()
        async let second = service.loadOrBuild()
        let (a, b) = await (first, second)

        XCTAssertFalse(a.files.isEmpty, "anti-vacuum: the build must have found the tree")
        XCTAssertEqual(a.generatedAt, b.generatedAt,
                       "both callers must have shared ONE build; different stamps mean the tree "
                           + "was walked twice")
        XCTAssertEqual(a.files.map(\.path), b.files.map(\.path))
    }

    /// `force: true` means "reuse NOTHING" — not the cache, not the on-disk copy, not a walk
    /// already in flight.
    ///
    /// All three routes sit under ONE `if !force` in `loadOrBuild`, which is what makes this
    /// test a pin on the RULE rather than on the cache arm alone. The in-flight arm cannot be
    /// reached from a test on its own: observing that window means blocking the actor mid-build,
    /// and the only way to arrange it is a seam that would exist purely for the test. Folding
    /// the three conditions into one is how that arm gets covered anyway.
    ///
    /// The folder is deliberately left UNCHANGED between the two calls. A fixture that writes a
    /// file first proves nothing: the new file moves the `IndexSignature`, `matchesFolder`
    /// returns false, and the rebuild happens for that reason whether `force` was honoured or
    /// not. Measured — with `if !force` mutated to `if true`, such a fixture stayed green.
    ///
    /// RED: change `if !force` to `if true` → the forced call returns the cached index and the
    /// two `generatedAt` stamps are equal.
    func testLoadOrBuild_forceReusesNothing() async throws {
        for i in 0..<20 { try write("f\(i).swift", content: "let token\(i) = \(i)\n") }
        let service = makeService()

        let cached = await service.loadOrBuild()
        let forced = await service.loadOrBuild(force: true)

        XCTAssertFalse(cached.files.isEmpty, "anti-vacuum: the first build must have found the tree")
        XCTAssertNotEqual(
            cached.generatedAt, forced.generatedAt,
            "a forced rebuild must walk again even when the cache still matches the folder")
        XCTAssertEqual(cached.files.map(\.path), forced.files.map(\.path),
                       "the unchanged folder must still produce the same roster")
    }

    /// The other half of the same rule: WITHOUT `force`, an unchanged folder must be served from
    /// the cache rather than re-walked. Otherwise "force" would be indistinguishable from the
    /// default and the test above would pass for the wrong reason.
    ///
    /// RED: drop the `reuseExistingIndex()` probe from `loadOrBuild` → the second call rebuilds
    /// and the stamps differ.
    func testLoadOrBuild_withoutForce_servesAnUnchangedFolderFromTheCache() async throws {
        for i in 0..<20 { try write("f\(i).swift", content: "let token\(i) = \(i)\n") }
        let service = makeService()

        let first = await service.loadOrBuild()
        let second = await service.loadOrBuild()

        XCTAssertEqual(first.generatedAt, second.generatedAt,
                       "an unchanged folder must not be walked twice")
    }

    /// The slot is released when its build finishes, or the second search of the session waits
    /// on a task that already returned and every later one joins a corpse.
    ///
    /// RED: never clear `inFlightBuild` → the second call returns the FIRST build's
    /// `generatedAt` even though the folder changed under it.
    func testLoadOrBuild_releasesTheSlotAfterTheBuildCompletes() async throws {
        try write("a.swift", content: "let alpha = 1\n")
        let service = makeService()
        let first = await service.loadOrBuild()

        try write("b.swift", content: "let beta = 2\n")
        let second = await service.loadOrBuild()

        XCTAssertNotEqual(first.generatedAt, second.generatedAt,
                          "the changed folder must produce a fresh build, not a joined stale one")
        XCTAssertTrue(second.files.contains { $0.path == "b.swift" })
    }
}
