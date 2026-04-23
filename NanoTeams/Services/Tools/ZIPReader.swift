import Foundation
import Compression

/// In-process ZIP reader for Office/ODT document containers. Pure-Swift
/// over `Foundation` + `Compression.framework`. Scope is narrow — this is
/// an internal helper for `DocumentTextExtractor`, not a general-purpose
/// ZIP browser. `search` does not traverse arbitrary `.zip` files.
///
/// Supports: STORED (method 0) + DEFLATE (method 8) with CRC-32 verification.
/// Rejects: ZIP64, encrypted entries, split archives, other compression methods.
/// Guards: file-size cap (`DocumentConstants.maxDocumentFileSize`) + output cap
/// (`DocumentConstants.maxExtractionBytes * 2`) against zip-bombs.
///
/// ### `COMPRESSION_ZLIB` quirk
///
/// On Apple platforms `COMPRESSION_ZLIB` accepts/produces raw DEFLATE (no
/// zlib RFC 1950 header/trailer), despite what the constant name suggests.
/// This is stable, documented community knowledge — and exactly what ZIP's
/// DEFLATE compression method (code 8) expects. `ZIPArchiveWriter` relies
/// on the encode side of the same quirk, making roundtrips symmetric.
///
/// Thread-safety: stateless enum. Each call creates its own `compression_stream`.
/// Parallel invocations from different roles are safe by construction.
enum ZIPReader {
    /// One entry in the archive's Central Directory.
    ///
    /// `Method` is a closed enum because only STORED/DEFLATE reach this type —
    /// unsupported methods are rejected at parse time via
    /// `Failure.unsupportedCompressionMethod`. This makes the extraction
    /// switch exhaustive at compile time.
    struct Entry {
        let name: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let method: Method
        let expectedCRC32: UInt32
    }

    enum Method {
        case stored    // compression method 0
        case deflate   // compression method 8
    }

    enum Failure: Error, CustomStringConvertible {
        case notAZIPFile
        case corruptArchive(reason: String)
        case zip64Unsupported
        case splitArchive
        case encryptedEntry(name: String)
        case unsupportedCompressionMethod(UInt16, name: String)
        case decompressionFailed(name: String, reason: String)
        case crcMismatch(name: String, expected: UInt32, actual: UInt32)

        var description: String {
            switch self {
            case .notAZIPFile:
                return "not a ZIP file (EOCD signature not found)"
            case .corruptArchive(let reason):
                return "corrupt ZIP archive: \(reason)"
            case .zip64Unsupported:
                return "ZIP64 archives are not supported"
            case .splitArchive:
                return "split/multi-volume ZIP archives are not supported"
            case .encryptedEntry(let name):
                return "encrypted ZIP entry not supported: \(name)"
            case .unsupportedCompressionMethod(let method, let name):
                return "unsupported ZIP compression method \(method) in entry: \(name)"
            case .decompressionFailed(let name, let reason):
                return "DEFLATE decompression failed for \(name): \(reason)"
            case .crcMismatch(let name, let expected, let actual):
                return "CRC-32 mismatch in \(name) (expected \(String(format: "%08X", expected)), got \(String(format: "%08X", actual)))"
            }
        }
    }

    /// Lists all entries from the Central Directory of the archive.
    /// Does NOT read or decompress entry data — see `readEntry(named:from:)`.
    static func listEntries(at url: URL) throws -> [Entry] {
        let archive = try loadArchive(at: url)
        return try parseEntries(in: archive)
    }

    /// Reads a single entry by exact name match. Returns `nil` if not found.
    /// Performs CRC-32 verification and output-size capping during decompression.
    static func readEntry(named: String, from url: URL) throws -> Data? {
        let archive = try loadArchive(at: url)
        let entries = try parseEntries(in: archive)
        guard let entry = entries.first(where: { $0.name == named }) else {
            return nil
        }
        return try extractData(for: entry, from: archive)
    }
}

// MARK: - Archive loading + top-level parsing

