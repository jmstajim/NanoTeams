import XCTest
@testable import NanoTeams

/// Edge cases for `SearchIndexService` beyond the happy-path coverage in
/// `SearchIndexServiceTests`. Focused on data-corruption recovery,
/// version gating, symbolic oddities, and boundary sizes.
final class SearchIndexServiceEdgeCasesTests: XCTestCase {

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

    private func makeService() -> SearchIndexService {
        SearchIndexService(workFolderRoot: tempDir, internalDir: internalDir, fileManager: fm)
    }

    private var indexFileURL: URL {
        internalDir.appendingPathComponent("search_index.json")
    }

    // MARK: - Disk corruption

    func testDiskCorruption_malformedJSON_rebuildsFromScratch() async throws {
        try write("A.swift", content: "class Alpha {}")
        let service = makeService()
        let first = await service.loadOrBuild()
        XCTAssertEqual(first.files.count, 1)

        // Corrupt the on-disk index.
        try "not valid JSON".write(to: indexFileURL, atomically: true, encoding: .utf8)
        let service2 = makeService()
        // loadOrBuild should detect the corruption and rebuild.
        let rebuilt = await service2.loadOrBuild()
        XCTAssertEqual(rebuilt.files.count, 1)
        XCTAssertTrue(rebuilt.tokens.contains("alpha"))
    }

    func testDiskCorruption_oldVersion_rebuildsFromScratch() async throws {
        try write("A.swift", content: "class Alpha {}")
        let service = makeService()
        _ = await service.loadOrBuild()

        // Re-persist with a bogus version to simulate an old/future schema.
        struct AnyEncodable: Encodable { let v: Int; let f: [String] = []; let t: [String] = []
            enum CodingKeys: String, CodingKey { case version, files, tokens }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(v, forKey: .version)
                try c.encode(f, forKey: .files)
                try c.encode(t, forKey: .tokens)
            }
        }
        let dummy = AnyEncodable(v: 9999)
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(dummy)
        try data.write(to: indexFileURL)

