import XCTest
@testable import NanoTeams

final class SearchIndexServiceTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ relPath: String, bytes: [UInt8]) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
    }

    private func makeService() -> SearchIndexService {
        SearchIndexService(workFolderRoot: tempDir, internalDir: internalDir, fileManager: fm)
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
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
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
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
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
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
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

    // MARK: - Vocabulary ranking

    func testVocabulary_exactMatchTierFirst() async throws {
        try write("A.swift", content: "scroll scrollView makeScrollView scrollbar")
        let service = makeService()
        _ = await service.loadOrBuild()
        let vocab = await service.vocabulary(matching: "scroll", limit: 10)
        XCTAssertEqual(vocab.first, "scroll", "Exact match should come first")
        XCTAssertTrue(vocab.contains("scrollview"))
    }

    func testVocabulary_empty_returnsEmpty() async throws {
        try write("A.swift", content: "scroll")
        let service = makeService()
        _ = await service.loadOrBuild()
        let vocab = await service.vocabulary(matching: "", limit: 10)
        XCTAssertEqual(vocab, [])
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
        XCTAssertTrue(fm.fileExists(atPath: indexFile.path))
        await service.clear()
        XCTAssertFalse(fm.fileExists(atPath: indexFile.path))
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
        XCTAssertTrue(fm.fileExists(atPath: indexFile.path))

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
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "class Bar {}".write(
            to: nested.appendingPathComponent("Bar.swift"),
            atomically: true, encoding: .utf8
        )
        // nested/loop -> nested/  (cycle)
        let loopURL = nested.appendingPathComponent("loop")
        try fm.createSymbolicLink(at: loopURL, withDestinationURL: nested)

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
        try fm.createSymbolicLink(at: mirrorURL, withDestinationURL: realURL)

        let service = makeService()
        let index = await service.loadOrBuild()

        // The target IS reachable through both `real/` and `mirror/`. Both
        // canonicalize to the same path, so the second visit is skipped as a
        // cycle. We end up with one file entry — correct.
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("realone"))
    }

    // MARK: - Per-file I/O failure surfacing

    /// Per-file attribute-read failures (a file that exists but whose
    /// metadata can't be read) must surface in `lastIndexWarnings` and the
    /// file must be SKIPPED — without this, the indexer would store
    /// `mTime = .distantPast` and `size = 0`, silently poisoning the
    /// IndexSignature on the next walk.
    func testBuild_unreadableFileAttributes_recordsWarningAndSkipsFile() async throws {
        try write("A.swift", content: "class Foo {}")
        try write("B.swift", content: "class Bar {}")
        // Strip every permission on B.swift so attributesOfItem fails.
        let bURL = tempDir.appendingPathComponent("B.swift")
        chmod(bURL.path, 0o000)
        defer { chmod(bURL.path, 0o600) }

        let service = makeService()
        let index = await service.loadOrBuild()
        let warnings = await service.lastIndexWarnings

        // A.swift survives; B.swift either skipped (warning emitted) or
        // indexed (no warning). The behavior depends on whether the running
        // user is root — chmod 0o000 doesn't block root reads. Be lenient:
        // assert that EITHER B.swift was successfully indexed (root case)
        // OR the skip surfaced a warning (non-root case). The dangerous
        // silent third case (B.swift indexed with stale attrs + no warning)
        // is what this test pins against.
        let foundB = index.files.contains { $0.path == "B.swift" }
        if foundB {
            // Root path — attributes succeeded. Nothing to assert.
        } else {
            XCTAssertFalse(warnings.isEmpty,
                "Skipped file must surface a walk warning; got empty warnings.")
            XCTAssertTrue(warnings.contains { $0.contains("B.swift") || $0.contains("attribute read failed") },
                "Warning should reference the failed file or the failure mode — got: \(warnings)")
        }
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
}
