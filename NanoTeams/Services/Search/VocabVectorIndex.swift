import Foundation
import Accelerate

/// Persistent "semantic layer" sitting next to `SearchIndex`. Stores one
/// unit-normalized embedding per vocab token plus the metadata needed to
/// reconstruct the token → row mapping.
///
/// File layout (both live in `.nanoteams/internal/`):
/// - `vocab_vectors.bin`: header (16 bytes) + `count × dims × Float16`.
/// - `vocab_vectors.meta.json`: `Meta` — version, timestamp, model name, dims,
///   index signature, `tokenMap`, `failedTokens`.
///
/// Why split the two files? The vectors themselves are >95% of the payload
/// (73MB for 50k × 768) — keeping them binary + Float16 halves disk cost vs
/// JSON-encoded floats and lets us load them as a contiguous `[Float]` with a
/// single conversion pass rather than parsing 768×count tokens.
///
/// Why unit-normalized? cosine similarity between unit vectors = dot product,
/// computable with a single `vDSP_dotpr` call over the whole corpus in a tight
/// loop. ~10-30ms for 50k vectors on Apple Silicon.
struct VocabVectorIndex: Sendable {

    // MARK: - Types

    struct Meta: Codable, Equatable, Sendable {
        /// Bump when the on-disk format changes — readers discard older
        /// payloads and force a full rebuild instead of migrating.
        static let currentVersion: Int = 1

        /// Invariants enforced by the throwing init — corrupted metas
        /// (builder bug or disk tampering) surface as load() failures rather
        /// than silent index corruption.
        let version: Int
        let generatedAt: Date
        /// Exact model identifier that produced these vectors. Mismatch vs
        /// current `EmbeddingConfig.modelName` forces a full rebuild.
        let modelName: String
        /// Embedding dimensions. Mismatch vs the file's on-disk `dims` header
        /// or vs. a fresh live-call response forces a full rebuild.
        let dims: Int
        /// Signature of the token-index snapshot these vectors were computed
        /// against. Copied from `SearchIndex.signature` at build time.
        /// Purely informational — the diff path (added/gone tokens) compares
        /// by token identity, not signature.
        let indexSignature: IndexSignature
        /// token (lowercase) → row index in the vectors array. Row indices
        /// are a bijection onto 0..<count (validated by init). No holes, no
        /// duplicates.
        let tokenMap: [String: Int]
        /// Tokens whose embed calls failed permanently in the last build.
        /// Disjoint from `tokenMap.keys` (validated by init) — the next
        /// rebuild sees them as `addedTokens` and retries.
        let failedTokens: [String]

        /// Throwing init: enforces cross-field invariants so downstream types
        /// (`VocabVectorIndex.init`, `nearestTokens`) can `precondition` the
        /// bijection and drop the `guard row < tokens.count else { return nil }`
        /// defensive branches.
        init(
            version: Int = Meta.currentVersion,
            generatedAt: Date,
            modelName: String,
            dims: Int,
            indexSignature: IndexSignature,
            tokenMap: [String: Int],
            failedTokens: [String] = []
        ) throws {
            let rowValues = Array(tokenMap.values)
            guard Set(rowValues).count == rowValues.count else {
                throw ValidationError.duplicateRowIndices
            }
            guard Set(rowValues) == Set(0..<tokenMap.count) else {
                throw ValidationError.nonCompactRowIndices(got: rowValues.sorted())
            }
            if !tokenMap.isEmpty, dims <= 0 {
                throw ValidationError.invalidDims(dims)
            }
            if !Set(failedTokens).isDisjoint(with: tokenMap.keys) {
                throw ValidationError.failedTokenAlsoInMap
            }

            self.version = version
            self.generatedAt = generatedAt
            self.modelName = modelName
            self.dims = dims
            self.indexSignature = indexSignature
            self.tokenMap = tokenMap
            self.failedTokens = failedTokens
        }

