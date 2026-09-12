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
        XCTAssertTrue(rebuilt.vocabulary.contains("alpha"))
    }

    func testDiskCorruption_oldVersion_rebuildsFromScratch() async throws {
        try write("A.swift", content: "class Alpha {}")
        let service = makeService()
        _ = await service.loadOrBuild()

        // Re-persist with a bogus version to simulate an old/future schema.
        // Hand-rolled so the payload can carry a version the current shape would never
        // produce. Its keys must be the CURRENT ones — a fixture built from a retired shape
        // compiles happily against its own `CodingKeys` and goes stale in silence, which is
        // what `tokens` did here until 2026-09-11.
        struct AnyEncodable: Encodable {
            let v: Int
            let f: [String] = []
            let vocab: [String] = []
            enum CodingKeys: String, CodingKey { case version, files, vocabulary }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(v, forKey: .version)
                try c.encode(f, forKey: .files)
                try c.encode(vocab, forKey: .vocabulary)
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
        XCTAssertEqual(index.vocabulary.count, 0)
        XCTAssertEqual(index.signature.fileCount, 0)
        XCTAssertEqual(index.signature.totalSize, 0)
    }

    // MARK: - Duplicate words across files

    /// A word is a word, however many times and in whatever case it occurs. The posting-list
    /// dedup this replaces was about ID lists; a set has no such failure mode, so what is worth
    /// pinning now is the CASE FOLD — which `TokenExtractor` owns and which the vocabulary
    /// depends on for `expand`'s lookups to hit.
    func testDuplicateWord_appearsOnceCaseFolded() async throws {
        try write("A.swift", content: "alpha alpha alpha alpha")
        try write("B.swift", content: "alpha ALPHA Alpha")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertTrue(index.vocabulary.contains("alpha"))
        XCTAssertFalse(index.vocabulary.contains("ALPHA"))
        XCTAssertFalse(index.vocabulary.contains("Alpha"))
    }

    // MARK: - Mixed scripts across files

    func testMultilingual_vocabularyHoldsCyrillicAndLatin() async throws {
        try write("ScrollView.swift", content: "let прокрутка = ScrollView()")
        let service = makeService()
        let index = await service.loadOrBuild()
        XCTAssertTrue(index.vocabulary.contains("прокрутка"))
        XCTAssertTrue(index.vocabulary.contains("scrollview"))
        XCTAssertTrue(index.vocabulary.contains("scroll"))
        XCTAssertTrue(index.vocabulary.contains("view"))
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
        XCTAssertTrue(index.vocabulary.contains("deeptype"))
    }

    // MARK: - Signature: same mTime + size preserved after no-op rebuild

    func testSignatureStable_noChanges_sameSignatureAcrossBuilds() async throws {
        try write("A.swift", content: "alpha")
        let service = makeService()
        let first = await service.loadOrBuild()
        let second = await service.loadOrBuild()
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertEqual(first.vocabulary, second.vocabulary)
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
