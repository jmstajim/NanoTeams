import XCTest

@testable import NanoTeams

// =============================================================================
// MARK: - Shared private helpers
// =============================================================================
//
// Everything at file scope is `private`. Class names are prefixed `ToolsTail`
// so they cannot collide anywhere in the test target.

/// Decoded `{ok, data, error{code,message}}` envelope, the shape every tool
/// result carries on the wire.
private struct ToolsTailEnvelope {
    let ok: Bool
    let errorCode: String?
    let errorMessage: String?
    let data: [String: Any]?

    init?(_ json: String) {
        guard let bytes = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        self.ok = (obj["ok"] as? Bool) ?? false
        let err = obj["error"] as? [String: Any]
        self.errorCode = err?["code"] as? String
        self.errorMessage = err?["message"] as? String
        self.data = obj["data"] as? [String: Any]
    }
}

private func toolsTailEnvelope(
    _ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line
) -> ToolsTailEnvelope {
    guard let env = ToolsTailEnvelope(result.outputJSON) else {
        XCTFail("result output is not a JSON envelope: \(result.outputJSON)", file: file, line: line)
        return ToolsTailEnvelope("{\"ok\":false}")!
    }
    return env
}

private func toolsTailMakeTempDir(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolsTail-\(label)-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Little-endian byte surgery for ZIP fixtures

private func toolsTailPatchLE16(_ data: inout Data, at offset: Int, _ value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
}

private func toolsTailPatchLE32(_ data: inout Data, at offset: Int, _ value: UInt32) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func toolsTailReadLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func toolsTailMatches(_ data: Data, at offset: Int, _ sig: [UInt8]) -> Bool {
    guard offset >= 0, offset + sig.count <= data.count else { return false }
    for (i, b) in sig.enumerated() where data[offset + i] != b { return false }
    return true
}

/// Naive backward scan for the EOCD signature — deliberately WITHOUT the
/// `commentLength` cross-check that `ZIPReader.findEOCD` performs. Used to
/// prove the decoy-comment fixture actually plants a trap the naive reader
/// would fall into.
private func toolsTailNaiveEOCDScan(in data: Data) -> Int? {
    let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    guard data.count >= 22 else { return nil }
    for offset in stride(from: data.count - 22, through: 0, by: -1)
        where toolsTailMatches(data, at: offset, sig) {
        return offset
    }
    return nil
}

/// The REAL EOCD: the lowest offset whose `commentLength` field lines up with
/// end-of-file. Mirrors `ZIPReader.findEOCD`'s acceptance rule.
private func toolsTailRealEOCD(in data: Data) -> Int? {
    let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    guard data.count >= 22 else { return nil }
    for offset in stride(from: data.count - 22, through: 0, by: -1)
        where toolsTailMatches(data, at: offset, sig) {
        let commentLength = Int(UInt16(data[offset + 20]) | (UInt16(data[offset + 21]) << 8))
        if offset + 22 + commentLength == data.count { return offset }
    }
    return nil
}

private func toolsTailFirstCentralDirectory(in data: Data) -> Int? {
    let sig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
    guard data.count >= 4 else { return nil }
    for offset in 0...(data.count - 4) where toolsTailMatches(data, at: offset, sig) {
        return offset
    }
    return nil
}

// =============================================================================
// MARK: - ZIPReader: rejection + guard arms
// =============================================================================

/// The `ZIPReader` arms that only fire on MALFORMED input. Fixtures are built
/// with the pure-Swift `ZIPArchiveWriter` and then surgically corrupted — no
/// `/usr/bin/zip`, no checked-in binaries.
final class ToolsTailZIPReaderRejectionTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = toolsTailMakeTempDir("zip")
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: Fixture helpers

    /// Writes a valid archive and returns (url, bytes).
    private func writeArchive(
        _ name: String, _ entries: [ZIPArchiveWriter.EntrySpec], comment: String = ""
    ) throws -> (url: URL, bytes: Data) {
        let url = tempDir.appendingPathComponent(name)
        try ZIPArchiveWriter.write(to: url, entries: entries, comment: comment)
        return (url, try Data(contentsOf: url))
    }

    private func rewrite(_ url: URL, _ bytes: Data) throws {
        try bytes.write(to: url)
    }

    private func assertFailure(
        _ url: URL,
        reading entryName: String? = nil,
        _ check: (ZIPReader.Failure) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let block: () throws -> Void = {
            if let entryName {
                _ = try ZIPReader.readEntry(named: entryName, from: url)
            } else {
                _ = try ZIPReader.listEntries(at: url)
            }
        }
        XCTAssertThrowsError(try block(), file: file, line: line) { error in
            guard let failure = error as? ZIPReader.Failure else {
                return XCTFail("expected ZIPReader.Failure, got \(error)", file: file, line: line)
            }
            check(failure)
        }
    }

    // MARK: - loadArchive: stat / read failures

    func testLoadArchive_missingFile_reportsStatFailure() {
        let url = tempDir.appendingPathComponent("does-not-exist.zip")
        assertFailure(url) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("cannot stat ZIP file"),
                          "a stat failure must not be silently treated as an empty archive: \(reason)")
        }
    }

    func testLoadArchive_pathIsADirectory_reportsReadFailure() {
        // `attributesOfItem` succeeds for a directory (so the size guard passes),
        // but `Data(contentsOf:)` fails — the second catch in `loadArchive`.
        assertFailure(tempDir) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("cannot read ZIP file"),
                          "expected the read-failure branch, got: \(reason)")
        }
    }

    // MARK: - findEOCD

    func testFindEOCD_fileShorterThanEOCD_throwsNotAZIPFile() throws {
        // 10 bytes < the 22-byte minimum EOCD: rejected by the size guard
        // BEFORE the signature scan can index out of range.
        let url = tempDir.appendingPathComponent("tiny.zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0, 0, 0]).write(to: url)
        assertFailure(url) { failure in
            guard case .notAZIPFile = failure else {
                return XCTFail("expected .notAZIPFile, got \(failure)")
            }
        }
    }

    func testFindEOCD_zeroByteFile_throwsNotAZIPFile() throws {
        let url = tempDir.appendingPathComponent("empty.zip")
        try Data().write(to: url)
        assertFailure(url) { failure in
            guard case .notAZIPFile = failure else {
                return XCTFail("expected .notAZIPFile, got \(failure)")
            }
        }
    }

    /// The `commentLength` cross-check. An archive comment carrying the literal
    /// bytes `50 4B 05 06` makes a naive backward scan stop at the DECOY; the
    /// real EOCD sits 22 bytes earlier. Anti-vacuum: the test first proves the
    /// naive scan really is trapped, then proves `ZIPReader` is not.
    func testFindEOCD_eocdSignatureInsideComment_isSkipped() throws {
        // 30-byte comment: "PK\u{05}\u{06}" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".
        // Bytes 20..21 of the comment ('Q','R') form the decoy's commentLength
        // field, which cannot line up with EOF.
        let comment = "PK\u{05}\u{06}ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        XCTAssertEqual(Data(comment.utf8).count, 30, "fixture assumes a 30-byte single-byte comment")

        let (url, bytes) = try writeArchive(
            "decoy-comment.zip",
            [.init(name: "a.txt", data: Data("payload".utf8), method: .stored)],
            comment: comment
        )

        let naive = try XCTUnwrap(toolsTailNaiveEOCDScan(in: bytes))
        let real = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        XCTAssertEqual(naive, bytes.count - 30,
                       "fixture must plant a decoy EOCD signature inside the comment")
        XCTAssertEqual(real, bytes.count - 52, "real EOCD sits 22 + 30 bytes from EOF")
        XCTAssertNotEqual(naive, real,
                          "the decoy must be a DIFFERENT offset, otherwise this test is vacuous")

        let entries = try ZIPReader.listEntries(at: url)
        XCTAssertEqual(entries.map(\.name), ["a.txt"],
                       "commentLength verification must reject the decoy and find the real EOCD")
        XCTAssertEqual(try ZIPReader.readEntry(named: "a.txt", from: url), Data("payload".utf8))
    }

    // MARK: - rejectZIP64 (EOCD-level sentinels)

    func testRejectZIP64_cdSizeSentinel_throwsZip64Unsupported() throws {
        let (url, originalBytes) = try writeArchive(
            "zip64-cdsize.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = originalBytes
        let eocd = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        toolsTailPatchLE32(&bytes, at: eocd + 12, 0xFFFF_FFFF)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .zip64Unsupported = failure else {
                return XCTFail("expected .zip64Unsupported, got \(failure)")
            }
        }
    }

    func testRejectZIP64_cdOffsetSentinel_throwsZip64Unsupported() throws {
        let (url, original) = try writeArchive(
            "zip64-cdoffset.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let eocd = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        toolsTailPatchLE32(&bytes, at: eocd + 16, 0xFFFF_FFFF)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .zip64Unsupported = failure else {
                return XCTFail("expected .zip64Unsupported, got \(failure)")
            }
        }
    }

    // MARK: - rejectSplit

    func testRejectSplit_diskWithCentralDirectoryNonZero_throwsSplitArchive() throws {
        // The sibling field to the one the existing suite covers: EOCD+6 is
        // "disk on which the central directory starts".
        let (url, original) = try writeArchive(
            "split-cd-disk.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let eocd = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        toolsTailPatchLE16(&bytes, at: eocd + 6, 1)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .splitArchive = failure else {
                return XCTFail("expected .splitArchive, got \(failure)")
            }
        }
    }

    // MARK: - parseCentralDirectory

    func testParseCentralDirectory_truncatedMidWay_namesTheEntryIndex() throws {
        // Shrink cdSize so entry 0 fits but entry 1's 46-byte fixed header
        // doesn't. The reported index proves the loop advanced past entry 0.
        let (url, original) = try writeArchive("truncated-cd.zip", [
            .init(name: "aa.txt", data: Data("A".utf8), method: .stored),
            .init(name: "bb.txt", data: Data("B".utf8), method: .stored),
        ])
        var bytes = original
        let eocd = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        let originalCDSize = toolsTailReadLE32(bytes, at: eocd + 12)
        let shortenedCDSize: UInt32 = 46 + 6 + 10  // entry 0 (46 + name "aa.txt") + slack
        XCTAssertLessThan(shortenedCDSize, originalCDSize, "fixture must actually shorten the CD")
        toolsTailPatchLE32(&bytes, at: eocd + 12, shortenedCDSize)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("central directory truncated at entry 1"),
                          "reason should name the entry index: \(reason)")
        }
    }

    func testParseCentralDirectory_cdSizeZero_truncatesAtEntryZero() throws {
        let (url, original) = try writeArchive(
            "cd-size-zero.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let eocd = try XCTUnwrap(toolsTailRealEOCD(in: bytes))
        toolsTailPatchLE32(&bytes, at: eocd + 12, 0)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("truncated at entry 0"), reason)
        }
    }

    func testParseCentralDirectory_badEntrySignature_throwsCorruptArchive() throws {
        let (url, original) = try writeArchive(
            "bad-cd-sig.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE32(&bytes, at: cd, 0x0000_0000)
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("bad central directory entry signature"), reason)
        }
    }

    func testParseCentralDirectory_filenameLengthOverrunsCD_throwsCorruptArchive() throws {
        let (url, original) = try writeArchive(
            "long-name.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE16(&bytes, at: cd + 28, 500)  // nameLength
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("filename extends beyond central directory"), reason)
        }
    }

    func testParseCentralDirectory_entryCompressedSizeSentinel_throwsZip64Unsupported() throws {
        // The "paranoid" per-entry ZIP64 check: some writers leave the sentinel
        // in the CD even when the EOCD looks clean.
        let (url, original) = try writeArchive(
            "entry-zip64-a.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE32(&bytes, at: cd + 20, 0xFFFF_FFFF)  // compressedSize
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .zip64Unsupported = failure else {
                return XCTFail("expected .zip64Unsupported, got \(failure)")
            }
        }
    }

    func testParseCentralDirectory_entryUncompressedSizeSentinel_throwsZip64Unsupported() throws {
        let (url, original) = try writeArchive(
            "entry-zip64-b.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE32(&bytes, at: cd + 24, 0xFFFF_FFFF)  // uncompressedSize
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .zip64Unsupported = failure else {
                return XCTFail("expected .zip64Unsupported, got \(failure)")
            }
        }
    }

    func testParseCentralDirectory_entryLocalHeaderOffsetSentinel_throwsZip64Unsupported() throws {
        let (url, original) = try writeArchive(
            "entry-zip64-c.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE32(&bytes, at: cd + 42, 0xFFFF_FFFF)  // localHeaderOffset
        try rewrite(url, bytes)

        assertFailure(url) { failure in
            guard case .zip64Unsupported = failure else {
                return XCTFail("expected .zip64Unsupported, got \(failure)")
            }
        }
    }

    // MARK: - extractData

    func testExtractData_localHeaderOffsetPastEOF_throwsCorruptArchive() throws {
        let (url, original) = try writeArchive(
            "bad-lfh-offset.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        toolsTailPatchLE32(&bytes, at: cd + 42, UInt32(bytes.count + 1000))
        try rewrite(url, bytes)

        // Listing still succeeds — only reading the entry touches the LFH.
        XCTAssertEqual(try ZIPReader.listEntries(at: url).count, 1)
        assertFailure(url, reading: "a.txt") { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("local header offset out of range"), reason)
            XCTAssertTrue(reason.contains("a.txt"), "reason must name the entry: \(reason)")
        }
    }

    func testExtractData_badLocalFileHeaderSignature_throwsCorruptArchive() throws {
        let (url, original) = try writeArchive(
            "bad-lfh-sig.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        // The first LFH always starts at offset 0 in the writer's output.
        XCTAssertTrue(toolsTailMatches(bytes, at: 0, [0x50, 0x4B, 0x03, 0x04]),
                      "fixture assumes the first local file header is at offset 0")
        toolsTailPatchLE32(&bytes, at: 0, 0xDEAD_BEEF)
        try rewrite(url, bytes)

        assertFailure(url, reading: "a.txt") { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("bad local file header signature"), reason)
        }
    }

    func testExtractData_compressedSizeOverrunsFile_throwsCorruptArchive() throws {
        let (url, original) = try writeArchive(
            "data-truncated.zip", [.init(name: "a.txt", data: Data("A".utf8), method: .stored)])
        var bytes = original
        let cd = try XCTUnwrap(toolsTailFirstCentralDirectory(in: bytes))
        // Large but NOT the 0xFFFFFFFF ZIP64 sentinel, and non-zero so the
        // empty-entry short circuit doesn't fire first.
        toolsTailPatchLE32(&bytes, at: cd + 20, UInt32(bytes.count))
        try rewrite(url, bytes)

        assertFailure(url, reading: "a.txt") { failure in
            guard case let .corruptArchive(reason) = failure else {
                return XCTFail("expected .corruptArchive, got \(failure)")
            }
            XCTAssertTrue(reason.contains("entry data truncated"), reason)
        }
    }

    // MARK: - Happy-path entry metadata

    func testReadEntry_middleOfThreeEntries_resolvesItsOwnLocalHeader() throws {
        let (url, _) = try writeArchive("three.zip", [
            .init(name: "one.txt", data: Data("first".utf8), method: .stored),
            .init(name: "two.txt", data: Data("second".utf8), method: .deflate),
            .init(name: "three.txt", data: Data("third".utf8), method: .stored),
        ])
        XCTAssertEqual(try ZIPReader.readEntry(named: "two.txt", from: url), Data("second".utf8))
        XCTAssertEqual(try ZIPReader.readEntry(named: "three.txt", from: url), Data("third".utf8))
    }

    func testListEntries_firstEntryLocalHeaderOffsetIsZero() throws {
        let (url, _) = try writeArchive("offsets.zip", [
            .init(name: "one.txt", data: Data("first".utf8), method: .stored),
            .init(name: "two.txt", data: Data("second".utf8), method: .stored),
        ])
        let entries = try ZIPReader.listEntries(at: url)
        XCTAssertEqual(entries[0].localHeaderOffset, 0)
        XCTAssertGreaterThan(entries[1].localHeaderOffset, entries[0].localHeaderOffset)
        XCTAssertEqual(entries[0].expectedCRC32, CRC32.compute(Data("first".utf8)))
        XCTAssertEqual(entries[0].compressedSize, 5, "stored entries are byte-for-byte")
    }

    func testReadEntry_emptyDeflateEntry_returnsEmptyData() throws {
        // The writer emits zero compressed bytes for empty input even in
        // `.deflate` mode, so the empty-entry short circuit runs for both methods.
        let (url, _) = try writeArchive(
            "empty-deflate.zip", [.init(name: "e.txt", data: Data(), method: .deflate)])
        XCTAssertEqual(try ZIPReader.readEntry(named: "e.txt", from: url), Data())
    }

    // MARK: - Failure.description

    func testFailureDescriptions_areHumanReadable() {
        XCTAssertEqual(ZIPReader.Failure.notAZIPFile.description,
                       "not a ZIP file (EOCD signature not found)")
        XCTAssertEqual(ZIPReader.Failure.corruptArchive(reason: "why").description,
                       "corrupt ZIP archive: why")
        XCTAssertEqual(ZIPReader.Failure.zip64Unsupported.description,
                       "ZIP64 archives are not supported")
        XCTAssertEqual(ZIPReader.Failure.splitArchive.description,
                       "split/multi-volume ZIP archives are not supported")
        XCTAssertEqual(ZIPReader.Failure.encryptedEntry(name: "s.xml").description,
                       "encrypted ZIP entry not supported: s.xml")
        XCTAssertEqual(ZIPReader.Failure.unsupportedCompressionMethod(99, name: "s.xml").description,
                       "unsupported ZIP compression method 99 in entry: s.xml")
        XCTAssertEqual(ZIPReader.Failure.decompressionFailed(name: "s.xml", reason: "boom").description,
                       "DEFLATE decompression failed for s.xml: boom")
        XCTAssertEqual(
            ZIPReader.Failure.crcMismatch(name: "s.xml", expected: 0xDEAD_BEEF, actual: 0x0000_0001).description,
            "CRC-32 mismatch in s.xml (expected DEADBEEF, got 00000001)",
            "CRC values must be zero-padded 8-digit hex or the diagnostic is ambiguous")
    }

    // MARK: - CRC32 helper

    func testCRC32_singleByteAndIncrementalConsistency() {
        // A byte-at-a-time table walk must agree with the whole-buffer helper.
        let payload = Data("The quick brown fox jumps over the lazy dog".utf8)
        var c: UInt32 = 0xFFFF_FFFF
        for b in payload {
            c = CRC32.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        XCTAssertEqual(c ^ 0xFFFF_FFFF, CRC32.compute(payload))
        XCTAssertEqual(CRC32.table.count, 256)
    }
}

// =============================================================================
// MARK: - ProcessRunner: error surface + shell entry points
// =============================================================================

final class ToolsTailProcessRunnerTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = toolsTailMakeTempDir("proc")
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Error descriptions

    func testCancelledError_hasItsOwnDescription() {
        // The third `ProcessRunnerError` case — the other two are already pinned.
        XCTAssertEqual(ProcessRunnerError.cancelled.errorDescription,
                       "Process cancelled (run paused or interrupted).")
    }

    func testTimeoutError_partialOutputIsNotPartOfTheMessage() {
        // The captured output rides in the associated values, NOT the message —
        // otherwise a 100 KB partial build log would end up in the error banner.
        let err = ProcessRunnerError.timeout(30, stdout: "STDOUT-MARKER", stderr: "STDERR-MARKER")
        XCTAssertEqual(err.errorDescription, "Process timed out after 30 seconds")
        guard case let .timeout(seconds, stdout, stderr) = err else {
            return XCTFail("associated values must survive")
        }
        XCTAssertEqual(seconds, 30)
        XCTAssertEqual(stdout, "STDOUT-MARKER")
        XCTAssertEqual(stderr, "STDERR-MARKER")
    }

    // MARK: - executableNotFound

    func testRun_existingButNonExecutableFile_throwsExecutableNotFound() throws {
        // `process.run()` refuses a plain text file; the runner maps ANY launch
        // failure to `.executableNotFound`, not just a missing path.
        let script = tempDir.appendingPathComponent("not-a-binary.txt")
        try "just text, no shebang, no +x".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: script.path))
        XCTAssertFalse(fm.isExecutableFile(atPath: script.path))

        XCTAssertThrowsError(
            try ProcessRunner.run(executable: script.path, arguments: [], currentDirectory: tempDir)
        ) { error in
            guard case let ProcessRunnerError.executableNotFound(path) = error else {
                return XCTFail("expected .executableNotFound, got \(error)")
            }
            XCTAssertEqual(path, script.path)
        }
    }

    func testRun_directoryAsExecutable_throwsExecutableNotFound() {
        XCTAssertThrowsError(
            try ProcessRunner.run(executable: tempDir.path, arguments: [], currentDirectory: nil)
        ) { error in
            guard case ProcessRunnerError.executableNotFound = error else {
                return XCTFail("expected .executableNotFound, got \(error)")
            }
        }
    }

    // MARK: - Non-zero exit is RETURNED, not thrown

    func testRun_nonZeroExit_isReturnedNotThrown() throws {
        // The asymmetry that matters: timeout/cancel throw; a failing command
        // does not. Callers decide whether a non-zero exit is a failure.
        let result = try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "exit 7"], currentDirectory: tempDir)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.combinedOutput, "")
    }

    func testRunGit_nonZeroExit_isReturnedNotThrown() throws {
        // `git rev-parse` outside a repository exits non-zero and writes stderr.
        let result = try ProcessRunner.runGit(["rev-parse", "--verify", "HEAD"], in: tempDir)
        XCTAssertFalse(result.success, "a bare temp dir is not a git repository")
        XCTAssertFalse(result.stderr.isEmpty, "git must have explained itself on stderr")
        XCTAssertTrue(result.combinedOutput.contains(result.stderr))
    }

    func testRun_signalledChild_reportsNonZeroTerminationStatus() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "kill -TERM $$"], currentDirectory: tempDir)
        XCTAssertFalse(result.success, "a SIGTERMed child must not read as success")
    }

    // MARK: - Environment merge order

    func testRun_customEnvironmentOverridesInheritedValue() throws {
        // The merge starts from the process environment and then applies the
        // caller's keys — so a caller key WINS over an inherited one.
        let inheritedHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        XCTAssertFalse(inheritedHome.isEmpty, "test host must have HOME set")

        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $HOME"],
            currentDirectory: tempDir,
            environment: ["HOME": "/tmp/nanoteams-override"]
        )
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "/tmp/nanoteams-override")
        XCTAssertNotEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), inheritedHome)
    }

    func testRun_emptyEnvironmentDictionary_stillInheritsSystemEnvironment() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo ${PATH:-EMPTY}"],
            currentDirectory: tempDir,
            environment: [:]
        )
        XCTAssertFalse(result.stdout.contains("EMPTY"),
                       "an empty overrides dictionary must not wipe the inherited environment")
    }

    // MARK: - loginShell

    func testLoginShell_defaultEnvironment_resolvesToAnExecutableOrTheFallback() {
        let shell = ProcessRunner.loginShell()
        XCTAssertFalse(shell.isEmpty)
        if shell != BashConstants.fallbackShell {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell),
                          "a non-fallback result must be something we can actually exec: \(shell)")
        }
    }

    func testLoginShell_shellKeyAbsent_usesFallback() {
        XCTAssertEqual(
            ProcessRunner.loginShell(environment: ["PATH": "/usr/bin", "TERM": "xterm"]),
            BashConstants.fallbackShell)
    }

    func testLoginShell_tabAndNewlineOnlyShell_usesFallback() {
        // `trimmingCharacters(in: .whitespaces)` covers tabs; a newline-only value
        // survives that trim but is still not an executable file.
        XCTAssertEqual(ProcessRunner.loginShell(environment: ["SHELL": "\t\t"]),
                       BashConstants.fallbackShell)
        XCTAssertEqual(ProcessRunner.loginShell(environment: ["SHELL": "\n"]),
                       BashConstants.fallbackShell)
    }

    // MARK: - runShell

    func testRunShell_runsInTheGivenDirectory() throws {
        let sub = tempDir.appendingPathComponent("workdir", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        let result = try ProcessRunner.runShell("pwd", in: sub, timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("workdir"),
                      "runShell must honor `currentDirectory`. Got: \(result.stdout)")
    }

    func testRunShell_supportsShellFeatures_pipesAndRedirection() throws {
        let result = try ProcessRunner.runShell(
            "printf 'x\\ny\\nz\\n' | grep -c .", in: tempDir, timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "3")
    }

    func testRunShell_timeoutCarriesPartialStderr() {
        // The stdout half is already pinned; stderr rides the same bounded drain
        // and must survive a timeout too.
        XCTAssertThrowsError(
            try ProcessRunner.runShell(
                "echo PRE_TIMEOUT_ERR 1>&2; sleep 5", in: tempDir, timeout: 0.5, sandboxProfile: nil)
        ) { error in
            guard case let ProcessRunnerError.timeout(_, _, stderr) = error else {
                return XCTFail("expected timeout error, got \(error)")
            }
            XCTAssertTrue(stderr.contains("PRE_TIMEOUT_ERR"),
                          "partial stderr must survive a timeout. Got: \(stderr)")
        }
    }

    func testRunShell_largeOutput_doesNotDeadlockOrTruncate() throws {
        let result = try ProcessRunner.runShell(
            "seq 1 20000", in: tempDir, timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("\n20000"),
                      "the pipe drain must outlast the 64 KB pipe buffer")
    }
}

