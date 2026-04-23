import Foundation
import Compression
@testable import NanoTeams

/// Test-only helper: writes pure-Swift ZIP archives for fixture creation.
///
/// Replaces `/usr/bin/zip` subprocess. Supports STORED + DEFLATE with CRC-32
/// and optional EOCD comment. Edge-case fixtures (encrypted, unsupported
/// compression method, split archive, ZIP64) are constructed byte-by-byte
/// directly in their respective tests and don't go through this helper.
enum ZIPArchiveWriter {
    enum Method {
        case stored
        case deflate
    }

    struct EntrySpec {
        let name: String
        let data: Data
        let method: Method
        /// If set, both the Local File Header and Central Directory entry
        /// emit this CRC-32 instead of the computed checksum. For crafting
        /// "CRC mismatch" fixtures that drive `ZIPReader.Failure.crcMismatch`.
        let overrideCRC: UInt32?

        init(name: String, data: Data, method: Method = .deflate, overrideCRC: UInt32? = nil) {
            self.name = name
            self.data = data
            self.method = method
            self.overrideCRC = overrideCRC
        }
    }

    enum Failure: Error {
        case compressionFailed(status: Int32)
        case fileWriteFailed(underlying: Error)
    }

    /// Writes a valid non-ZIP64 archive to `url`. Each entry's data is
    /// CRC-32 summed and either stored verbatim (`.stored`) or compressed
    /// via raw DEFLATE (`.deflate`). EOCD carries an optional comment.
    static func write(to url: URL, entries: [EntrySpec], comment: String = "") throws {
        var output = Data()

        struct CDRecord {
            let nameBytes: Data
            let method: UInt16
            let crc32: UInt32
            let compressedSize: UInt32
            let uncompressedSize: UInt32
            let localHeaderOffset: UInt32
        }
        var cdRecords: [CDRecord] = []

        // --- Local File Headers + data ---
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = entry.overrideCRC ?? CRC32.compute(entry.data)
            let uncompressedSize = UInt32(entry.data.count)

            let compressed: Data
            let methodCode: UInt16
            switch entry.method {
            case .stored:
                compressed = entry.data
                methodCode = 0
            case .deflate:
                compressed = try deflateEncode(entry.data)
                methodCode = 8
            }
            let compressedSize = UInt32(compressed.count)
            let localHeaderOffset = UInt32(output.count)

            output.append(le32: 0x04034B50)              // signature
            output.append(le16: 20)                      // version needed
            output.append(le16: 0)                       // GP flag
            output.append(le16: methodCode)              // method
            output.append(le16: 0)                       // mod time
            output.append(le16: 0)                       // mod date
            output.append(le32: crc)                     // CRC-32
            output.append(le32: compressedSize)
            output.append(le32: uncompressedSize)
            output.append(le16: UInt16(nameBytes.count)) // name length
            output.append(le16: 0)                       // extra length
            output.append(nameBytes)
            output.append(compressed)

            cdRecords.append(CDRecord(
                nameBytes: nameBytes,
                method: methodCode,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
        }

        // --- Central Directory ---
        let cdOffset = UInt32(output.count)
        for rec in cdRecords {
            output.append(le32: 0x02014B50)              // signature
            output.append(le16: 0x031E)                  // version made by (3.0 Unix)
            output.append(le16: 20)                      // version needed
            output.append(le16: 0)                       // GP flag
            output.append(le16: rec.method)
            output.append(le16: 0)                       // mod time
            output.append(le16: 0)                       // mod date
            output.append(le32: rec.crc32)
            output.append(le32: rec.compressedSize)
            output.append(le32: rec.uncompressedSize)
            output.append(le16: UInt16(rec.nameBytes.count))
            output.append(le16: 0)                       // extra length
            output.append(le16: 0)                       // comment length
            output.append(le16: 0)                       // disk number start
            output.append(le16: 0)                       // internal attrs
            output.append(le32: 0)                       // external attrs
            output.append(le32: rec.localHeaderOffset)
            output.append(rec.nameBytes)
        }
        let cdSize = UInt32(output.count) - cdOffset

        // --- End Of Central Directory ---
        let commentBytes = Data(comment.utf8)
        output.append(le32: 0x06054B50)                  // signature
        output.append(le16: 0)                           // disk number
        output.append(le16: 0)                           // disk with CD start
        output.append(le16: UInt16(cdRecords.count))     // CD entries on this disk
        output.append(le16: UInt16(cdRecords.count))     // total CD entries
        output.append(le32: cdSize)
        output.append(le32: cdOffset)
        output.append(le16: UInt16(commentBytes.count))
        output.append(commentBytes)

        do {
            try output.write(to: url)
        } catch {
            throw Failure.fileWriteFailed(underlying: error)
        }
    }

    // MARK: - DEFLATE encoding via Compression.framework

    /// Raw DEFLATE (no zlib header/trailer) via `COMPRESSION_ZLIB` in encode mode.
    /// On Apple platforms `COMPRESSION_ZLIB` produces/accepts raw DEFLATE — the
    /// same quirk `ZIPReader` relies on for decoding.
    private static func deflateEncode(_ input: Data) throws -> Data {
        if input.isEmpty { return Data() }

        let scratchSize = 64 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }

        return try input.withUnsafeBytes { (inputBuf: UnsafeRawBufferPointer) -> Data in
            guard let inputBase = inputBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Data()
            }

            // compression_stream_init must be given a fully-initialized stream
            // but will overwrite `state`. Set dst/src placeholders first, then
            // init, then overwrite src/dst with real values.
            var stream = compression_stream(
                dst_ptr: scratch,
                dst_size: 0,
                src_ptr: inputBase,
                src_size: 0,
                state: nil
            )
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            guard initStatus == COMPRESSION_STATUS_OK else {
                throw Failure.compressionFailed(status: initStatus.rawValue)
            }
            defer { _ = compression_stream_destroy(&stream) }

            stream.src_ptr = inputBase
            stream.src_size = input.count
            stream.dst_ptr = scratch
            stream.dst_size = scratchSize

            var output = Data()

            while true {
                let flags: Int32 = (stream.src_size == 0) ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)

                let produced = scratchSize - stream.dst_size
                if produced > 0 {
                    output.append(scratch, count: produced)
                    stream.dst_ptr = scratch
                    stream.dst_size = scratchSize
                }

                if status == COMPRESSION_STATUS_END {
                    return output
                } else if status == COMPRESSION_STATUS_OK {
                    continue
                } else {
                    throw Failure.compressionFailed(status: status.rawValue)
                }
            }
        }
    }

    // CRC-32 table shared with ZIPReader via `@testable import NanoTeams`.
    // Single source of truth — symmetric roundtrip via the same implementation.
}

// MARK: - Little-endian append helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func append(le16 value: UInt16) { append(le: value) }
    mutating func append(le32 value: UInt32) { append(le: value) }
}