        // Codable: decode raw fields, then re-run the validating init.
        // A corrupted meta on disk throws here and `load()` treats it as missing.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                version: c.decode(Int.self, forKey: .version),
                generatedAt: c.decode(Date.self, forKey: .generatedAt),
                modelName: c.decode(String.self, forKey: .modelName),
                dims: c.decode(Int.self, forKey: .dims),
                indexSignature: c.decode(IndexSignature.self, forKey: .indexSignature),
                tokenMap: c.decode([String: Int].self, forKey: .tokenMap),
                failedTokens: c.decodeIfPresent([String].self, forKey: .failedTokens) ?? []
            )
        }

        enum CodingKeys: String, CodingKey {
            case version, generatedAt, modelName, dims, indexSignature, tokenMap, failedTokens
        }

        enum ValidationError: Error, Equatable {
            case duplicateRowIndices
            case nonCompactRowIndices(got: [Int])
            case invalidDims(Int)
            case failedTokenAlsoInMap
        }
    }

    // MARK: - Stored state

    let meta: Meta
    /// Flat `count × dims` Float32 buffer. Row `i` = tokens where `tokenMap`
    /// value == i, always unit-normalized. Float32 (not Float16) because that's
    /// what `vDSP_dotpr` takes — we pay the 2× memory cost at load time in
    /// exchange for zero per-call conversion.
    let vectors: [Float]

    /// Reverse of `meta.tokenMap`. Built once on load so `nearestTokens` can
    /// resolve row indices back to strings without scanning the dictionary.
    let tokensByRow: [String]

    // MARK: - Init

    enum InitError: Error, Equatable {
        case vectorsBufferSizeMismatch(got: Int, expected: Int)
    }

    /// Throws `InitError.vectorsBufferSizeMismatch` when the vector buffer
    /// doesn't match `meta.tokenMap.count * meta.dims`. A throwing init lets
    /// the persistence layer degrade to "force rebuild" instead of crashing
    /// the whole app on codec drift / partial-write recovery.
    init(meta: Meta, vectors: [Float]) throws {
        let expected = meta.tokenMap.count * meta.dims
        guard vectors.count == expected else {
            throw InitError.vectorsBufferSizeMismatch(got: vectors.count, expected: expected)
        }
        self.meta = meta
        self.vectors = vectors
        // Direct assignment — no `row < count` guard needed thanks to the
        // Meta invariant. Pre-fill is to satisfy [String] init; every slot
        // gets overwritten exactly once by the loop.
        var tokens = Array(repeating: "", count: meta.tokenMap.count)
        for (token, row) in meta.tokenMap {
            tokens[row] = token
        }
        self.tokensByRow = tokens
    }

    // MARK: - Queries

    /// Returns the stored vector for `token` (lowercased) or nil if not in the
    /// index. Vector is unit-normalized. Bounds are guaranteed by Meta's
    /// bijection invariant — no defensive `end <= vectors.count` branch.
    func vector(for token: String) -> [Float]? {
        let key = token.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard let row = meta.tokenMap[key] else { return nil }
        let start = row * meta.dims
        let end = start + meta.dims
        return Array(vectors[start..<end])
    }

    /// Top-k vocab tokens ranked by cosine similarity to `queryVec`, with
    /// `score >= threshold`. Input must be unit-normalized (caller's
    /// responsibility — we don't normalize here because on the hot path the
    /// query vector was just returned by the embedding client and already
    /// carries reasonable magnitude; callers normalize once in `expand`).
    ///
    /// Excludes `excluding` tokens (by lowercase match) — callers pass the
    /// original query tokens so they don't dominate their own expansion.
    ///
    /// A `queryVec` with the wrong dims is a programmer error — different
    /// model in the query path vs. build path, or a race between config
    /// change and in-flight expansion. Fail loud in debug; in release we
    /// still return `[]` rather than reading out-of-bounds memory.
    func nearestTokens(
        to queryVec: [Float],
        k: Int,
        threshold: Float,
        excluding: Set<String> = []
    ) -> [(token: String, score: Float)] {
        if queryVec.count != meta.dims {
            // Loud print so the programmer notices in dev — release builds
            // degrade to "no matches" rather than crash the UI card. This is
            // a programmer error (query embedded with different config than
            // index was built with); `[]` is harmless to downstream callers.
            print("[VocabVectorIndex] nearestTokens dim mismatch: query=\(queryVec.count), index=\(meta.dims)")
            return []
        }
        guard !vectors.isEmpty, k > 0 else {
            return []
        }
        let count = meta.tokenMap.count
        var hits: [(token: String, score: Float)] = []
        hits.reserveCapacity(32)

        // vDSP_dotpr over each row in the contiguous buffer. No dynamic
        // allocation inside the loop. For 50k × 768 this runs in the low tens
        // of milliseconds on Apple Silicon.
        queryVec.withUnsafeBufferPointer { qBuf in
            vectors.withUnsafeBufferPointer { vBuf in
                let qPtr = qBuf.baseAddress!
                for i in 0..<count {
                    let rowPtr = vBuf.baseAddress!.advanced(by: i * meta.dims)
                    var score: Float = 0
                    vDSP_dotpr(qPtr, 1, rowPtr, 1, &score, vDSP_Length(meta.dims))
                    if score >= threshold {
                        let token = tokensByRow[i]
                        if !excluding.contains(token) {
                            hits.append((token: token, score: score))
                        }
                    }
                }
            }
        }

        // Sort descending by score, take top k. For typical k ≤ 20 and hit
        // counts up to a few hundred, full sort is cheaper than a heap.
        hits.sort { $0.score > $1.score }
        if hits.count > k {
            return Array(hits.prefix(k))
        }
        return hits
    }
}