private extension ZIPReader {
    /// Loads the archive file into memory after enforcing the size cap.
    ///
    /// `attributesOfItem` is allowed to `throw` here — a stat failure
    /// (permission, broken symlink, SMB race) must NOT silently bypass the
    /// file-size guard, since the guard is what protects against OOM on
    /// deceptively small-looking files.
    static func loadArchive(at url: URL) throws -> Data {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw Failure.corruptArchive(
                reason: "cannot stat ZIP file: \(error.localizedDescription)"
            )
        }
        if let size = attrs[.size] as? NSNumber,
           size.intValue > DocumentConstants.maxDocumentFileSize
        {
            throw Failure.corruptArchive(
                reason: "ZIP file too large (\(size.intValue) bytes; max \(DocumentConstants.maxDocumentFileSize))"
            )
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Failure.corruptArchive(reason: "cannot read ZIP file: \(error.localizedDescription)")
        }
    }

    static func parseEntries(in data: Data) throws -> [Entry] {
        let eocdOffset = try findEOCD(in: data)
        try rejectZIP64(in: data, eocdOffset: eocdOffset)
        try rejectSplit(in: data, eocdOffset: eocdOffset)

        let entryCount = Int(data.le16(at: eocdOffset + 10))
        let cdSize = Int(data.le32(at: eocdOffset + 12))
        let cdOffset = Int(data.le32(at: eocdOffset + 16))

        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw Failure.corruptArchive(reason: "central directory offset/size out of range")
        }

        return try parseCentralDirectory(in: data,
                                         cdOffset: cdOffset,
                                         cdSize: cdSize,
                                         entryCount: entryCount)
    }

    /// Scans backward from end of file for EOCD signature (0x06054B50) and
    /// verifies the comment-length field is consistent with the remaining
    /// bytes. Without that verification, an archive comment containing the
    /// bytes `0x50 0x4B 0x05 0x06` would be mistaken for the EOCD and cause
    /// misparsing downstream.
    static func findEOCD(in data: Data) throws -> Int {
        let signature: UInt32 = 0x06054B50
        let minEOCDSize = 22
        guard data.count >= minEOCDSize else { throw Failure.notAZIPFile }

        let maxCommentLen = 65535
        let windowSize = min(data.count, minEOCDSize + maxCommentLen)
        let searchStart = data.count - windowSize
        let lastPossibleOffset = data.count - minEOCDSize

        for offset in stride(from: lastPossibleOffset, through: searchStart, by: -1) {
            guard data.le32(at: offset) == signature else { continue }
            // Verify commentLength field (at offset+20) lines up with file end.
            // This is the canonical trick to disambiguate real EOCD from stray
            // signature bytes that happen to appear inside a comment.
            let commentLength = Int(data.le16(at: offset + 20))
            if offset + minEOCDSize + commentLength == data.count {
                return offset
            }
        }
        throw Failure.notAZIPFile
    }

    /// Rejects archives that use ZIP64 extensions:
    /// - EOCD64 locator (signature 0x07064B50) sits in the 20 bytes before EOCD
    /// - any sentinel value (0xFFFFFFFF / 0xFFFF) in EOCD fields
    static func rejectZIP64(in data: Data, eocdOffset: Int) throws {
        let locatorOffset = eocdOffset - 20
        if locatorOffset >= 0, data.le32(at: locatorOffset) == 0x07064B50 {
            throw Failure.zip64Unsupported
        }
        let totalEntries = data.le16(at: eocdOffset + 10)
        let cdSize = data.le32(at: eocdOffset + 12)
        let cdOffset = data.le32(at: eocdOffset + 16)
        if totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            throw Failure.zip64Unsupported
        }
    }

    static func rejectSplit(in data: Data, eocdOffset: Int) throws {
        let diskNumber = data.le16(at: eocdOffset + 4)
        let diskWithCD = data.le16(at: eocdOffset + 6)
        if diskNumber != 0 || diskWithCD != 0 {
            throw Failure.splitArchive
        }
    }
}

// MARK: - Central Directory parsing

private extension ZIPReader {
    static func parseCentralDirectory(
        in data: Data, cdOffset: Int, cdSize: Int, entryCount: Int
    ) throws -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = cdOffset
        let cdEnd = cdOffset + cdSize

