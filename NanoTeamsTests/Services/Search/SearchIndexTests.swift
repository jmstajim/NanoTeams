import XCTest
@testable import NanoTeams

final class SearchIndexTests: XCTestCase {

    func testSignature_equality() {
        let a = IndexSignature(
            fileCount: 10,
            maxMTime: Date(timeIntervalSince1970: 1_000_000),
            totalSize: 5_000
        )
        let b = a
        XCTAssertEqual(a, b)
    }

    func testSignature_differsOnFileCount() {
        let a = IndexSignature(fileCount: 10, maxMTime: Date(), totalSize: 100)
        var b = a
        b.fileCount = 11
        XCTAssertNotEqual(a, b)
    }

    func testSignature_differsOnMaxMTime() {
        let a = IndexSignature(fileCount: 10, maxMTime: Date(timeIntervalSince1970: 1), totalSize: 100)
        var b = a
        b.maxMTime = Date(timeIntervalSince1970: 2)
        XCTAssertNotEqual(a, b)
    }

    func testSignature_differsOnTotalSize() {
        let a = IndexSignature(fileCount: 10, maxMTime: Date(), totalSize: 100)
        var b = a
        b.totalSize = 101
        XCTAssertNotEqual(a, b)
    }

    func testCurrentVersion_isTwo() {
        XCTAssertEqual(SearchIndex.currentVersion, 2)
    }

    /// The signature is derived from the roster, so it can never disagree with it.
    ///
    /// RED: hand-roll the fold anywhere else -> that copy drifts, and `vocab_vectors.meta.json`
    /// starts describing an index that no longer exists.
    func testSignature_isFoldedFromTheRoster() {
        let index = SearchIndex(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_002),
            files: [
                IndexedFile(path: "A.swift", mTime: Date(timeIntervalSince1970: 10), size: 100),
                IndexedFile(path: "B.swift", mTime: Date(timeIntervalSince1970: 20), size: 200),
            ],
            vocabulary: ["alpha"])
        XCTAssertEqual(index.signature, IndexSignature(
            fileCount: 2, maxMTime: Date(timeIntervalSince1970: 20), totalSize: 300))
    }

    /// An empty roster must not report `.distantPast` as an observation of anything — it is the
    /// identity of the fold, and `fileCount: 0` is what a reader branches on.
    func testSignature_emptyRoster() {
        let index = SearchIndex(
            generatedAt: Date(timeIntervalSince1970: 1), files: [], vocabulary: [])
        XCTAssertEqual(index.signature.fileCount, 0)
        XCTAssertEqual(index.signature.totalSize, 0)
        XCTAssertEqual(index.signature.maxMTime, Date.distantPast)
    }

    func testIndex_codableRoundTrip() throws {
        let index = SearchIndex(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            files: [
                IndexedFile(path: "A.swift", mTime: Date(timeIntervalSince1970: 1_700_000_000), size: 100),
                IndexedFile(path: "B.swift", mTime: Date(timeIntervalSince1970: 1_700_000_001), size: 200),
            ],
            vocabulary: ["alpha", "beta"],
            changedSinceFullBuild: 3
        )

        let enc = JSONCoderFactory.makeCompactPersistenceEncoder()
        let data = try enc.encode(index)
        let dec = JSONCoderFactory.makeDateDecoder()
        let roundTripped = try dec.decode(SearchIndex.self, from: data)
        XCTAssertEqual(roundTripped, index)
        XCTAssertEqual(roundTripped.changedSinceFullBuild, 3)
    }

    /// The one invariant that survives, enforced on DECODE only: the walk cannot produce a
    /// duplicate path, so this exists against a foreign payload — where a duplicate would give
    /// the diff two rows for one file and silently freeze one of them.
    ///
    /// RED: drop the `validate(files:)` call from `init(from:)` -> the decode succeeds and the
    /// corrupt roster is used.
    func testDecode_duplicateFilePaths_throws() throws {
        let row = #"{"path":"A.swift","mTime":"2026-09-11T00:00:00.000Z","size":1}"#
        let payload = #"{"version":2,"generatedAt":"2026-09-11T00:00:00.000Z","#
            + #""vocabulary":["a"],"changedSinceFullBuild":0,"files":["#
            + row + "," + row + "]}"
        let dec = JSONCoderFactory.makeDateDecoder()
        XCTAssertThrowsError(
            try dec.decode(SearchIndex.self, from: Data(payload.utf8))
        ) { error in
            XCTAssertEqual(
                error as? SearchIndex.ValidationError,
                .duplicateFilePaths(path: "A.swift"))
        }
    }

    /// A payload missing the churn counter — no version writes one that way, but a truncated or
    /// hand-edited file is a real thing — decodes as "nothing spent yet" rather than failing the
    /// load and forcing a full rebuild.
    func testDecode_missingChurnCounter_defaultsToZero() throws {
        let payload = #"{"version":2,"generatedAt":"2026-09-11T00:00:00.000Z","#
            + #""vocabulary":["a"],"files":[]}"#
        let dec = JSONCoderFactory.makeDateDecoder()
        let index = try dec.decode(SearchIndex.self, from: Data(payload.utf8))
        XCTAssertEqual(index.changedSinceFullBuild, 0)
    }
}