// =============================================================================
// MARK: - ToolErrorHandler: every catch arm
// =============================================================================

final class ToolsTailToolErrorHandlerTests: XCTestCase {

    private func run(
        _ args: [String: Any] = [:], _ body: @escaping () throws -> ToolExecutionResult
    ) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: "probe_tool", args: args, implementation: body)
    }

    // MARK: - SandboxPathError: restrictedPath is caught BEFORE the generic arm

    func testRestrictedPath_isReportedAsFileNotFound_notPermissionDenied() async {
        // Catch ORDER is the contract: `.restrictedPath` must stay silent
        // ("File not found.") so `.nanoteams/internal` is indistinguishable
        // from a missing file. A permission-denied answer would confirm it exists.
        let result = await run(["path": ".nanoteams/internal/teams.json"]) {
            throw SandboxPathError.restrictedPath
        }
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.fileNotFound.rawValue)
        XCTAssertEqual(env.errorMessage, "File not found.")
        XCTAssertNotEqual(env.errorCode, ToolErrorCode.permissionDenied.rawValue,
                          "the restrictedPath arm must win over the generic SandboxPathError arm")
    }

    func testOtherSandboxPathErrors_mapToPermissionDenied() async {
        let cases: [SandboxPathError] = [
            .absolutePathNotAllowed("/etc/passwd"),
            .parentTraversalNotAllowed("../../secrets"),
            .outsideSandbox("/var/root"),
        ]
        for sandboxError in cases {
            let result = await run(["path": "x"]) { throw sandboxError }
            let env = toolsTailEnvelope(result)
            XCTAssertTrue(result.isError, "\(sandboxError)")
            XCTAssertEqual(env.errorCode, ToolErrorCode.permissionDenied.rawValue, "\(sandboxError)")
            XCTAssertEqual(env.errorMessage, sandboxError.errorDescription,
                           "the actionable path guidance must reach the model verbatim")
        }
    }

    // MARK: - ToolArgumentError

    func testInvalidValueArgumentError_carriesTheSpecificDetail() async {
        // `.invalidValue` exists so the model is told the TYPE is wrong rather
        // than being sent hunting for an argument it just supplied.
        let result = await run(["depth": "deep"]) {
            throw ToolArgumentError.invalidValue(key: "depth", detail: "must be an integer")
        }
        let env = toolsTailEnvelope(result)
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Argument 'depth' must be an integer")
        XCTAssertFalse(env.errorMessage?.contains("Missing") ?? true,
                       "a present-but-wrong-typed argument must not be reported as missing")
    }

    func testMissingRequiredArgumentError_namesTheKey() async {
        let result = await run([:]) { throw ToolArgumentError.missingRequired("path") }
        let env = toolsTailEnvelope(result)
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: path")
    }

    // MARK: - ProcessRunnerError.cancelled → the unified cancel envelope

    func testProcessRunnerCancelled_routesToTheUnifiedCancelEnvelope() async {
        // A SIGTERMed subprocess must look identical on the wire to a pause that
        // landed between two tool calls, so downstream classifiers see one shape.
        let args: [String: Any] = ["scheme": "App"]
        let result = await run(args) { throw ProcessRunnerError.cancelled }
        let env = toolsTailEnvelope(result)

        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.cancelled.rawValue)
        XCTAssertEqual(env.errorMessage,
                       "Tool call cancelled by user (run paused or interrupted).")
        XCTAssertEqual(result.outputJSON,
                       makeCancelledResult(toolName: "probe_tool", argumentsJSON: "{}").outputJSON,
                       "must be byte-identical to the ToolRuntime-emitted cancel envelope")
    }

    func testProcessRunnerCancelled_preservesTheArgumentsJSON() async {
        // The cancelled arm builds its own result rather than going through
        // makeErrorResult — the args must still be threaded through.
        let args: [String: Any] = ["command": "xcodebuild", "timeout": 600]
        let result = await run(args) { throw ProcessRunnerError.cancelled }
        XCTAssertEqual(result.argumentsJSON, encodeArgsToJSON(args))
        XCTAssertEqual(result.toolName, "probe_tool")
        XCTAssertNil(result.signal)
    }

    func testProcessRunnerTimeout_doesNotGetTheCancelEnvelope() async {
        // Only `.cancelled` is special-cased; a timeout falls through to the
        // generic arm, which is what lets `bash` reinterpret it as a success.
        let result = await run([:]) {
            throw ProcessRunnerError.timeout(30, stdout: "partial", stderr: "")
        }
        let env = toolsTailEnvelope(result)
        XCTAssertEqual(env.errorCode, ToolErrorCode.commandFailed.rawValue)
        XCTAssertNotEqual(env.errorCode, ToolErrorCode.cancelled.rawValue)
        XCTAssertEqual(env.errorMessage, "Process timed out after 30 seconds")
    }

    func testProcessRunnerExecutableNotFound_fallsToCommandFailed() async {
        let result = await run([:]) { throw ProcessRunnerError.executableNotFound("/usr/bin/nope") }
        let env = toolsTailEnvelope(result)
        XCTAssertEqual(env.errorCode, ToolErrorCode.commandFailed.rawValue)
        XCTAssertEqual(env.errorMessage, "Executable not found: /usr/bin/nope")
    }

    // MARK: - Generic arm

    func testPlainSwiftError_withNoLocalizedDescription_stillProducesAnEnvelope() async {
        struct Bare: Error {}
        let result = await run([:]) { throw Bare() }
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.commandFailed.rawValue)
        XCTAssertFalse((env.errorMessage ?? "").isEmpty,
                       "even a description-less error must carry SOME message")
    }

    // MARK: - Success passthrough

    func testSuccessResult_passesThroughUntouched_includingItsSignal() async {
        // `execute` must not rewrap a handler's own result — the signal is how
        // collaboration tools reach the service layer.
        let expected = ToolExecutionResult(
            toolName: "probe_tool",
            argumentsJSON: "{}",
            outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
            isError: false,
            signal: .waitForEvents
        )
        let result = await run([:]) { expected }
        XCTAssertEqual(result, expected)
        guard case .waitForEvents? = result.signal else {
            return XCTFail("signal must survive: \(String(describing: result.signal))")
        }
    }

    func testHandlerReturnedErrorResult_isNotDoubleWrapped() async {
        // A handler that RETURNS an error envelope (rather than throwing) keeps
        // its own error code — the catch arms must not touch it.
        let result = await run(["path": "x"]) {
            makeErrorResult(toolName: "probe_tool", args: ["path": "x"],
                            code: .notADirectory, message: "Parent path is not a directory")
        }
        let env = toolsTailEnvelope(result)
        XCTAssertEqual(env.errorCode, ToolErrorCode.notADirectory.rawValue)
        XCTAssertEqual(env.errorMessage, "Parent path is not a directory")
    }

    func testEmptyToolName_stillProducesAWellFormedEnvelope() async {
        let result = await ToolErrorHandler.execute(toolName: "", args: [:]) {
            throw ToolArgumentError.missingRequired("path")
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.toolName, "")
        XCTAssertNotNil(ToolsTailEnvelope(result.outputJSON))
    }
}

