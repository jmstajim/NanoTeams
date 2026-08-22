import XCTest
@testable import NanoTeams

/// Edge cases for `SearchIndexService` beyond the happy-path coverage in
/// `SearchIndexServiceTests`. Focused on data-corruption recovery,
/// version gating, symbolic oddities, and boundary sizes.
final class SearchIndexServiceEdgeCasesTests: XCTestCase {

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

    private func makeService() -> SearchIndexService {
        SearchIndexService(workFolderRoot: tempDir, internalDir: internalDir, fileManager: .default)
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

 

    // MARK: - Force rebuild

    func testForceRebuild_regeneratesEvenIfSignatureMatches() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        let first = await service.loadOrBuild()
        // Wait a millisecond to guarantee `generatedAt` advances past the first build.
        try await Task.sleep(for: .milliseconds(2))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexFileURL.path))
    }

 



}
