import XCTest
@testable import NanoTeams

/// Structural invariants of the index after a build. If any of these fail
/// after a code change, the on-disk index can corrupt downstream search
/// behavior in subtle ways (e.g. out-of-bounds posting IDs in
/// `files(containing:)`).
final class SearchIndexInvariantsTests: XCTestCase {

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

    // MARK: - Postings invariants

    func testAllPostingIDs_inBoundsOfFilesArray() async throws {
        try write("A.swift", content: "alpha beta gamma")
        try write("B.swift", content: "delta beta epsilon")
        try write("C.swift", content: "zeta")
        let index = await makeService().loadOrBuild()
        let bound = index.files.count
        for (token, ids) in index.postings {
            for id in ids {
                XCTAssertGreaterThanOrEqual(id, 0,
                    "Posting for '\(token)' has negative ID \(id)")
                XCTAssertLessThan(id, bound,
                    "Posting for '\(token)' references out-of-range id \(id) (bound \(bound))")
            }
        }
    }

    func testAllPostingLists_sortedAscending() async throws {
        try write("A.swift", content: "alpha")
        try write("B.swift", content: "alpha beta")
        try write("C.swift", content: "alpha gamma")
        let index = await makeService().loadOrBuild()
        for (token, ids) in index.postings {
            XCTAssertEqual(ids, ids.sorted(),
                "Posting list for '\(token)' must be sorted ascending.")
        }
    }

    func testAllPostingLists_haveNoDuplicates() async throws {
        try write("A.swift", content: "alpha alpha alpha alpha")
        try write("B.swift", content: "alpha")
        let index = await makeService().loadOrBuild()
        for (token, ids) in index.postings {
            XCTAssertEqual(ids.count, Set(ids).count,
                "Posting list for '\(token)' contains duplicates: \(ids)")
        }
    }

    func testTokensVocabulary_matchesPostingsKeys() async throws {
        try write("A.swift", content: "alpha beta gamma")
        let index = await makeService().loadOrBuild()
        let tokenSet = Set(index.tokens)
        let postingsKeys = Set(index.postings.keys)
        XCTAssertEqual(tokenSet, postingsKeys,
            "tokens[] must equal Set(postings.keys) — same vocabulary surface.")
    }

    func testTokens_sortedAscending() async throws {
        try write("A.swift", content: "zebra alpha mango bird")
        let index = await makeService().loadOrBuild()
        XCTAssertEqual(index.tokens, index.tokens.sorted(),
            "tokens[] must be sorted ascending for stable LLM hint slicing.")
    }

    // MARK: - Signature invariants

    func testSignature_fileCount_equalsFilesArrayCount() async throws {
        try write("A.swift", content: "x")
        try write("B.swift", content: "y")
        try write("C.swift", content: "z")
        let index = await makeService().loadOrBuild()
        XCTAssertEqual(index.signature.fileCount, index.files.count)
    }

    func testSignature_totalSize_equalsSumOfFileSizes() async throws {
        try write("A.swift", content: "hello")  // 5 bytes
        try write("B.swift", content: "world!")  // 6 bytes
        let index = await makeService().loadOrBuild()
        let sumOfSizes = index.files.reduce(0) { $0 + Int64($1.size) }
        XCTAssertEqual(index.signature.totalSize, sumOfSizes)
    }

    func testSignature_maxMTime_equalsMaxOfFileMTimes() async throws {
        try write("A.swift", content: "alpha")
        try write("B.swift", content: "beta")
        let index = await makeService().loadOrBuild()
        let maxFileMTime = index.files.map(\.mTime).max() ?? .distantPast
        XCTAssertEqual(index.signature.maxMTime, maxFileMTime)
    }

    // MARK: - Files invariants

    func testFiles_pathsAreRelativeToWorkFolderRoot() async throws {
        try write("A.swift", content: "x")
        try write("nested/B.swift", content: "y")
        let index = await makeService().loadOrBuild()
        for file in index.files {
            XCTAssertFalse(file.path.hasPrefix("/"),
                "File path '\(file.path)' must be relative, not absolute.")
            XCTAssertFalse(file.path.contains(tempDir.path),
                "File path '\(file.path)' must not contain absolute prefix.")
        }
    }