        // Fresh service must reject the bogus-version blob and rebuild.
        let service2 = makeService()
        let rebuilt = await service2.loadOrBuild()
        XCTAssertEqual(rebuilt.version, SearchIndex.currentVersion)
        XCTAssertEqual(rebuilt.files.count, 1)
    }

    // MARK: - Empty folder

    func testEmptyFolder_buildsEmptyIndex() async {
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.count, 0)
        XCTAssertEqual(index.tokens.count, 0)
        XCTAssertEqual(index.postings.count, 0)
        XCTAssertEqual(index.signature.fileCount, 0)
        XCTAssertEqual(index.signature.totalSize, 0)
    }

    // MARK: - Duplicate tokens across files

    func testDuplicateToken_postingDeduplicated() async throws {
        // Both files have the same token — posting list for "alpha" must list
        // each file ID exactly once.
        try write("A.swift", content: "alpha alpha alpha alpha")
        try write("B.swift", content: "alpha ALPHA Alpha")
        let service = makeService()
        let index = await service.loadOrBuild()
        let postings = index.postings["alpha"] ?? []
        XCTAssertEqual(postings, Array(Set(postings)).sorted())
        XCTAssertEqual(postings.count, 2)
    }

    // MARK: - Mixed scripts across files

    func testMultilingual_postingsHandleCyrillicAndLatin() async throws {
        try write("ScrollView.swift", content: "let прокрутка = ScrollView()")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertTrue(index.postings["прокрутка"] != nil)
        XCTAssertTrue(index.postings["scrollview"] != nil)
        XCTAssertTrue(index.postings["scroll"] != nil)
        XCTAssertTrue(index.postings["view"] != nil)
    }

    // MARK: - files(containing:) corner cases

    func testFilesContaining_tokenAbsent_returnsEmpty() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        _ = await service.loadOrBuild()
        let none = await service.files(containing: ["notindexed"])
        XCTAssertEqual(none, [])
    }

    func testFilesContaining_emptyTermList_returnsEmpty() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        _ = await service.loadOrBuild()
        let none = await service.files(containing: [])
        XCTAssertEqual(none, [])
    }

    func testFilesContaining_caseInsensitive() async throws {
        try write("A.swift", content: "Alpha")
        let service = makeService()
        _ = await service.loadOrBuild()
        let hitLower = await service.files(containing: ["alpha"])
        let hitUpper = await service.files(containing: ["ALPHA"])
        XCTAssertEqual(hitLower, ["A.swift"])
        XCTAssertEqual(hitUpper, ["A.swift"])
    }

    // MARK: - vocabulary ranking tiers

    func testVocabulary_prefixTier_beforeContainsTier() async throws {
        try write("A.swift", content: "scroll scrollbar makeScroll interscroll")
        let service = makeService()
        _ = await service.loadOrBuild()
        let vocab = await service.vocabulary(matching: "scroll", limit: 10)
        // Exact "scroll" is tier 0; "scrollbar" starts with "scroll" → tier 1;
        // "interscroll" contains "scroll" → tier 2. Order must preserve tiers.
        let scrollIdx = vocab.firstIndex(of: "scroll") ?? .max
        let scrollbarIdx = vocab.firstIndex(of: "scrollbar") ?? .max
        let interscrollIdx = vocab.firstIndex(of: "interscroll") ?? .max
        XCTAssertLessThan(scrollIdx, scrollbarIdx)
        XCTAssertLessThan(scrollbarIdx, interscrollIdx)
    }

    func testVocabulary_respectsLimit() async throws {
        let body = (0..<50).map { "token\($0)" }.joined(separator: " ")
        try write("A.swift", content: body)
        let service = makeService()
        _ = await service.loadOrBuild()
        let limited = await service.vocabulary(matching: "token", limit: 5)
        XCTAssertLessThanOrEqual(limited.count, 5)
    }

    // MARK: - Force rebuild

    func testForceRebuild_regeneratesEvenIfSignatureMatches() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        let first = await service.loadOrBuild()
        // Wait a millisecond to guarantee `generatedAt` advances past the first build.
        try await Task.sleep(nanoseconds: 2_000_000)
        let second = await service.loadOrBuild(force: true)
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertGreaterThan(second.generatedAt, first.generatedAt,
                             "Force rebuild must produce a fresh generatedAt.")
    }

    // MARK: - Nested deep paths

    func testDeepNestedPaths_indexed() async throws {
        try write("a/b/c/d/e/Deep.swift", content: "class DeepType {}")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertEqual(index.files.first?.path, "a/b/c/d/e/Deep.swift")
        XCTAssertTrue(index.tokens.contains("deeptype"))
    }

    // MARK: - Signature: same mTime + size preserved after no-op rebuild

    func testSignatureStable_noChanges_sameSignatureAcrossBuilds() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        let first = await service.loadOrBuild()
        let second = await service.loadOrBuild()
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertEqual(first.tokens, second.tokens)
    }

    // MARK: - Clear is idempotent

    func testClearTwice_isSafe() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        _ = await service.loadOrBuild()
        await service.clear()
        await service.clear()
        XCTAssertFalse(fm.fileExists(atPath: indexFileURL.path))
    }

    // MARK: - Cross-script vocabulary fallback

    func testVocabulary_cyrillicQuery_surfacesAsciiTokensFromIndex() async throws {
        // A codebase with both Cyrillic and English identifiers. A Cyrillic
        // query shares no 3-char substrings with the English tokens, so
        // tiers 0-3 can only surface the Cyrillic ones. The cross-script
        // fallback should append the English tokens so the LLM can translate.
        try write("Loader.swift", content: "func загрузитьФайл() {}\nfunc loadFile() {}")
        try write("Downloader.swift", content: "class Downloader { func startDownload() {} }")
        let service = makeService()
        _ = await service.loadOrBuild()

        let vocab = await service.vocabulary(matching: "загрузка", limit: 20)
        // Cyrillic tier3 matches expected:
        XCTAssertTrue(vocab.contains("загрузитьфайл"))
        // Cross-script fallback must also include the ASCII tokens:
        XCTAssertTrue(vocab.contains("loadfile"),
                      "cross-script fallback should include ASCII tokens — got \(vocab)")
        XCTAssertTrue(vocab.contains("downloader"),
                      "cross-script fallback should include ASCII tokens — got \(vocab)")
    }

    func testVocabulary_englishQuery_surfacesCyrillicTokensFromIndex() async throws {
        // Reverse direction: English query against a mixed index should
        // surface the Cyrillic tokens via the fallback.
        try write("Store.swift", content: "class Store { func синхронизация() {} }")
        try write("Fetcher.swift", content: "class Fetcher { func syncData() {} }")
        let service = makeService()
        _ = await service.loadOrBuild()

        let vocab = await service.vocabulary(matching: "synchronization", limit: 20)
        // Existing tier match (prefix/fuzzy) for ASCII tokens still works:
        XCTAssertTrue(vocab.contains("syncdata") || vocab.contains("sync"))
        // Cross-script fallback adds the Cyrillic token:
        XCTAssertTrue(vocab.contains("синхронизация"),
                      "cross-script fallback should include Cyrillic token — got \(vocab)")
    }

    func testVocabulary_tieredMatchesPreservedBeforeTopUp() async throws {
        // When tier 0-3 matches exist, they must come first in the output.
        // The sparse-vocabulary top-up (phase A/B) only appends AFTER the
        // tiered matches.
        try write("A.swift", content: "class Scroll { func scrollView() {} }")
        try write("B.swift", content: "class Unrelated { func other() {} }")
        let service = makeService()
        _ = await service.loadOrBuild()

        let vocab = await service.vocabulary(matching: "scroll", limit: 20)
        // Tier 0 (`scroll`) and tier 1 (`scrollview`) must lead.
        let scrollIdx = vocab.firstIndex(of: "scroll") ?? .max
        let scrollviewIdx = vocab.firstIndex(of: "scrollview") ?? .max
        let unrelatedIdx = vocab.firstIndex(of: "unrelated") ?? .max
        XCTAssertLessThan(scrollIdx, unrelatedIdx,
                          "tier 0 match must precede any fallback top-up — got \(vocab)")
        XCTAssertLessThan(scrollviewIdx, unrelatedIdx,
                          "tier 1 match must precede any fallback top-up — got \(vocab)")
    }

    func testVocabulary_smallIndex_sameScriptTopUpIncludesAdjacentAbbreviations() async throws {
        // Query "drag and drop" doesn't share 3-char substrings with `dnd` or
        // `dndview`, so the tiered matcher misses them. Phase-B top-up must
        // surface them so the LLM has a chance to pick them.
        try write("DragDropController.swift",
                  content: "class DragDropController { func onDropTarget() {} }")
        try write("DnDView.swift", content: "class DnDView {}")
        try write("ListView.swift", content: "class ListView {}")
        let service = makeService()
        _ = await service.loadOrBuild()

        let vocab = await service.vocabulary(matching: "drag and drop", limit: 20)
        XCTAssertTrue(vocab.contains("dragdropcontroller"))
        // Abbreviations surface via phase-B top-up:
        XCTAssertTrue(vocab.contains("dndview"),
                      "phase-B top-up should surface abbreviation-adjacent tokens — got \(vocab)")
    }

    func testVocabulary_cjkIndex_asciiQuerySurfacesCJKTokens() async throws {
        // Cross-script fallback must be language-agnostic — works for any
        // non-ASCII script, not just Cyrillic. Chinese identifiers indexed
        // alongside English should surface for an English query.
        try write("DB.swift", content: "class Database { func 查询() {} }")
        try write("Net.swift", content: "class 网络 {}")
        let service = makeService()
        _ = await service.loadOrBuild()

        let vocab = await service.vocabulary(matching: "database", limit: 20)
        XCTAssertTrue(vocab.contains("database"))
        // Chinese tokens surface via cross-script fallback:
        XCTAssertTrue(vocab.contains("查询") || vocab.contains("网络"),
                      "cross-script fallback should work for any non-ASCII script — got \(vocab)")
    }
}