// MARK: - Binary file format

/// Codec for `vocab_vectors.bin`. Pure functions — no file I/O. The caller
/// (`VocabVectorIndexService`) handles atomic persistence and mmap lifecycle.
enum VocabVectorBinaryCodec {

    /// ASCII `"NTVE"` — NanoTeams Vector Embeddings. Serves as a sanity check
    /// that we're reading our own format, not an unrelated file with the
    /// expected name.
    static let magic: UInt32 = 0x4E_54_56_45   // N T V E

    static let headerBytes: Int = 16
    static let currentVersion: UInt32 = 1

    /// Encodes `vectors` (`count × dims` Float32, expected unit-normalized) as
    /// a binary blob with the header spec'd above. Float32 → Float16 down-cast
    /// happens here so the caller doesn't have to think about it.
    static func encode(vectors: [Float], count: Int, dims: Int) -> Data {
        precondition(vectors.count == count * dims, "vectors buffer size mismatch")
        var data = Data(capacity: headerBytes + count * dims * 2)
        writeUInt32LE(magic, into: &data)
        writeUInt32LE(currentVersion, into: &data)
        writeUInt32LE(UInt32(dims), into: &data)
        writeUInt32LE(UInt32(count), into: &data)

        // Float32 → Float16 conversion. Done on the CPU with the native
        // `Float16` type — hardware-accelerated on Apple Silicon via vDSP
        // would be marginally faster, but this loop runs once per build.
        for v in vectors {
            let h = Float16(v)
            var bits = h.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decodes a binary blob into a flat `[Float]` (Float32). Validates magic
    /// and count × dims against `expectedDims` and `expectedCount`, throwing
    /// on any mismatch so the caller can force a full rebuild.
    static func decode(
        data: Data,
        expectedDims: Int,
        expectedCount: Int
    ) throws -> [Float] {
        guard data.count >= headerBytes else {
            throw DecodeError.truncated(data.count)
        }
        let magicRead = readUInt32LE(data, offset: 0)
        guard magicRead == magic else {
            throw DecodeError.badMagic(magicRead)
        }
        let version = readUInt32LE(data, offset: 4)
        guard version == currentVersion else {
            throw DecodeError.unsupportedVersion(Int(version))
        }
        let dims = Int(readUInt32LE(data, offset: 8))
        let count = Int(readUInt32LE(data, offset: 12))
        guard dims == expectedDims else {
            throw DecodeError.dimsMismatch(expected: expectedDims, got: dims)
        }
        guard count == expectedCount else {
            throw DecodeError.countMismatch(expected: expectedCount, got: count)
        }

        let expectedBytes = headerBytes + count * dims * 2
        guard data.count >= expectedBytes else {
            throw DecodeError.truncated(data.count)
        }

        var floats = [Float]()
        floats.reserveCapacity(count * dims)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: headerBytes)
            let halfPtr = base.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(count * dims) {
                let bits = UInt16(littleEndian: halfPtr[i])
                let h = Float16(bitPattern: bits)
                floats.append(Float(h))
            }
        }
        return floats
    }

    enum DecodeError: Error, Equatable {
        case truncated(Int)
        case badMagic(UInt32)
        case unsupportedVersion(Int)
        case dimsMismatch(expected: Int, got: Int)
        case countMismatch(expected: Int, got: Int)
    }

    // MARK: - Byte helpers

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            raw.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}

// MARK: - Vector utilities

/// Unit-normalize a vector in place-ish. Returns a fresh array. Zero-magnitude
/// vectors come through unchanged — they produce a zero dot product with
/// anything, which is the correct "no similarity" outcome.
enum VectorMath {
    static func normalize(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var magnitude: Float = 0
        v.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress!, 1, &magnitude, vDSP_Length(v.count))
        }
        let norm = sqrt(magnitude)
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var scale: Float = 1 / norm
        v.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                vDSP_vsmul(inBuf.baseAddress!, 1, &scale,
                           outBuf.baseAddress!, 1, vDSP_Length(v.count))
            }
        }
        return out
    }
}