        while entries.count < entryCount {
            guard cursor + 46 <= cdEnd else {
                throw Failure.corruptArchive(reason: "central directory truncated at entry \(entries.count)")
            }
            let signature = data.le32(at: cursor)
            guard signature == 0x02014B50 else {
                throw Failure.corruptArchive(
                    reason: "bad central directory entry signature at offset \(cursor)"
                )
            }

            let gpFlag = data.le16(at: cursor + 8)
            let methodCode = data.le16(at: cursor + 10)
            let crc = data.le32(at: cursor + 16)
            let compressedSize = data.le32(at: cursor + 20)
            let uncompressedSize = data.le32(at: cursor + 24)
            let nameLength = Int(data.le16(at: cursor + 28))
            let extraLength = Int(data.le16(at: cursor + 30))
            let commentLength = Int(data.le16(at: cursor + 32))
            let localHeaderOffset = data.le32(at: cursor + 42)

            // Paranoid ZIP64 check at entry level — some writers put sentinel in CD
            // even if EOCD looks clean.
            if compressedSize == 0xFFFFFFFF
                || uncompressedSize == 0xFFFFFFFF
                || localHeaderOffset == 0xFFFFFFFF
            {
                throw Failure.zip64Unsupported
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= cdEnd else {
                throw Failure.corruptArchive(reason: "filename extends beyond central directory")
            }
            let nameBytes = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(decoding: nameBytes, as: UTF8.self)

            if gpFlag & 0x0001 != 0 {
                throw Failure.encryptedEntry(name: name)
            }
            let method: Method
            switch methodCode {
            case 0:  method = .stored
            case 8:  method = .deflate
            default: throw Failure.unsupportedCompressionMethod(methodCode, name: name)
            }

            entries.append(Entry(
                name: name,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                method: method,
                expectedCRC32: crc
            ))

            cursor = nameEnd + extraLength + commentLength
        }

        return entries
    }
}

// MARK: - Entry data extraction

private extension ZIPReader {
    static func extractData(for entry: Entry, from data: Data) throws -> Data {
        let lfhStart = Int(entry.localHeaderOffset)
        guard lfhStart + 30 <= data.count else {
            throw Failure.corruptArchive(reason: "local header offset out of range for \(entry.name)")
        }
        let lfhSignature = data.le32(at: lfhStart)
        guard lfhSignature == 0x04034B50 else {
            throw Failure.corruptArchive(
                reason: "bad local file header signature at \(lfhStart) for \(entry.name)"
            )
        }
        let nameLength = Int(data.le16(at: lfhStart + 26))
        let extraLength = Int(data.le16(at: lfhStart + 28))
        let dataStart = lfhStart + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
            throw Failure.corruptArchive(reason: "entry data truncated for \(entry.name)")
        }

        // Empty entries — short-circuit to preserve CRC-0 guarantee
        if entry.compressedSize == 0 {
            if entry.expectedCRC32 != 0 {
                throw Failure.crcMismatch(name: entry.name, expected: entry.expectedCRC32, actual: 0)
            }
            return Data()
        }

