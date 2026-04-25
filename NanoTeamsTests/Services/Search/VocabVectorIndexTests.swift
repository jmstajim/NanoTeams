import XCTest

@testable import NanoTeams

final class VocabVectorIndexTests: XCTestCase {

    // MARK: - Binary codec round-trip

    func testBinaryCodec_roundTrip_preservesValuesWithinFloat16Precision() throws {
        // Input values span positive / negative / small / near-unit so any
        // Float16 down-cast bug shows up. Float16 has ~3 decimal digits of
        // precision — 0.001 tolerance is generous.
        let dims = 4
        let count = 3
        let input: [Float] = [
             0.1,  0.2, -0.3,  0.4,   // row 0
             0.5, -0.6,  0.7,  0.8,   // row 1
            -0.9,  0.0,  1.0, -1.0,   // row 2
        ]

        let encoded = VocabVectorBinaryCodec.encode(
            vectors: input, count: count, dims: dims
        )
        let decoded = try VocabVectorBinaryCodec.decode(
            data: encoded, expectedDims: dims, expectedCount: count
        )

        XCTAssertEqual(decoded.count, input.count)
        for (a, b) in zip(input, decoded) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testBinaryCodec_headerSize_matchesSpec() {
        // Header is 16 bytes; payload is count × dims × 2 bytes (Float16).
        let encoded = VocabVectorBinaryCodec.encode(
            vectors: [1.0, 2.0, 3.0, 4.0], count: 2, dims: 2
        )
        XCTAssertEqual(encoded.count, 16 + 2 * 2 * 2)
    }

    func testBinaryCodec_truncated_throws() {
        let encoded = VocabVectorBinaryCodec.encode(
            vectors: [1.0, 2.0], count: 1, dims: 2
        )
        let truncated = encoded.prefix(8)

        XCTAssertThrowsError(
            try VocabVectorBinaryCodec.decode(
                data: truncated, expectedDims: 2, expectedCount: 1
            )
        ) { error in
            guard case VocabVectorBinaryCodec.DecodeError.truncated = error else {
                XCTFail("Expected .truncated, got \(error)")
                return
            }
        }
    }

    func testBinaryCodec_badMagic_throws() {
        var corrupt = VocabVectorBinaryCodec.encode(
            vectors: [1.0, 2.0], count: 1, dims: 2
        )
        // Clobber the first magic byte.
        corrupt[0] = 0xFF

        XCTAssertThrowsError(
            try VocabVectorBinaryCodec.decode(
                data: corrupt, expectedDims: 2, expectedCount: 1
            )
        ) { error in
            guard case VocabVectorBinaryCodec.DecodeError.badMagic = error else {
                XCTFail("Expected .badMagic, got \(error)")
                return
            }
        }
    }

    func testBinaryCodec_dimsMismatch_throws() {
        let encoded = VocabVectorBinaryCodec.encode(
            vectors: [1.0, 2.0, 3.0, 4.0], count: 2, dims: 2
        )

        XCTAssertThrowsError(
            try VocabVectorBinaryCodec.decode(
                data: encoded, expectedDims: 4, expectedCount: 2
            )
        ) { error in
            guard case VocabVectorBinaryCodec.DecodeError.dimsMismatch(let exp, let got) = error else {
                XCTFail("Expected .dimsMismatch, got \(error)")
                return
            }
            XCTAssertEqual(exp, 4)
            XCTAssertEqual(got, 2)
        }
    }

    func testBinaryCodec_countMismatch_throws() {
        let encoded = VocabVectorBinaryCodec.encode(
            vectors: [1.0, 2.0, 3.0, 4.0], count: 2, dims: 2
        )

        XCTAssertThrowsError(
            try VocabVectorBinaryCodec.decode(
                data: encoded, expectedDims: 2, expectedCount: 3
            )
        ) { error in
            guard case VocabVectorBinaryCodec.DecodeError.countMismatch = error else {
                XCTFail("Expected .countMismatch, got \(error)")
                return
            }
        }
    }

    // MARK: - VocabVectorIndex queries

    private func makeIndex(tokensAndVectors: [(String, [Float])]) -> VocabVectorIndex {
        let dims = tokensAndVectors.first?.1.count ?? 0
        var tokenMap: [String: Int] = [:]
        var flat: [Float] = []
        for (i, pair) in tokensAndVectors.enumerated() {
            tokenMap[pair.0] = i
            flat.append(contentsOf: VectorMath.normalize(pair.1))
        }
        // `Meta.init` validates invariants; force-try is fine here — the
        // builder above constructs the tokenMap as a valid bijection.
        let meta = try! VocabVectorIndex.Meta(
            generatedAt: Date(),
            modelName: "test-model",
            dims: dims,
            indexSignature: IndexSignature(fileCount: 0, maxMTime: Date.distantPast, totalSize: 0),
            tokenMap: tokenMap
        )
        return try! VocabVectorIndex(meta: meta, vectors: flat)
    }

    // MARK: - I8: throwing init replaces crash-on-mismatch

    /// I8: `VocabVectorIndex.init(meta:vectors:)` used to `precondition` on a
    /// vectors/meta size mismatch — a buggy codec or partial-write recovery
    /// would crash the whole app. A throwing init lets the persistence layer
    /// degrade to "force rebuild" instead.
    func testInit_vectorsBufferMismatch_throws() {
        let meta = try! VocabVectorIndex.Meta(
            generatedAt: Date(),
            modelName: "test-model",
            dims: 3,
            indexSignature: IndexSignature(fileCount: 0, maxMTime: Date.distantPast, totalSize: 0),
            tokenMap: ["user": 0, "account": 1]
        )
        // Buffer size wrong: 2 tokens × 3 dims should be 6 floats; supply 5.
        XCTAssertThrowsError(try VocabVectorIndex(meta: meta, vectors: [1, 0, 0, 0, 1]))
    }

    func testVectorForToken_returnsNormalizedRow() {
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0, 0.0]),
            ("account", [0.0, 1.0, 0.0]),
        ])

        let userVec = idx.vector(for: "user")
        XCTAssertNotNil(userVec)
        XCTAssertEqual(userVec, [1.0, 0.0, 0.0])
    }

    func testVectorForToken_isCaseInsensitive() {
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0, 0.0]),
        ])

        XCTAssertNotNil(idx.vector(for: "USER"))
        XCTAssertNotNil(idx.vector(for: "User"))
        XCTAssertEqual(idx.vector(for: "USER"), idx.vector(for: "user"))
    }

    func testVectorForToken_returnsNilForUnknown() {
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0, 0.0]),
        ])
        XCTAssertNil(idx.vector(for: "widget"))
    }

    func testNearestTokens_ranksByDescendingCosine() {
        // Three points on the unit sphere. Query is "user" itself.
        // - "account" at 60° from user (cos = 0.5)
        // - "widget" at 90° from user (cos = 0)
        // - "профиль" at 30° from user (cos ≈ 0.866)
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0]),
            ("account", [cos(Float.pi / 3), sin(Float.pi / 3)]),          // 60°
            ("widget", [0.0, 1.0]),                                         // 90°
            ("профиль", [cos(Float.pi / 6), sin(Float.pi / 6)]),           // 30°
        ])
        let query = idx.vector(for: "user")!

        let hits = idx.nearestTokens(
            to: query, k: 10, threshold: 0, excluding: ["user"]
        )

        // "user" must be excluded; остальные ordered by decreasing cosine.
        XCTAssertFalse(hits.contains(where: { $0.token == "user" }))
        let order = hits.map(\.token)
        XCTAssertEqual(order.first, "профиль", "closest should be at 30° (highest cosine)")
        XCTAssertEqual(order.last, "widget", "farthest should be at 90° (zero cosine)")
    }

    func testNearestTokens_threshold_filtersLowScores() {
        // Same fixture. Threshold 0.6 should exclude "widget" (cos 0) and
        // "account" (cos 0.5), keep only "профиль" (cos ~0.866).
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0]),
            ("account", [cos(Float.pi / 3), sin(Float.pi / 3)]),
            ("widget", [0.0, 1.0]),
            ("профиль", [cos(Float.pi / 6), sin(Float.pi / 6)]),
        ])
        let query = idx.vector(for: "user")!

        let hits = idx.nearestTokens(
            to: query, k: 10, threshold: 0.6, excluding: ["user"]
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.token, "профиль")
    }

    func testNearestTokens_capsAtK() {
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0]),
            ("a", [0.99, 0.01]),
            ("b", [0.98, 0.02]),
            ("c", [0.97, 0.03]),
        ])
        let query = idx.vector(for: "user")!

        let hits = idx.nearestTokens(
            to: query, k: 2, threshold: 0, excluding: ["user"]
        )
        XCTAssertEqual(hits.count, 2, "k=2 must cap the result")
    }

    func testNearestTokens_dimsMismatch_returnsEmpty() {
        let idx = makeIndex(tokensAndVectors: [
            ("user", [1.0, 0.0, 0.0]),
        ])
        // Mismatched dims — defensive path.
        let hits = idx.nearestTokens(to: [1.0, 0.0], k: 10, threshold: 0)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Meta validation

    func testMeta_validTokenMap_succeeds() {
        // Canonical tokenMap: 3 tokens, rows 0..<3.
        XCTAssertNoThrow(
            try VocabVectorIndex.Meta(
                generatedAt: Date(),
                modelName: "m",
                dims: 768,
                indexSignature: IndexSignature(
                    fileCount: 0, maxMTime: Date.distantPast, totalSize: 0
                ),
                tokenMap: ["a": 0, "b": 1, "c": 2]
            )
        )
    }

    func testMeta_duplicateRowIndices_throws() {
        // Two tokens pointing at the same row — bijection violated.
        XCTAssertThrowsError(
            try VocabVectorIndex.Meta(
                generatedAt: Date(), modelName: "m", dims: 3,
                indexSignature: IndexSignature(
                    fileCount: 0, maxMTime: Date.distantPast, totalSize: 0
                ),
                tokenMap: ["a": 0, "b": 0, "c": 1]
            )
        ) { error in
            XCTAssertEqual(error as? VocabVectorIndex.Meta.ValidationError,
                           .duplicateRowIndices)
        }
    }

    func testMeta_nonCompactRowIndices_throws() {
        // Rows 0 and 2 with no 1 in between — tokenMap.count = 2 but values
        // aren't the set {0, 1}.
        XCTAssertThrowsError(
            try VocabVectorIndex.Meta(
                generatedAt: Date(), modelName: "m", dims: 3,
                indexSignature: IndexSignature(
                    fileCount: 0, maxMTime: Date.distantPast, totalSize: 0
                ),
                tokenMap: ["a": 0, "c": 2]
            )
        ) { error in
            guard case VocabVectorIndex.Meta.ValidationError.nonCompactRowIndices = error else {
                XCTFail("Expected .nonCompactRowIndices, got \(error)")
                return
            }
        }
    }

    func testMeta_failedTokenAlsoInMap_throws() {
        // A token that's simultaneously "embedded" and "failed" — impossible
        // state, rejected by validation.
        XCTAssertThrowsError(
            try VocabVectorIndex.Meta(
                generatedAt: Date(), modelName: "m", dims: 3,
                indexSignature: IndexSignature(
                    fileCount: 0, maxMTime: Date.distantPast, totalSize: 0
                ),
                tokenMap: ["a": 0],
                failedTokens: ["a"]
            )
        ) { error in
            XCTAssertEqual(error as? VocabVectorIndex.Meta.ValidationError,
                           .failedTokenAlsoInMap)
        }
    }

    func testMeta_invalidDims_throws() {
        // Non-empty tokenMap with dims <= 0 — stored vectors would be
        // zero-length, defeating cosine entirely.
        XCTAssertThrowsError(
            try VocabVectorIndex.Meta(
                generatedAt: Date(), modelName: "m", dims: 0,
                indexSignature: IndexSignature(
                    fileCount: 0, maxMTime: Date.distantPast, totalSize: 0
                ),
                tokenMap: ["a": 0]
            )
        ) { error in
            guard case VocabVectorIndex.Meta.ValidationError.invalidDims = error else {
                XCTFail("Expected .invalidDims, got \(error)")
                return
            }
        }
    }

    // MARK: - VectorMath

    func testNormalize_producesUnitMagnitude() {
        let v: [Float] = [3.0, 4.0]   // magnitude 5
        let n = VectorMath.normalize(v)
        XCTAssertEqual(n[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(n[1], 0.8, accuracy: 0.0001)
    }

    func testNormalize_zeroVector_unchanged() {
        let v: [Float] = [0.0, 0.0, 0.0]
        let n = VectorMath.normalize(v)
        XCTAssertEqual(n, v)
    }
}