// =============================================================================
// MARK: - FileWriteHandlers: guard arms
// =============================================================================

final class ToolsTailFileWriteHandlerTests: XCTestCase {
    private let fm = FileManager.default
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = toolsTailMakeTempDir("filewrite")
    }

    override func tearDown() {
        if let workDir { try? fm.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    private func resolver() -> SandboxPathResolver {
        SandboxPathResolver(workFolderRoot: workDir)
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r")
    }

    private func write(_ args: [String: Any]) async -> ToolExecutionResult {
        await WriteFileTool(resolver: resolver(), fileManager: await fm).handle(context: context(), args: args)
    }

    private func edit(_ args: [String: Any]) async -> ToolExecutionResult {
        await EditFileTool(resolver: resolver(), fileManager: await fm).handle(context: context(), args: args)
    }

    private func delete(_ args: [String: Any]) async -> ToolExecutionResult {
        await DeleteFileTool(resolver: resolver(), fileManager: await fm).handle(context: context(), args: args)
    }

    // MARK: - write_file

    func testWriteFile_parentPathIsAFile_notADirectory() async throws {
        // `a.txt` exists as a FILE; writing `a.txt/child.txt` must be refused
        // rather than attempting a create-directory that would clobber it.
        let blocker = workDir.appendingPathComponent("a.txt")
        try "i am a file".write(to: blocker, atomically: true, encoding: .utf8)

        let result = await write(["path": "a.txt/child.txt", "content": "nope"])
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.notADirectory.rawValue)
        XCTAssertEqual(env.errorMessage, "Parent path is not a directory")
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "i am a file",
                       "the blocking file must be untouched")
    }

    func testWriteFile_missingPath_isInvalidArgs() async {
        let env = await toolsTailEnvelope(write(["content": "x"]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: path")
    }

    func testWriteFile_missingContent_isInvalidArgs() async {
        let env = await toolsTailEnvelope(write(["path": "a.txt"]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: content")
        XCTAssertFalse(fm.fileExists(atPath: workDir.appendingPathComponent("a.txt").path),
                       "a rejected write must not create the file")
    }

    func testWriteFile_stringEncodedCreateDirsFalse_isHonored() async {
        // Models quote booleans; `"false"` must still suppress directory creation
        // (silently creating them would be the destructive direction).
        let result = await write(["path": "no/parent/x.txt", "content": "c", "create_dirs": "false"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.notADirectory.rawValue)
        XCTAssertFalse(fm.fileExists(atPath: workDir.appendingPathComponent("no").path))
    }

    func testWriteFile_ambiguousCreateDirsValue_keepsTheCreatingDefault() async {
        // Unrecognized spellings fall back to the default (true) rather than
        // silently flipping behavior on garbage.
        let result = await write(["path": "made/up/x.txt", "content": "c", "create_dirs": "maybe"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        XCTAssertTrue(fm.fileExists(atPath: workDir.appendingPathComponent("made/up/x.txt").path))
    }

    func testWriteFile_emptyContent_createsAnEmptyFile() async {
        let result = await write(["path": "blank.txt", "content": ""])
        XCTAssertFalse(result.isError)
        let data = toolsTailEnvelope(result).data
        XCTAssertEqual(data?["size"] as? Int, 0)
        XCTAssertEqual(data?["created"] as? Bool, true)
        XCTAssertEqual(try? String(contentsOf: workDir.appendingPathComponent("blank.txt"),
                                   encoding: .utf8), "")
    }

    func testWriteFile_size_isUTF8ByteCountNotCharacterCount() async {
        // "Привет" is 6 characters / 12 UTF-8 bytes. Reporting characters would
        // make the model's size accounting wrong for every non-ASCII file.
        let result = await write(["path": "ru.txt", "content": "Привет"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).data?["size"] as? Int, 12)
    }

    func testWriteFile_overwrite_reportsCreatedFalse() async throws {
        let target = workDir.appendingPathComponent("exists.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let result = await write(["path": "exists.txt", "content": "new"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).data?["created"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }

    // MARK: - edit_file

    func testEditFile_missingFile_isFileNotFoundNamingThePath() async {
        // The handler's own existence guard (distinct from the resolver's
        // restrictedPath mapping, which reports a bare "File not found.").
        let env = await toolsTailEnvelope(
            edit(["path": "ghost.swift", "old_text": "a", "new_text": "b"]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.fileNotFound.rawValue)
        XCTAssertEqual(env.errorMessage, "File not found: ghost.swift")
    }

    func testEditFile_nonUTF8File_failsLoudlyInsteadOfEditingGarbage() async throws {
        let binary = workDir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0xFF, 0x00, 0xC0]).write(to: binary)

        let result = await edit(["path": "blob.bin", "old_text": "a", "new_text": "b"])
        XCTAssertTrue(result.isError, "a non-UTF-8 file must not be silently rewritten")
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.commandFailed.rawValue)
        XCTAssertEqual(try Data(contentsOf: binary), Data([0xFF, 0xFE, 0xFF, 0x00, 0xC0]),
                       "the file must be byte-identical after a failed edit")
    }

    func testEditFile_missingOldText_isInvalidArgs() async throws {
        try "hello".write(to: workDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let env = await toolsTailEnvelope(edit(["path": "f.txt", "new_text": "b"]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: old_text")
    }

    func testEditFile_missingNewText_isInvalidArgs() async throws {
        try "hello".write(to: workDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let env = await toolsTailEnvelope(edit(["path": "f.txt", "old_text": "hello"]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: new_text")
    }

    func testEditFile_stringEncodedReplaceAll_isHonored() async throws {
        let target = workDir.appendingPathComponent("many.txt")
        try "x\nx\nx\n".write(to: target, atomically: true, encoding: .utf8)

        let result = await edit(["path": "many.txt", "old_text": "x", "new_text": "y",
                                 "replace_all": "true"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        XCTAssertEqual(toolsTailEnvelope(result).data?["replacements_made"] as? Int, 3)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "y\ny\ny\n")
    }

    func testEditFile_exactMatch_omitsTheFuzzyDisclosure() async throws {
        let target = workDir.appendingPathComponent("clean.txt")
        try "alpha\nbeta\n".write(to: target, atomically: true, encoding: .utf8)

        let result = await edit(["path": "clean.txt", "old_text": "beta", "new_text": "gamma"])
        XCTAssertFalse(result.isError)
        let data = toolsTailEnvelope(result).data
        XCTAssertEqual(data?["replacements_made"] as? Int, 1)
        XCTAssertNil(data?["matched_ignoring_trailing_whitespace"],
                     "an exact match must not claim the fuzzy fallback fired")
    }

    // MARK: - delete_file

    func testDeleteFile_missingPath_isInvalidArgs() async {
        let env = await toolsTailEnvelope(delete([:]))
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Missing required argument: path")
    }

    func testDeleteFile_stringEncodedMustExistFalse_isHonored() async {
        let result = await delete(["path": "nope.txt", "must_exist": "false"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        let data = toolsTailEnvelope(result).data
        XCTAssertEqual(data?["deleted"] as? Bool, false)
        XCTAssertEqual(data?["path"] as? String, "nope.txt")
    }

    func testDeleteFile_ambiguousMustExistValue_keepsTheStrictDefault() async {
        // Unrecognized spelling → default `true` → a missing file is an error.
        // Defaulting the other way would make a typo look like a successful delete.
        let result = await delete(["path": "nope.txt", "must_exist": "sure"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.fileNotFound.rawValue)
    }

    func testDeleteFile_nestedFile_isRemovedAndParentSurvives() async throws {
        let sub = workDir.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let target = sub.appendingPathComponent("doomed.txt")
        try "bye".write(to: target, atomically: true, encoding: .utf8)

        let result = await delete(["path": "nested/doomed.txt"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).data?["deleted"] as? Bool, true)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: sub.path), "only the file is removed, not its parent")
    }

    func testDeleteFile_workFolderRootItself_isRefusedAsADirectory() async {
        // "." is the documented spelling for the work-folder root; deleting it
        // would take the whole project with it, so the directory guard must fire.
        let result = await delete(["path": "."])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.notAFile.rawValue)
        XCTAssertTrue(fm.fileExists(atPath: workDir.path))
    }
}

// =============================================================================
// MARK: - BashHandlers: guard arms + bash_output action dispatch
// =============================================================================

final class ToolsTailBashHandlerTests: XCTestCase {
    private let fm = FileManager.default
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = toolsTailMakeTempDir("bash")
    }

    override func tearDown() {
        BackgroundBashRegistry.shared.terminateAll()
        if let workDir { try? fm.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    private func tool(sandboxed: Bool = false) -> BashTool {
        BashTool(
            workFolderRoot: workDir,
            resolver: SandboxPathResolver(workFolderRoot: workDir),
            fileManager: fm,
            sandboxEnabled: sandboxed,
            sandboxPermissions: BashSandboxPermissions(),
            allowUnsandboxedFallback: false)
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workDir, taskID: 41, runID: 0, roleID: "r")
    }

    // MARK: - working_directory

    func testWorkingDirectory_pointsAtAFile_isNotADirectory() async throws {
        try "text".write(to: workDir.appendingPathComponent("file.txt"),
                         atomically: true, encoding: .utf8)
        let result = await tool().handle(
            context: context(), args: ["command": "pwd", "working_directory": "file.txt"])
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.notADirectory.rawValue)
        XCTAssertEqual(env.errorMessage, "working_directory does not exist or is not a directory.")
    }

    // MARK: - timeout resolution

    func testTimeout_aboveTheCeiling_isClampedNotRejected() async {
        // Clamping keeps an over-eager timeout usable; rejecting it would cost
        // the model a round trip for a value that is harmless once bounded.
        let result = await tool().handle(
            context: context(),
            args: ["command": "echo clamped", "timeout": BashConstants.maxTimeoutMilliseconds * 10])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        XCTAssertEqual(toolsTailEnvelope(result).data?["exit_code"] as? Int, 0)
    }

    func testTimeout_stringEncoded_isAccepted() async {
        let result = await tool().handle(
            context: context(), args: ["command": "echo quoted", "timeout": "5000"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        XCTAssertEqual(toolsTailEnvelope(result).data?["exit_code"] as? Int, 0)
    }

    func testTimeout_fractional_isTruncatedTowardZeroThenValidated() async {
        // 1500.6 ms → 1500 ms → 1.5 s → floored to the 1 s minimum. Still valid.
        let result = await tool().handle(
            context: context(), args: ["command": "echo frac", "timeout": 1500.6])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
    }

    func testTimeout_nonNumericString_fallsBackToTheDefault() async {
        // `optionalInt` returns nil for garbage, and a nil timeout means "use
        // the default" — NOT "reject", which is reserved for a sign typo.
        let result = await tool().handle(
            context: context(), args: ["command": "echo dflt", "timeout": "soon"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        XCTAssertEqual(toolsTailEnvelope(result).data?["exit_code"] as? Int, 0)
    }

    // MARK: - command resolution

    func testWhitespaceOnlyCommand_isTreatedAsMissing() async {
        let result = await tool().handle(context: context(), args: ["command": "   \n  "])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.invalidArgs.rawValue)
    }

    func testEmptyStringCommand_isTreatedAsMissing() async {
        let result = await tool().handle(context: context(), args: ["command": ""])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.invalidArgs.rawValue)
    }

    // MARK: - Sandbox

    func testSandboxEnabled_reportsSandboxedTrue() async throws {
        guard fm.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        let result = await tool(sandboxed: true).handle(
            context: context(), args: ["command": "echo SANDBOX_MARKER"])
        XCTAssertFalse(result.isError, "default permissions keep system reads broad. Got: \(result.outputJSON)")
        let data = toolsTailEnvelope(result).data
        XCTAssertEqual(data?["sandboxed"] as? Bool, true)
        XCTAssertEqual(data?["exit_code"] as? Int, 0)
        XCTAssertTrue((data?["stdout"] as? String ?? "").contains("SANDBOX_MARKER"))
    }

    func testSandboxDisabled_reportsSandboxedFalse() async {
        let result = await tool(sandboxed: await false).handle(context: context(), args: ["command": "true"])
        XCTAssertEqual(toolsTailEnvelope(result).data?["sandboxed"] as? Bool, false)
    }

    // MARK: - bash_output action dispatch

    private func startBackground(_ command: String) async throws -> String {
        let start = await tool().handle(
            context: context(), args: ["command": command, "run_in_background": true])
        XCTAssertFalse(start.isError, "got \(start.outputJSON)")
        return try XCTUnwrap(toolsTailEnvelope(start).data?["command_id"] as? String)
    }

    func testBashOutput_uppercaseStopAction_stillStops() async throws {
        // The action is lowercased before dispatch — models capitalize verbs.
        let id = try await startBackground("sleep 30")
        let result = await BashOutputTool().handle(
            context: context(), args: ["command_id": id, "action": "STOP"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        let data = toolsTailEnvelope(result).data
        XCTAssertEqual(data?["status"] as? String, "stopped")
        XCTAssertEqual(data?["running"] as? Bool, false)
    }

    func testBashOutput_unknownAction_fallsThroughToRead() async throws {
        // Only "stop" is special; anything else reads. Erroring on an unknown
        // verb would strand a model that mis-spelled the read default.
        let id = try await startBackground("echo READ_FALLBACK; sleep 5")
        var sawOutput = false
        for _ in 0..<30 {
            let result = await BashOutputTool().handle(
                context: context(), args: ["command_id": id, "action": "frobnicate"])
            XCTAssertFalse(result.isError, "an unknown action must read, not error: \(result.outputJSON)")
            let data = toolsTailEnvelope(result).data
            XCTAssertNotEqual(data?["status"] as? String, "stopped")
            if (data?["output"] as? String ?? "").contains("READ_FALLBACK") {
                sawOutput = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawOutput, "an unknown action should have behaved as a read")
    }

    func testBashOutput_stopTwice_bothReportStopped() async throws {
        // The registry keeps the entry after a stop so a second call is
        // idempotent rather than an "unknown command_id" the model can't explain.
        let id = try await startBackground("sleep 30")
        let first = await BashOutputTool().handle(
            context: context(), args: ["command_id": id, "action": "stop"])
        let second = await BashOutputTool().handle(
            context: context(), args: ["command_id": id, "action": "stop"])
        XCTAssertFalse(first.isError)
        XCTAssertFalse(second.isError, "a repeat stop must stay idempotent: \(second.outputJSON)")
        XCTAssertEqual(toolsTailEnvelope(second).data?["status"] as? String, "stopped")
    }

    func testBashOutput_stopUnknownID_isInvalidArgsNamingTheID() async {
        let result = await BashOutputTool().handle(
            context: context(), args: ["command_id": "bg_nope", "action": "stop"])
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(env.errorMessage, "Unknown command_id 'bg_nope'.")
    }

    func testBashOutput_readUnknownID_isInvalidArgsNamingTheID() async {
        let result = await BashOutputTool().handle(context: context(), args: ["command_id": "bg_nope"])
        let env = toolsTailEnvelope(result)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(env.errorMessage, "Unknown command_id 'bg_nope'.")
    }

    func testBackground_startResultCarriesTheNextHintPointingAtBashOutput() async throws {
        // The hint is how a model learns the follow-up call without guessing.
        let start = await tool().handle(
            context: context(), args: ["command": "echo hinted", "run_in_background": true])
        XCTAssertFalse(start.isError)
        guard let obj = try JSONSerialization.jsonObject(with: Data(start.outputJSON.utf8))
            as? [String: Any],
            let next = obj["next"] as? [String: Any]
        else { return XCTFail("background start must carry a `next` hint: \(start.outputJSON)") }
        XCTAssertEqual(next["suggested_cmd"] as? String, ToolNames.bashOutput)
        let suggestedArgs = next["suggested_args"] as? [String: String]
        XCTAssertEqual(suggestedArgs?["command_id"],
                       toolsTailEnvelope(start).data?["command_id"] as? String)
    }

    func testBackground_withWorkingDirectory_startsInThatDirectory() async throws {
        let sub = workDir.appendingPathComponent("bgdir", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let start = await tool().handle(context: context(), args: [
            "command": "pwd", "working_directory": "bgdir", "run_in_background": true,
        ])
        XCTAssertFalse(start.isError, "got \(start.outputJSON)")
        let id = try XCTUnwrap(toolsTailEnvelope(start).data?["command_id"] as? String)

        var sawDir = false
        for _ in 0..<30 {
            let read = await BashOutputTool().handle(context: context(), args: ["command_id": id])
            if (toolsTailEnvelope(read).data?["output"] as? String ?? "").contains("bgdir") {
                sawDir = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawDir, "background command must honor working_directory")
    }

    func testBackground_invalidWorkingDirectory_isRejectedBeforeStarting() async {
        let result = await tool().handle(context: context(), args: [
            "command": "pwd", "working_directory": "missing", "run_in_background": true,
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(toolsTailEnvelope(result).errorCode, ToolErrorCode.notADirectory.rawValue)
        XCTAssertNil(toolsTailEnvelope(result).data?["command_id"])
    }
}

// =============================================================================
// MARK: - AutovisorHandlers: argument-validation arms
// =============================================================================

/// These handlers are pure validate-and-signal: no orchestrator, no I/O. Driving
/// them directly is the same entry point `ToolRuntime.executeOne` uses.
final class ToolsTailAutovisorHandlerTests: XCTestCase {

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: FileManager.default.temporaryDirectory,
            taskID: 1, runID: 0, roleID: AutovisorConstants.managerRoleSystemID)
    }

    private func assertInvalidArgs(
        _ result: ToolExecutionResult, contains fragment: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(result.isError, "expected an error envelope: \(result.outputJSON)",
                      file: file, line: line)
        XCTAssertNil(result.signal, "a rejected call must not emit a signal", file: file, line: line)
        let env = toolsTailEnvelope(result, file: file, line: line)
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue, file: file, line: line)
        if let fragment {
            XCTAssertTrue(env.errorMessage?.contains(fragment) ?? false,
                          "message should mention \(fragment): \(env.errorMessage ?? "nil")",
                          file: file, line: line)
        }
    }

    // MARK: - task_id validation across every task-targeted tool

    func testMissingTaskID_isRejectedByEveryTaskTargetedTool() async {
        let ctx = context()
        await assertInvalidArgs(TaskStatusTool().handle(context: ctx, args: [:]), contains: "task_id")
        await assertInvalidArgs(
            ControlTaskTool().handle(context: ctx, args: ["action": "pause"]), contains: "task_id")
        await assertInvalidArgs(
            ManageRoleTool().handle(context: ctx, args: ["role_id": "r", "action": "accept"]),
            contains: "task_id")
        await assertInvalidArgs(
            AnswerTaskQuestionTool().handle(context: ctx, args: ["answer": "yes"]),
            contains: "task_id")
        await assertInvalidArgs(
            MessageTaskTool().handle(context: ctx, args: ["message": "go"]), contains: "task_id")
        await assertInvalidArgs(
            ScheduleTaskTool().handle(context: ctx, args: ["interval_minutes": 5]),
            contains: "task_id")
    }

    func testNonNumericTaskID_isRejected() async {
        // `optionalInt` coerces quoted numbers but not prose — a task named
        // rather than numbered must fail loudly, not resolve to task 0.
        await assertInvalidArgs(
            TaskStatusTool().handle(context: context(), args: ["task_id": "the login one"]),
            contains: "task_id")
    }

    func testStringEncodedTaskID_isCoerced() async {
        let result = await TaskStatusTool().handle(context: context(), args: ["task_id": " 7 "])
        XCTAssertFalse(result.isError)
        guard case let .taskStatus(id)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(id, 7)
    }

    func testFractionalTaskID_truncatesTowardZero() async {
        let result = await TaskStatusTool().handle(context: context(), args: ["task_id": 7.9])
        XCTAssertFalse(result.isError)
        guard case let .taskStatus(id)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(id, 7)
    }

    // MARK: - control_task / manage_role verb decoding

    func testControlTask_missingAction_isRejected() async {
        await assertInvalidArgs(ControlTaskTool().handle(context: context(), args: ["task_id": 3]))
    }

    func testControlTask_emptyAction_isRejected() async {
        await assertInvalidArgs(
            ControlTaskTool().handle(context: context(), args: ["task_id": 3, "action": "   "]))
    }

    func testControlTask_setTimeoutWithoutArg_clearsTheTimeout() async {
        // Documented behavior: a missing `arg` CLEARS the per-run timeout — the
        // same meaning as `arg: "0"`. (Unlike `rename`, which rejects a missing
        // title, because there is no sensible "clear" for a task's name.)
        let result = await ControlTaskTool().handle(
            context: context(), args: ["task_id": 3, "action": "set_timeout"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        guard case let .controlTask(taskID, verb)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(taskID, 3)
        guard case let .setTimeout(seconds) = verb else {
            return XCTFail("expected .setTimeout, got \(verb)")
        }
        XCTAssertNil(seconds, "no `arg` means clear, not \"set to zero seconds\"")
    }

    func testControlTask_setTimeoutWithZero_clearsTheTimeout() async {
        let result = await ControlTaskTool().handle(
            context: context(), args: ["task_id": 3, "action": "set_timeout", "arg": "0"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        guard case let .controlTask(_, verb)? = result.signal,
              case let .setTimeout(seconds) = verb
        else { return XCTFail("got \(String(describing: result.signal))") }
        XCTAssertNil(seconds)
    }

    func testControlTask_setTimeoutWithSeconds_carriesThemInTheVerb() async {
        let result = await ControlTaskTool().handle(
            context: context(), args: ["task_id": 3, "action": "set_timeout", "arg": "120"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        guard case let .controlTask(taskID, verb)? = result.signal,
              case let .setTimeout(seconds) = verb
        else { return XCTFail("got \(String(describing: result.signal))") }
        XCTAssertEqual(taskID, 3)
        XCTAssertEqual(seconds, TimeInterval(120))
    }

    /// Regression: a present-but-unparseable `arg` used to CLEAR the timeout and
    /// report ok:true — the opposite of what the manager asked, with no signal it
    /// could act on. `rename` beside it already rejects an unusable `arg`.
    func testControlTask_setTimeoutWithUnparseableArg_isRejectedNotSilentlyCleared() async {
        for arg in ["600s", "10 minutes", "two hours", "abc", "-30"] {
            let result = await ControlTaskTool().handle(
                context: context(), args: ["task_id": 3, "action": "set_timeout", "arg": arg])
            XCTAssertTrue(result.isError,
                          "'\(arg)' must be rejected, not read as 'clear': \(result.outputJSON)")
            XCTAssertNil(result.signal,
                         "a rejected verb must not reach the orchestrator: \(arg)")
            XCTAssertTrue(result.outputJSON.contains(arg),
                          "the refusal must echo what it could not parse: \(result.outputJSON)")
        }
    }

    func testControlTask_renameCarriesTheTrimmedTitle() async {
        let result = await ControlTaskTool().handle(
            context: context(), args: ["task_id": 3, "action": "rename", "arg": "  New title  "])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        guard case let .controlTask(_, verb)? = result.signal,
              case let .rename(title) = verb
        else { return XCTFail("got \(String(describing: result.signal))") }
        XCTAssertEqual(title, "New title")
    }

    func testManageRole_missingAction_isRejected() async {
        await assertInvalidArgs(
            ManageRoleTool().handle(context: context(), args: ["task_id": 3, "role_id": "r"]))
    }

    func testManageRole_whitespaceOnlyRoleID_isRejected() async {
        await assertInvalidArgs(
            ManageRoleTool().handle(
                context: context(),
                args: ["task_id": 3, "role_id": "   ", "action": "accept"]),
            contains: "role_id")
    }

    func testManageRole_paddedRoleID_isTrimmedIntoTheSignal() async {
        let result = await ManageRoleTool().handle(
            context: context(),
            args: ["task_id": 3, "role_id": "  engineer  ", "action": "accept"])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")
        guard case let .manageRole(_, roleID, _)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(roleID, "engineer", "an untrimmed id would never match a step id")
    }

    func testManageRole_correctWithoutComment_isRejected() async {
        await assertInvalidArgs(
            ManageRoleTool().handle(
                context: context(), args: ["task_id": 3, "role_id": "r", "action": "correct"]))
    }

    // MARK: - answer_task_question / message_task

    func testAnswerTaskQuestion_missingAnswerKey_isRejected() async {
        await assertInvalidArgs(
            AnswerTaskQuestionTool().handle(context: context(), args: ["task_id": 3]),
            contains: "answer")
    }

    func testAnswerTaskQuestion_trimsTheAnswer() async {
        let result = await AnswerTaskQuestionTool().handle(
            context: context(), args: ["task_id": 3, "answer": "  ship it  "])
        XCTAssertFalse(result.isError)
        guard case let .answerTaskQuestion(_, answer)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(answer, "ship it")
    }

    func testMessageTask_missingMessageKey_isRejected() async {
        await assertInvalidArgs(
            MessageTaskTool().handle(context: context(), args: ["task_id": 3]), contains: "message")
    }

    func testMessageTask_withoutRoleID_targetsTheWholeTeam() async {
        let result = await MessageTaskTool().handle(
            context: context(), args: ["task_id": 3, "message": "nudge"])
        XCTAssertFalse(result.isError)
        guard case let .messageTask(taskID, text, roleID)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(taskID, 3)
        XCTAssertEqual(text, "nudge")
        XCTAssertNil(roleID, "an absent role_id must mean the whole team, not an empty-string role")
    }

    func testMessageTask_withRoleID_narrowsDelivery() async {
        let result = await MessageTaskTool().handle(
            context: context(),
            args: ["task_id": 3, "message": "nudge", "role_id": " engineer "])
        XCTAssertFalse(result.isError)
        guard case let .messageTask(_, _, roleID)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(roleID, "engineer")
    }

    func testMessageTask_blankRoleID_collapsesToWholeTeam() async {
        // `extractString` returns nil for an empty/whitespace value, so a blank
        // role_id must not become an unmatchable role name.
        let result = await MessageTaskTool().handle(
            context: context(), args: ["task_id": 3, "message": "nudge", "role_id": "   "])
        XCTAssertFalse(result.isError)
        guard case let .messageTask(_, _, roleID)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertNil(roleID)
    }

    // MARK: - schedule_task

    func testScheduleTask_missingInterval_isRejected() async {
        await assertInvalidArgs(
            ScheduleTaskTool().handle(context: context(), args: ["task_id": 3]),
            contains: "interval_minutes")
    }

    func testScheduleTask_nonNumericInterval_isRejected() async {
        await assertInvalidArgs(
            ScheduleTaskTool().handle(
                context: context(), args: ["task_id": 3, "interval_minutes": "hourly"]),
            contains: "interval_minutes")
    }

    func testScheduleTask_stringEncodedInterval_isCoerced() async {
        let result = await ScheduleTaskTool().handle(
            context: context(), args: ["task_id": 3, "interval_minutes": "15"])
        XCTAssertFalse(result.isError)
        guard case let .scheduleTask(_, minutes)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(minutes, 15)
    }

    // MARK: - set_work_folder_context

    func testSetWorkFolderContext_carriesContentVerbatim() async {
        // No trimming here by design: the folder context is prose whose leading
        // and trailing structure is the author's.
        let content = "  # Project\n\nA calculator.\n"
        let result = await SetWorkFolderContextTool().handle(
            context: context(), args: ["content": content])
        XCTAssertFalse(result.isError)
        guard case let .setWorkFolderContext(carried)? = result.signal else {
            return XCTFail("got \(String(describing: result.signal))")
        }
        XCTAssertEqual(carried, content)
    }

    func testSetWorkFolderContext_missingContent_isRejected() async {
        await assertInvalidArgs(
            SetWorkFolderContextTool().handle(context: context(), args: [:]), contains: "content")
    }

    /// Regression: whitespace-only content used to be accepted, and what this tool
    /// writes is injected into every role's prompt on every task in the folder — so
    /// one accidental empty emission silently wiped it. Every sibling text field
    /// (`brief`, `answer`, `message`, `role_id`) already trims and rejects.
    func testSetWorkFolderContext_whitespaceOnlyContent_isRejected() async {
        for blank in ["", "   ", "\n\n", " \t \n "] {
            let result = await SetWorkFolderContextTool().handle(
                context: context(), args: ["content": blank])
            XCTAssertTrue(result.isError,
                          "blank content must not silently wipe the folder context: \(result.outputJSON)")
            XCTAssertNil(result.signal, "a rejected write must not reach the orchestrator")
        }
    }

    // MARK: - Zero-argument tools

    func testZeroArgumentTools_ignoreStrayArgumentsAndStillSignal() async {
        // Small models bolt arguments onto argument-less tools; that must not
        // turn "go idle" into an error the manager cannot recover from.
        let stray: [String: Any] = ["task_id": 9, "reason": "done for now"]

        let wait = await WaitForEventsTool().handle(context: context(), args: stray)
        XCTAssertFalse(wait.isError, "got \(wait.outputJSON)")
        guard case .waitForEvents? = wait.signal else {
            return XCTFail("got \(String(describing: wait.signal))")
        }

        let list = await ListTasksTool().handle(context: context(), args: stray)
        XCTAssertFalse(list.isError, "got \(list.outputJSON)")
        guard case .listTasks? = list.signal else {
            return XCTFail("got \(String(describing: list.signal))")
        }
    }

    // MARK: - Routing metadata

    func testAllAutovisorTools_areCollaborationAndMeetingExcluded() {
        // `.collaboration` is what routes them through the deferred handler —
        // a sandbox handler cannot reach the orchestrator. `excludedInMeetings`
        // keeps folder-level management out of a meeting turn's toolset.
        let types: [any ToolHandler.Type] = [
            ListTasksTool.self, TaskStatusTool.self, CreateManagedTaskTool.self,
            ControlTaskTool.self, ManageRoleTool.self, AnswerTaskQuestionTool.self,
            MessageTaskTool.self, ScheduleTaskTool.self, SetWorkFolderContextTool.self,
            WaitForEventsTool.self,
        ]
        XCTAssertEqual(types.count, 10)
        for type in types {
            XCTAssertEqual(type.category, .collaboration, "\(type.name)")
            XCTAssertTrue(type.excludedInMeetings, "\(type.name)")
            XCTAssertFalse(type.blockedInDefaultStorage,
                           "\(type.name) manages tasks, not files — a work folder is irrelevant")
        }
    }

    func testEveryAutovisorToolName_isInToolNamesAllNames() {
        for name in [
            ToolNames.listTasks, ToolNames.taskStatus, ToolNames.createManagedTask,
            ToolNames.controlTask, ToolNames.manageRole, ToolNames.answerTaskQuestion,
            ToolNames.messageTask, ToolNames.scheduleTask, ToolNames.setWorkFolderContext,
            ToolNames.waitForEvents,
        ] {
            XCTAssertTrue(ToolNames.allNames.contains(name), name)
        }
    }
}

// =============================================================================
// MARK: - GeneratedTeamHandlers (create_team): decode-failure arms
// =============================================================================

final class ToolsTailCreateTeamHandlerTests: XCTestCase {

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: FileManager.default.temporaryDirectory,
            taskID: 1, runID: 0, roleID: "supervisor")
    }

    private func run(_ args: [String: Any]) async -> ToolExecutionResult {
        await CreateTeamTool().handle(context: context(), args: args)
    }

    private func assertRejected(
        _ result: ToolExecutionResult, contains fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(result.isError, "expected rejection: \(result.outputJSON)", file: file, line: line)
        XCTAssertNil(result.signal, "a rejected config must not install a team", file: file, line: line)
        let env = toolsTailEnvelope(result, file: file, line: line)
        XCTAssertEqual(env.errorCode, ToolErrorCode.invalidArgs.rawValue, file: file, line: line)
        XCTAssertTrue(env.errorMessage?.contains(fragment) ?? false,
                      "message should mention \(fragment): \(env.errorMessage ?? "nil")",
                      file: file, line: line)
    }

    private func validRoles() -> [[String: Any]] {
        [["name": "Engineer", "prompt": "Build it.", "produces_artifacts": ["Notes"]]]
    }

    // MARK: - team_config shape

    func testTeamConfig_numericValue_isReportedAsMissing() async {
        // Neither a dict nor a string → the else branch. Reported as missing
        // rather than "invalid", because the model supplied no config at all.
        await assertRejected(run(["team_config": 42]),
                             contains: "Missing required 'team_config' parameter")
    }

    func testTeamConfig_arrayValue_isReportedAsMissing() async {
        await assertRejected(run(["team_config": [1, 2, 3]]),
                             contains: "Missing required 'team_config' parameter")
    }

    func testTeamConfig_booleanValue_isReportedAsMissing() async {
        await assertRejected(run(["team_config": true]),
                             contains: "Missing required 'team_config' parameter")
    }

    func testTeamConfig_absent_isReportedAsMissing() async {
        await assertRejected(run([:]), contains: "Missing required 'team_config' parameter")
    }

    func testTeamConfig_stringWithMalformedJSON_isInvalidArgs() async {
        await assertRejected(run(["team_config": "{\"name\": \"X\", roles:"]),
                             contains: "Invalid team_config")
    }

    func testTeamConfig_stringHoldingAJSONArray_isInvalidArgs() async {
        // Valid JSON, wrong top-level shape.
        await assertRejected(run(["team_config": "[1,2,3]"]), contains: "Invalid team_config")
    }

    func testTeamConfig_emptyString_isInvalidArgs() async {
        await assertRejected(run(["team_config": ""]), contains: "Invalid team_config")
    }

    // MARK: - decodingMessage: each DecodingError flavour

    func testDecodeError_typeMismatch_surfacesTheDebugDescription() async {
        // `localizedDescription` alone would say "data couldn't be read"; the
        // model needs the actual mismatch to fix its emission.
        let config: [String: Any] = ["name": "T", "description": "d", "roles": "not-an-array"]
        let result = await run(["team_config": config])
        assertRejected(result, contains: "Expected to decode")
        XCTAssertFalse(
            toolsTailEnvelope(result).errorMessage?.contains("couldn't be read") ?? true,
            "the generic localizedDescription must not replace the debug description")
    }

    func testDecodeError_keyNotFound_namesTheMissingKey() async {
        // A role with no `prompt` — the one hard-required role field.
        let config: [String: Any] = [
            "name": "T", "description": "d",
            "roles": [["name": "Engineer"]],
        ]
        await assertRejected(run(["team_config": config]), contains: "prompt")
    }

    func testDecodeError_missingRolesKey_isReported() async {
        let config: [String: Any] = ["name": "T", "description": "d"]
        await assertRejected(run(["team_config": config]), contains: "roles")
    }

    func testDecodeError_valueNotFound_isReported() async {
        // `prompt: null` is a valueNotFound — a different `decodingMessage` arm
        // from the missing-key case above. Its debug description names the NULL
        // (the coding path holds "prompt"), so assert on that rather than the key.
        let json = """
        {"name": "T", "description": "d", "roles": [{"name": "E", "prompt": null}]}
        """
        let result = await run(["team_config": json])
        assertRejected(result, contains: "Invalid team_config")
        let message = toolsTailEnvelope(result).errorMessage ?? ""
        XCTAssertTrue(message.lowercased().contains("null"),
                      "a null-valued required field must be reported as such: \(message)")
    }

    func testDecodeError_dataCorrupted_carriesTheValidationMessage() async {
        let config: [String: Any] = [
            "name": "T", "description": "d",
            "roles": [String](), "artifacts": [String](),
            "supervisor_requires": [String](),
        ]
        await assertRejected(run(["team_config": config]), contains: "at least one role")
    }

    func testEveryDecodeFailure_appendsTheSnakeCaseGuidance() async {
        // The one recovery hint that fits every decode failure — dropping it on
        // any arm leaves a small model guessing at key casing.
        let failures: [[String: Any]] = [
            ["team_config": "{bad json"],
            ["team_config": ["name": "T", "description": "d", "roles": "nope"]],
            ["team_config": ["name": "T", "description": "d", "roles": [["name": "E"]]]],
            ["team_config": ["name": "T", "description": "d", "roles": [String]()]],
        ]
        for args in failures {
            let message = await toolsTailEnvelope(run(args)).errorMessage ?? ""
            XCTAssertTrue(message.contains("snake_case"), "missing guidance in: \(message)")
            XCTAssertTrue(message.contains("produces_artifacts"), "missing example in: \(message)")
        }
    }

    // MARK: - Success envelope

    func testSuccessEnvelope_reportsTeamNameAndRoleCountAsStrings() async {
        let config: [String: Any] = [
            "name": "Dev Team", "description": "Ships software",
            "roles": validRoles(),
            "artifacts": [String](), "supervisor_requires": ["Notes"],
        ]
        let result = await run(["team_config": config])
        XCTAssertFalse(result.isError, "got \(result.outputJSON)")

        let env = toolsTailEnvelope(result)
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.data?["team"] as? String, "Dev Team")
        XCTAssertEqual(env.data?["roles"] as? String, "1",
                       "the count ships as a string — the envelope is a [String: String] map")
        XCTAssertEqual(env.data?["status"] as? String, "created")
    }

    func testSuccessSignal_carriesTheDecodedConfigNotTheRawArgs() async {
        let config: [String: Any] = [
            "name": "Dev Team", "description": "Ships software",
            "roles": validRoles(), "artifacts": [String](), "supervisor_requires": ["Notes"],
        ]
        let result = await run(["team_config": config])
        guard case let .teamCreation(decoded)? = result.signal else {
            return XCTFail("expected .teamCreation, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(decoded.name, "Dev Team")
        XCTAssertEqual(decoded.roles.count, 1)
        XCTAssertEqual(decoded.roles[0].name, "Engineer")
        XCTAssertEqual(decoded.roles[0].producesArtifacts, ["Notes"])
    }

    func testStringAndDictionaryForms_produceTheSameSignal() async throws {
        // Providers loosen the schema differently; both shapes must land on the
        // same parsed config or the generated team depends on the provider.
        let config: [String: Any] = [
            "name": "Dev Team", "description": "Ships software",
            "roles": validRoles(), "artifacts": [String](), "supervisor_requires": ["Notes"],
        ]
        let asString = String(
            data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!

        let fromDict = await run(["team_config": config])
        let fromString = await run(["team_config": asString])
        XCTAssertFalse(fromDict.isError)
        XCTAssertFalse(fromString.isError)

        guard case let .teamCreation(a)? = fromDict.signal,
              case let .teamCreation(b)? = fromString.signal
        else { return XCTFail("both forms must emit .teamCreation") }
        XCTAssertEqual(a, b)
    }

    // MARK: - Static metadata

    func testCreateTeam_isNeverOfferedToRoles() {
        // Invoked exclusively via TeamGenerationService; leaving it in a role's
        // schema would let any role rewrite its own team mid-run.
        XCTAssertFalse(CreateTeamTool.availableToRoles)
        XCTAssertTrue(CreateTeamTool.excludedInMeetings)
        XCTAssertEqual(CreateTeamTool.category, .collaboration)
        XCTAssertEqual(CreateTeamTool.name, ToolNames.createTeam)
    }

    func testCreateTeam_schemaDeclaresTeamConfigRequired() {
        XCTAssertEqual(CreateTeamTool.schema.name, ToolNames.createTeam)
        XCTAssertTrue(CreateTeamTool.schema.parameters.required?.contains("team_config") ?? false,
                      "team_config must be declared required")
    }
}