        let compressed = data.subdata(in: dataStart..<dataEnd)
        switch entry.method {
        case .stored:
            return try verifyStoredCRC(compressed, expectedCRC: entry.expectedCRC32, name: entry.name)
        case .deflate:
            return try decompressDeflate(compressed,
                                         expectedCRC: entry.expectedCRC32,
                                         name: entry.name)
        }
    }

    static func verifyStoredCRC(_ data: Data, expectedCRC: UInt32, name: String) throws -> Data {
        let actualCRC = CRC32.compute(data)
        guard actualCRC == expectedCRC else {
            throw Failure.crcMismatch(name: name, expected: expectedCRC, actual: actualCRC)
        }
        return data
    }

    /// Streaming DEFLATE decode with inline CRC-32 update and output-size cap.
    ///
    /// ### Loop invariants
    ///
    /// Violations cause silent hangs or OOM — do not reorder without care:
    /// - `COMPRESSION_STREAM_FINALIZE` is passed iff `stream.src_size == 0`;
    ///   otherwise `COMPRESSION_STATUS_END` never fires.
    /// - `dst_ptr`/`dst_size` are reset back to the scratch buffer after every
    ///   iteration that produced output; otherwise the next call returns
    ///   `STATUS_OK` with `produced == 0` and the loop spins forever.
    /// - `src_ptr`/`src_size` are NOT reset — the framework advances them
    ///   internally as input is consumed. Applying the dst-reset pattern to
    ///   src would corrupt decoding.
    /// - `compression_stream_destroy` runs via `defer` (leaks framework-owned
    ///   internal buffers otherwise).
    ///
    /// ### Output cap
    ///
    /// `DocumentConstants.maxExtractionBytes * 2` gives extractors headroom
    /// for formatting overhead (markdown tables in XLSX, paragraph newlines
    /// in DOCX, `\n\n` between PPTX slides, etc.) added AFTER ZIP decompression
    /// but BEFORE the final byte-cap truncation in `DocumentTextExtractor`.
    /// 2× is a conservative margin — observed extraction overhead is well
    /// under 1.3×. We do NOT trust `uncompressedSize` from the CD header
    /// (attacker-controlled).
    static func decompressDeflate(
        _ compressed: Data, expectedCRC: UInt32, name: String
    ) throws -> Data {
        let outputCap = DocumentConstants.maxExtractionBytes * 2
        let scratchSize = 64 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }

        return try compressed.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) -> Data in
            guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Data()
            }

            // compression_stream_init overwrites `state`. Initialize with
            // placeholder zero sizes, then overwrite src/dst with real values.
            var stream = compression_stream(
                dst_ptr: scratch,
                dst_size: 0,
                src_ptr: inBase,
                src_size: 0,
                state: nil
            )
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard initStatus == COMPRESSION_STATUS_OK else {
                throw Failure.decompressionFailed(
                    name: name,
                    reason: "compression_stream_init returned \(initStatus.rawValue)"
                )
            }
            defer { _ = compression_stream_destroy(&stream) }

            stream.src_ptr = inBase
            stream.src_size = compressed.count
            stream.dst_ptr = scratch
            stream.dst_size = scratchSize

            var output = Data()
            var crc: UInt32 = 0xFFFFFFFF
            var totalWritten = 0

            while true {
                let flags: Int32 = (stream.src_size == 0)
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                let status = compression_stream_process(&stream, flags)

                let produced = scratchSize - stream.dst_size
                if produced > 0 {
                    output.append(scratch, count: produced)
                    for i in 0..<produced {
                        crc = CRC32.table[Int((crc ^ UInt32(scratch[i])) & 0xFF)] ^ (crc >> 8)
                    }
                    totalWritten += produced
                    if totalWritten > outputCap {
                        throw Failure.corruptArchive(
                            reason: "decompressed output exceeds limit (\(outputCap) bytes) for \(name)"
                        )
                    }
                    stream.dst_ptr = scratch
                    stream.dst_size = scratchSize
                }

                if status == COMPRESSION_STATUS_END {
                    break
                } else if status == COMPRESSION_STATUS_OK {
                    continue
                } else if status == COMPRESSION_STATUS_ERROR {
                    throw Failure.decompressionFailed(
                        name: name,
                        reason: "DEFLATE stream corrupt or truncated"
                    )
                } else {
                    // Forward-compat for any new Apple-added status codes.
                    throw Failure.decompressionFailed(
                        name: name,
                        reason: "unknown compression_stream_process status \(status.rawValue)"
                    )
                }
            }

            let finalCRC = crc ^ 0xFFFFFFFF
            guard finalCRC == expectedCRC else {
                throw Failure.crcMismatch(name: name, expected: expectedCRC, actual: finalCRC)
            }
            return output
        }
    }
}

// MARK: - CRC-32/IEEE (shared via @testable with ZIPArchiveWriter)

/// Standard CRC-32 / IEEE 802.3, polynomial `0xEDB88320` (reflected `0x04C11DB7`).
/// Matches the CRC values that Office/ODT writers — and `/usr/bin/zip` — put
/// in Central Directory entries.
///
/// Exposed as `internal` so the test-only `ZIPArchiveWriter` can share the
/// implementation rather than duplicating the table.
enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { (i: UInt32) -> UInt32 in
            (0..<8).reduce(i) { c, _ in
                (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
        }
    }()

    static func compute(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for b in bytes {
                c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - Little-endian read helpers

private extension Data {
    /// Reads a little-endian UInt16 at a byte offset from `startIndex`.
    ///
    /// Callers must pass `Data` values whose `startIndex == 0` (full files,
    /// not slices) — `loadUnaligned(fromByteOffset:)` treats the offset as
    /// relative to the underlying buffer origin, not the slice start. The
    /// check is a `precondition` rather than `assert` because a slice-origin
    /// mismatch here silently misreads the archive header, bypassing every
    /// security check downstream; we want it to fail loudly in release too.
    func le16(at offset: Int) -> UInt16 {
        precondition(startIndex == 0, "ZIPReader le16 expects a full Data buffer, not a slice")
        return withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func le32(at offset: Int) -> UInt32 {
        precondition(startIndex == 0, "ZIPReader le32 expects a full Data buffer, not a slice")
        return withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