    func testFiles_pathsHaveNoLeadingDotSlash() async throws {
        try write("A.swift", content: "x")
        let index = await makeService().loadOrBuild()
        for file in index.files {
            XCTAssertFalse(file.path.hasPrefix("./"),
                "File path '\(file.path)' has stray './' prefix.")
            XCTAssertFalse(file.path.hasPrefix("/"))
        }
    }

    // MARK: - Token presence invariants

    func testEveryFile_contributesAtLeastFilenameTokens() async throws {
        // Even a binary file with an unsupported extension should produce
        // filename tokens — guaranteeing the file doesn't fall out of the index.
        let url = tempDir.appendingPathComponent("UniqueBinaryName.bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        let index = await makeService().loadOrBuild()
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.tokens.contains("uniquebinaryname"),
            "Filename tokens must always land in the vocabulary.")
    }

    // MARK: - Path location of on-disk index

    func testIndexFile_landsInInternalDir() async throws {
        try write("A.swift", content: "x")
        _ = await makeService().loadOrBuild()
        let expected = internalDir.appendingPathComponent("search_index.json")
        XCTAssertTrue(fm.fileExists(atPath: expected.path),
            "Index must persist to .nanoteams/internal/search_index.json")
    }

    // MARK: - All files appear in at least one posting (or are empty)

    // MARK: - I6: throwing init catches hand-crafted invariants violations

    /// Out-of-bounds posting ID must be rejected at construction time, not at
    /// query time. Without the throwing init, a future caller could hand-roll
    /// `SearchIndex(... postings: ["x": [999]], files: [f])` and
    /// `files(containing:)` would silently drop the bad id — masking the bug.
    func testInit_postingIDOutOfBounds_throws() {
        XCTAssertThrowsError(try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "A.swift", mTime: Date(), size: 1)],
            tokens: ["x"],
            postings: ["x": [99]]
        ))
    }

    func testInit_tokensNotEqualToPostingsKeys_throws() {
        XCTAssertThrowsError(try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "A.swift", mTime: Date(), size: 1)],
            tokens: ["x", "stray"],  // "stray" not in postings
            postings: ["x": [0]]
        ))
    }

    func testInit_postingListWithDuplicates_throws() {
        XCTAssertThrowsError(try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "A.swift", mTime: Date(), size: 1)],
            tokens: ["x"],
            postings: ["x": [0, 0]]
        ))
    }

    func testInit_postingListNotSorted_throws() {
        XCTAssertThrowsError(try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 2, maxMTime: Date(), totalSize: 2),
            files: [
                IndexedFile(path: "A.swift", mTime: Date(), size: 1),
                IndexedFile(path: "B.swift", mTime: Date(), size: 1),
            ],
            tokens: ["x"],
            postings: ["x": [1, 0]]
        ))
    }

    func testInit_validIndex_succeeds() throws {
        let idx = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 2, maxMTime: Date(), totalSize: 2),
            files: [
                IndexedFile(path: "A.swift", mTime: Date(), size: 1),
                IndexedFile(path: "B.swift", mTime: Date(), size: 1),
            ],
            tokens: ["x"],
            postings: ["x": [0, 1]]
        )
        XCTAssertEqual(idx.files.count, 2)
    }

    func testEveryNonEmptyIndexedFile_appearsInAtLeastOnePosting() async throws {
        try write("Alpha.swift", content: "kw1 kw2 kw3")
        try write("Beta.swift", content: "kw4")
        try write("Gamma.swift", content: "")
        let index = await makeService().loadOrBuild()
        // Empty file still gets tokenized via filename → "gamma" must be present.
        XCTAssertTrue(index.tokens.contains("gamma"))
        // Every file id must appear in at least one posting list (filename
        // tokens guarantee this).
        let allCovered: Set<Int> = Set(
            index.postings.values.reduce(into: [Int]()) { $0.append(contentsOf: $1) }
        )
        for id in 0..<index.files.count {
            XCTAssertTrue(allCovered.contains(id),
                "File '\(index.files[id].path)' (id=\(id)) does not appear in any posting list.")
        }
    }
}
