import XCTest

@testable import NanoTeams

/// Unit tests for `ZIPReader`. All fixtures are produced by the pure-Swift
/// `ZIPArchiveWriter` helper or constructed byte-by-byte for edge cases.
/// No `/usr/bin/zip` anywhere.
final class ZIPReaderTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ZIPReaderTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Basic roundtrips

    func testListEntries_singleStoredEntry() throws {
        let url = tempDir.appendingPathComponent("single.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "hello.txt", data: Data("Hello".utf8), method: .stored)
        ])

        let entries = try ZIPReader.listEntries(at: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "hello.txt")
        XCTAssertEqual(entries[0].method, .stored)
        XCTAssertEqual(entries[0].uncompressedSize, 5)
    }

    func testReadEntry_storedRoundtrip() throws {
        let url = tempDir.appendingPathComponent("stored.zip")
        let payload = Data("The quick brown fox jumps over the lazy dog".utf8)
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "fox.txt", data: payload, method: .stored)
        ])

        let data = try ZIPReader.readEntry(named: "fox.txt", from: url)
        XCTAssertEqual(data, payload)
    }

    func testReadEntry_deflateRoundtrip() throws {
        let url = tempDir.appendingPathComponent("deflate.zip")
        // Payload large enough to force real DEFLATE (not just stored passthrough).
        var payload = Data()
        for i in 0..<1000 {
            payload.append(Data("line \(i): the quick brown fox\n".utf8))
        }
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "big.txt", data: payload, method: .deflate)
        ])

        let data = try ZIPReader.readEntry(named: "big.txt", from: url)
        XCTAssertEqual(data, payload, "DEFLATE roundtrip must preserve bytes exactly")
    }

    func testReadEntry_emptyEntry() throws {
        let url = tempDir.appendingPathComponent("empty.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "empty.txt", data: Data(), method: .stored)
        ])

        let data = try ZIPReader.readEntry(named: "empty.txt", from: url)
        XCTAssertEqual(data, Data())
    }

    func testListEntries_multiEntry() throws {
        let url = tempDir.appendingPathComponent("multi.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .stored),
            .init(name: "b/c.txt", data: Data("BC".utf8), method: .deflate),
            .init(name: "readme.md", data: Data("docs".utf8), method: .deflate),
            .init(name: "xl/sharedStrings.xml", data: Data("<xml/>".utf8), method: .deflate),
            .init(name: "deep/nested/path/file.bin", data: Data(repeating: 0xAB, count: 100), method: .stored),
        ])

        let entries = try ZIPReader.listEntries(at: url)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(Set(entries.map(\.name)),
                       Set(["a.txt", "b/c.txt", "readme.md", "xl/sharedStrings.xml", "deep/nested/path/file.bin"]))
    }

    func testReadEntry_entryNotFound() throws {
        let url = tempDir.appendingPathComponent("lookup.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .deflate)
        ])

        let data = try ZIPReader.readEntry(named: "nonexistent.txt", from: url)
        XCTAssertNil(data)
    }

    func testListEntries_notAZIPFile() {
        let url = tempDir.appendingPathComponent("garbage.zip")
        try? Data("this is not a zip file, just random bytes".utf8).write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.notAZIPFile = error else {
                return XCTFail("expected .notAZIPFile, got \(error)")
            }
        }
    }

    func testListEntries_eocdTruncated_throwsNotAZIPFile() throws {
        // 30-byte truncation removes the 22-byte EOCD entirely, so the
        // signature-scan path in findEOCD rejects up-front rather than reaching
        // central-directory parsing.
        let url = tempDir.appendingPathComponent("corrupt.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .deflate),
            .init(name: "b.txt", data: Data("B".utf8), method: .deflate),
        ])
        let original = try Data(contentsOf: url)
        let truncated = original.prefix(original.count - 30)
        try truncated.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.notAZIPFile = error else {
                return XCTFail("expected .notAZIPFile, got \(error)")
            }
        }
    }

    func testListEntries_cdOffsetPointsBeyondArchive_throwsCorruptArchive() throws {
        // EOCD intact but centralDirectoryOffset rewritten to point past EOF —
        // this hits the "central directory offset/size out of range" branch
        // in parseEntries.
        let url = tempDir.appendingPathComponent("bad-cd-offset.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .deflate),
        ])
        var bytes = try Data(contentsOf: url)
        // Locate EOCD by scanning backward for signature 0x06054B50.
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocdOffset: Int?
        for i in stride(from: bytes.count - 22, through: 0, by: -1) {
            if Array(bytes[i..<min(i+4, bytes.count)]) == sig {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else { return XCTFail("no EOCD found in writer output") }
        // EOCD offset +16 is the 4-byte little-endian cdOffset field.
        let badOffset = UInt32(bytes.count + 1000)
        bytes[eocd + 16] = UInt8(badOffset & 0xFF)
        bytes[eocd + 17] = UInt8((badOffset >> 8) & 0xFF)
        bytes[eocd + 18] = UInt8((badOffset >> 16) & 0xFF)
        bytes[eocd + 19] = UInt8((badOffset >> 24) & 0xFF)
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.corruptArchive = error else {
                return XCTFail("expected .corruptArchive, got \(error)")
            }
        }
    }

    func testListEntries_withComment() throws {
        let url = tempDir.appendingPathComponent("commented.zip")
        let comment = "This archive was created by ZIPArchiveWriter tests"
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("hello".utf8), method: .deflate)
        ], comment: comment)

        let entries = try ZIPReader.listEntries(at: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "a.txt")
    }

    // MARK: - ZIP64 rejection (byte-level construction)

    func testListEntries_zip64Rejected() throws {
        // Build a valid ZIP then splice in an EOCD64 locator (20 bytes before EOCD).
        let baseURL = tempDir.appendingPathComponent("base.zip")
        try ZIPArchiveWriter.write(to: baseURL, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: baseURL)

        // Find EOCD signature (0x06054B50) from end of file.
        let eocdOffset = Self.locateEOCD(in: bytes)
        // Construct a fake EOCD64 locator: signature + 16 bytes of arbitrary data.
        var locator = Data()
        var sig: UInt32 = 0x07064B50
        withUnsafeBytes(of: &sig) { locator.append(contentsOf: $0) }
        locator.append(Data(repeating: 0, count: 16)) // total 20 bytes
        bytes.insert(contentsOf: locator, at: eocdOffset)

        let url = tempDir.appendingPathComponent("zip64.zip")
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.zip64Unsupported = error else {
                return XCTFail("expected .zip64Unsupported, got \(error)")
            }
        }
    }

    func testListEntries_zip64SentinelRejected() throws {
        let url = tempDir.appendingPathComponent("sentinel.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Poke 0xFFFF into EOCD "total entries" field to simulate a ZIP64 sentinel.
        let eocdOffset = Self.locateEOCD(in: bytes)
        // EOCD layout: +10 = total CD entries (uint16)
        bytes[eocdOffset + 10] = 0xFF
        bytes[eocdOffset + 11] = 0xFF
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.zip64Unsupported = error else {
                return XCTFail("expected .zip64Unsupported, got \(error)")
            }
        }
    }

    // MARK: - CRC mismatch

    func testReadEntry_emptyEntryWithNonZeroExpectedCRC_throws() throws {
        // Empty entry short-circuits without running the decompressor; the CRC
        // check must still apply (expectedCRC != 0 for empty data is corruption).
        let url = tempDir.appendingPathComponent("empty-bad-crc.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "empty.txt", data: Data(), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Patch CRC field in the Central Directory entry (offset+16) to non-zero.
        let cdOffset = Self.locateCentralDirectory(in: bytes)
        bytes[cdOffset + 16] = 0xDE
        bytes[cdOffset + 17] = 0xAD
        bytes[cdOffset + 18] = 0xBE
        bytes[cdOffset + 19] = 0xEF
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.readEntry(named: "empty.txt", from: url)) { error in
            guard case let ZIPReader.Failure.crcMismatch(_, expected, actual) = error else {
                return XCTFail("expected .crcMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 0xEFBEADDE)  // little-endian read
            XCTAssertEqual(actual, 0)
        }
    }

    func testReadEntry_crcMismatch() throws {
        let url = tempDir.appendingPathComponent("crcmiss.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("hello world".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Flip one CRC byte in the Central Directory entry.
        // We find the CD signature (0x02014B50) and modify the CRC at offset +16.
        let cdOffset = Self.locateCentralDirectory(in: bytes)
        bytes[cdOffset + 16] ^= 0xFF
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.readEntry(named: "a.txt", from: url)) { error in
            guard case ZIPReader.Failure.crcMismatch = error else {
                return XCTFail("expected .crcMismatch, got \(error)")
            }
        }
    }

    // MARK: - Rejections (byte-level)

    func testReadEntry_encryptedRejected() throws {
        let url = tempDir.appendingPathComponent("encrypted.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("secret".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Set GP flag bit 0 (encryption) in the Central Directory entry.
        // CD layout: +8 = GP flag (uint16), bit 0 = encryption.
        let cdOffset = Self.locateCentralDirectory(in: bytes)
        bytes[cdOffset + 8] |= 0x01
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.encryptedEntry = error else {
                return XCTFail("expected .encryptedEntry, got \(error)")
            }
        }
    }

    func testReadEntry_unsupportedMethod() throws {
        let url = tempDir.appendingPathComponent("method99.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("data".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Set compression method to 99 in the Central Directory entry.
        // CD layout: +10 = method (uint16).
        let cdOffset = Self.locateCentralDirectory(in: bytes)
        bytes[cdOffset + 10] = 99
        bytes[cdOffset + 11] = 0
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case let ZIPReader.Failure.unsupportedCompressionMethod(method, _) = error else {
                return XCTFail("expected .unsupportedCompressionMethod, got \(error)")
            }
            XCTAssertEqual(method, 99)
        }
    }

    func testListEntries_splitArchive() throws {
        let url = tempDir.appendingPathComponent("split.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "a.txt", data: Data("A".utf8), method: .stored)
        ])
        var bytes = try Data(contentsOf: url)

        // Set disk number in EOCD.
        // EOCD layout: +4 = this disk number (uint16).
        let eocdOffset = Self.locateEOCD(in: bytes)
        bytes[eocdOffset + 4] = 1
        bytes[eocdOffset + 5] = 0
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case ZIPReader.Failure.splitArchive = error else {
                return XCTFail("expected .splitArchive, got \(error)")
            }
        }
    }

    // MARK: - Guards (zip-bomb, file-size cap)

    func testReadEntry_zipBombRejected() throws {
        // Create a highly compressible 2 MB payload. DEFLATE will squash it
        // down to ~2 KB, and ZIPReader's output cap (maxExtractionBytes * 2
        // ≈ 1 MB) should trigger during decompression.
        let url = tempDir.appendingPathComponent("bomb.zip")
        let payload = Data(repeating: 0x41, count: 2 * 1024 * 1024) // 2 MB of 'A'
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "big.txt", data: payload, method: .deflate)
        ])

        XCTAssertThrowsError(try ZIPReader.readEntry(named: "big.txt", from: url)) { error in
            guard case let ZIPReader.Failure.corruptArchive(reason) = error else {
                return XCTFail("expected .corruptArchive, got \(error)")
            }
            XCTAssertTrue(reason.contains("exceeds limit"),
                          "reason should mention output limit: \(reason)")
        }
    }

    func testReadEntry_fileSizeCapRejected() throws {
        // Create a file larger than maxDocumentFileSize (50 MB). Don't bother
        // making it a real ZIP — the size check fires before any parsing.
        let url = tempDir.appendingPathComponent("huge.bin")
        let size = DocumentConstants.maxDocumentFileSize + 1
        // Use sparse write via truncate() to avoid actually allocating 50+ MB.
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()

        XCTAssertThrowsError(try ZIPReader.listEntries(at: url)) { error in
            guard case let ZIPReader.Failure.corruptArchive(reason) = error else {
                return XCTFail("expected .corruptArchive, got \(error)")
            }
            XCTAssertTrue(reason.contains("too large"),
                          "reason should mention size cap: \(reason)")
        }
    }

    // MARK: - Helpers for byte-level fixture manipulation

    /// Locate the EOCD signature (0x06054B50) by scanning backwards.
    private static func locateEOCD(in data: Data) -> Int {
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            if Array(data[offset..<offset + 4]) == sig { return offset }
        }
        fatalError("test fixture has no EOCD")
    }

    /// Locate the first Central Directory entry signature (0x02014B50).
    private static func locateCentralDirectory(in data: Data) -> Int {
        let sig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        for offset in 0..<(data.count - 4) {
            if Array(data[offset..<offset + 4]) == sig { return offset }
        }
        fatalError("test fixture has no central directory")
    }

    // MARK: - DEFLATE corruption (C1)

    func testReadEntry_truncatedDeflateStream_throwsDecompressionFailed() throws {
        // Build a valid DEFLATE archive, then scribble bytes in the middle of
        // the compressed payload — leaving CD + EOCD intact. Compression.framework
        // hits COMPRESSION_STATUS_ERROR and we must surface it as .decompressionFailed.
        let url = tempDir.appendingPathComponent("truncated-deflate.zip")
        let payload = Data(repeating: UInt8(ascii: "A"), count: 4096) // compressible
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "content.bin", data: payload, method: .deflate)
        ])

        var bytes = try Data(contentsOf: url)
        // LFH begins at offset 0. Signature 30 bytes + name 11 bytes = data starts at 41.
        // Flip bytes mid-payload so DEFLATE decoder errors out on a symbol mismatch.
        let dataStart = 30 + "content.bin".utf8.count
        let midPoint = dataStart + 4
        XCTAssertLessThan(midPoint + 4, bytes.count,
                          "test fixture too small to corrupt")
        for i in midPoint..<(midPoint + 4) {
            bytes[i] = bytes[i] ^ 0xFF
        }
        try bytes.write(to: url)

        XCTAssertThrowsError(try ZIPReader.readEntry(named: "content.bin", from: url)) { error in
            guard case ZIPReader.Failure.decompressionFailed(let name, _) = error else {
                return XCTFail("expected .decompressionFailed, got \(error)")
            }
            XCTAssertEqual(name, "content.bin")
        }
    }

    // MARK: - CRC-32 canonical vectors

    func testCRC32_canonicalVectors() {
        // Pins the CRC-32/IEEE table shared with ZIPArchiveWriter. The
        // "123456789" value is the universal CRC test vector. Empty-input
        // zero is required by the ZIP empty-entry contract. Any drift here
        // means previously-written archives become unreadable.
        XCTAssertEqual(CRC32.compute(Data()), 0x00000000)
        XCTAssertEqual(CRC32.compute(Data("123456789".utf8)), 0xCBF43926)
    }

    func testCRC32_roundtripVsZIPArchiveWriter() throws {
        // Cross-check: the writer and reader must agree on the same payload,
        // otherwise every archive the writer produces is unreadable.
        let url = tempDir.appendingPathComponent("crc-roundtrip.zip")
        let payload = Data("cross-consistency payload".utf8)
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "x.txt", data: payload, method: .stored)
        ])

        let decoded = try ZIPReader.readEntry(named: "x.txt", from: url)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - CRC mismatch (driven by ZIPArchiveWriter.overrideCRC)

    func testReadEntry_overriddenCRC_throwsCrcMismatch() throws {
        let url = tempDir.appendingPathComponent("wrong-crc.zip")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "text.txt",
                  data: Data("hello".utf8),
                  method: .deflate,
                  overrideCRC: 0xDEADBEEF)
        ])

        XCTAssertThrowsError(try ZIPReader.readEntry(named: "text.txt", from: url)) { error in
            guard case ZIPReader.Failure.crcMismatch(let name, let expected, _) = error else {
                return XCTFail("expected .crcMismatch, got \(error)")
            }
            XCTAssertEqual(name, "text.txt")
            XCTAssertEqual(expected, 0xDEADBEEF)
        }
    }
}
