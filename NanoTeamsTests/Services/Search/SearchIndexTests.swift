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

    func testCurrentVersion_isOne() {
        XCTAssertEqual(SearchIndex.currentVersion, 1)
    }

    func testIndex_codableRoundTrip() throws {
        let signature = IndexSignature(
            fileCount: 2,
            maxMTime: Date(timeIntervalSince1970: 1_700_000_000),
            totalSize: 1234
        )
        let index = try SearchIndex(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            signature: signature,
            files: [
                IndexedFile(path: "A.swift", mTime: Date(timeIntervalSince1970: 1_700_000_000), size: 100),
                IndexedFile(path: "B.swift", mTime: Date(timeIntervalSince1970: 1_700_000_001), size: 200),
            ],
            tokens: ["alpha", "beta"],
            postings: ["alpha": [0], "beta": [0, 1]]
        )

        let enc = JSONCoderFactory.makePersistenceEncoder()
        let data = try enc.encode(index)
        let dec = JSONCoderFactory.makeDateDecoder()
        let roundTripped = try dec.decode(SearchIndex.self, from: data)
        XCTAssertEqual(roundTripped, index)
    }
}
