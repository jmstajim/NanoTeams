import XCTest

@testable import NanoTeams

/// Direct pins on the append-only JSONL primitive — until 2026-08-21 it was
/// covered only through `NetworkLogger`, and its two new obligations (torn-tail
/// repair, atomic `rewrite`) are load-bearing for the task-stream split.
final class JSONLFileLogTests: XCTestCase {

    private struct Rec: Codable, Equatable { var v: String }

    var dir: URL!
    var encoder: JSONEncoder!
    var decoder: JSONDecoder!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        encoder = nil
        decoder = nil
        super.tearDown()
    }

    private func freshURL() -> URL {
        dir.appendingPathComponent("log-\(UUID().uuidString).jsonl")
    }

    func testAppendThenDecode_roundTrips() {
        let url = freshURL()
        JSONLFileLog.append(Rec(v: "a"), to: url, encoder: encoder)
        JSONLFileLog.append(Rec(v: "b"), to: url, encoder: encoder)
        XCTAssertEqual(JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder),
                       [Rec(v: "a"), Rec(v: "b")])
    }

    /// A crash mid-append leaves a partial line with no trailing newline. The
    /// FIRST append of the next process must truncate it away — otherwise the
    /// new record concatenates onto the torn one and BOTH are lost, turning a
    /// one-record loss into two.
    ///
    /// RED: drop the `claimTailRepair` block from `append` → the third record
    /// fuses with the torn bytes and only two lines decode.
    func testAppend_afterTornTail_repairsInsteadOfConcatenating() throws {
        let url = freshURL()
        // The torn state is written BY HAND (a fresh path, so this process has
        // not claimed the repair yet) — two intact lines plus a torn third.
        var bytes = Data()
        bytes.append(try encoder.encode(Rec(v: "a"))); bytes.append(0x0A)
        bytes.append(try encoder.encode(Rec(v: "b"))); bytes.append(0x0A)
        bytes.append(Data(#"{"v":"torn-no-newl"#.utf8))
        try bytes.write(to: url)

        JSONLFileLog.append(Rec(v: "c"), to: url, encoder: encoder)

        let decoded = JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder)
        XCTAssertEqual(decoded, [Rec(v: "a"), Rec(v: "b"), Rec(v: "c")],
                       "the torn line is dropped, the new record survives intact")
        let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("torn-no-newl"),
                       "the torn bytes must be physically gone, not merely undecodable")
    }

    /// A torn line larger than one backward-scan chunk still repairs — records
    /// carry file contents and can exceed 64 KB.
    func testAppend_afterHugeTornTail_repairs() throws {
        let url = freshURL()
        var bytes = Data()
        bytes.append(try encoder.encode(Rec(v: "a"))); bytes.append(0x0A)
        bytes.append(Data(("{\"v\":\"" + String(repeating: "x", count: 200_000)).utf8))
        try bytes.write(to: url)

        JSONLFileLog.append(Rec(v: "b"), to: url, encoder: encoder)

        XCTAssertEqual(JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder),
                       [Rec(v: "a"), Rec(v: "b")])
    }

    /// `rewrite` replaces the whole file atomically and later appends continue
    /// from the new content — the primitive compaction stands on.
    func testRewrite_replacesContent_andAppendContinues() throws {
        let url = freshURL()
        JSONLFileLog.append(Rec(v: "old-1"), to: url, encoder: encoder)
        JSONLFileLog.append(Rec(v: "old-2"), to: url, encoder: encoder)

        var fresh = Data()
        fresh.append(try encoder.encode(Rec(v: "kept"))); fresh.append(0x0A)
        XCTAssertTrue(JSONLFileLog.rewrite(url, with: fresh))
        JSONLFileLog.append(Rec(v: "after"), to: url, encoder: encoder)

        XCTAssertEqual(JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder),
                       [Rec(v: "kept"), Rec(v: "after")])
    }

    /// A file torn from byte ZERO — no newline anywhere — has no intact prefix:
    /// the backward scan exhausts, the repair truncates to empty, and the new
    /// record lands alone instead of fusing with the garbage.
    func testAppend_fileTornFromByteZero_truncatesToEmptyThenAppends() throws {
        let url = freshURL()
        try Data(#"{"v":"never-finished"#.utf8).write(to: url)

        JSONLFileLog.append(Rec(v: "a"), to: url, encoder: encoder)

        XCTAssertEqual(JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder),
                       [Rec(v: "a")])
        let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("never-finished"),
                       "a wholly-torn file repairs to empty, not to a fused first line")
    }

    /// Best-effort by contract: an unwritable destination reports `false`
    /// instead of throwing — `TaskStreamStore`'s go-cold recovery keys on it.
    func testRewrite_unwritableParent_returnsFalse() throws {
        let sub = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("log.jsonl")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sub.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sub.path)
        }

        XCTAssertFalse(JSONLFileLog.rewrite(url, with: Data("x\n".utf8)))
    }

    func testRewrite_createsTheFileWhenAbsent() throws {
        let url = freshURL()
        var fresh = Data()
        fresh.append(try encoder.encode(Rec(v: "only"))); fresh.append(0x0A)
        XCTAssertTrue(JSONLFileLog.rewrite(url, with: fresh))
        XCTAssertEqual(JSONLFileLog.decodeLines(Rec.self, from: url, decoder: decoder),
                       [Rec(v: "only")])
    }
}
