import XCTest

@testable import NanoTeams

/// Server-Sent Events as the specification writes them, not as one server happens to.
/// The multi-line `data:` case is the reason this parser exists at all: reading one
/// `data:` line as one frame hands the JSON-RPC codec half a frame.
final class SSEFrameParserTests: XCTestCase {

    private var parser: SSEFrameParser!

    override func setUp() {
        super.setUp()
        parser = SSEFrameParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - The ordinary frame

    func testDispatchesOnTheBlankLine() throws {
        XCTAssertNil(try parser.consume(line: "event: message"))
        XCTAssertNil(try parser.consume(line: #"data: {"jsonrpc":"2.0"}"#))
        let frame = try XCTUnwrap(try parser.consume(line: ""))
        XCTAssertEqual(frame.event, "message")
        XCTAssertEqual(frame.data, #"{"jsonrpc":"2.0"}"#)
    }

    func testDefaultsTheEventNameToMessage() throws {
        XCTAssertNil(try parser.consume(line: "data: x"))
        XCTAssertEqual(try parser.consume(line: "")?.event, "message")
    }

    /// The whole reason for a frame parser rather than a line parser.
    func testJoinsMultipleDataLinesWithNewlines() throws {
        for line in ["data: {", #"data:   "a": 1,"#, "data: }"] {
            XCTAssertNil(try parser.consume(line: line))
        }
        let frame = try XCTUnwrap(try parser.consume(line: ""))
        XCTAssertEqual(frame.data, "{\n  \"a\": 1,\n}")
    }

    func testEatsExactlyOneSpaceAfterTheColon() throws {
        XCTAssertNil(try parser.consume(line: "data:  two spaces"))
        XCTAssertEqual(try parser.consume(line: "")?.data, " two spaces")
    }

    func testFieldWithNoColonHasAnEmptyValue() throws {
        XCTAssertNil(try parser.consume(line: "data"))
        // An empty data line still dispatches: the field was present.
        XCTAssertEqual(try parser.consume(line: "")?.data, "")
    }

    func testEmptyEventDispatchesNothing() throws {
        // A stream of keep-alive blank lines must not produce frames to decode.
        XCTAssertNil(try parser.consume(line: ""))
        XCTAssertNil(try parser.consume(line: ""))
    }

    func testCommentLinesAreKeepAlivesNotFrames() throws {
        XCTAssertNil(try parser.consume(line: ": keep-alive"))
        XCTAssertNil(try parser.consume(line: ":"))
        XCTAssertNil(try parser.consume(line: ""))
    }

    func testUnknownFieldsAreIgnored() throws {
        XCTAssertNil(try parser.consume(line: "unknown: whatever"))
        XCTAssertNil(try parser.consume(line: "data: x"))
        XCTAssertEqual(try parser.consume(line: "")?.data, "x")
    }

    func testStripsTheCarriageReturnOfACRLFStream() throws {
        XCTAssertNil(try parser.consume(line: "data: x\r"))
        XCTAssertEqual(try parser.consume(line: "\r")?.data, "x")
    }

    // MARK: - id and retry

    func testLastEventIDPersistsAcrossEvents() throws {
        XCTAssertNil(try parser.consume(line: "id: 7"))
        XCTAssertNil(try parser.consume(line: "data: a"))
        XCTAssertEqual(try parser.consume(line: "")?.lastEventID, "7")

        XCTAssertNil(try parser.consume(line: "data: b"))
        let second = try XCTUnwrap(try parser.consume(line: ""))
        XCTAssertEqual(second.lastEventID, "7", "the id survives the event that set it")
    }

    func testIDContainingNULIsIgnored() throws {
        XCTAssertNil(try parser.consume(line: "id: 7"))
        XCTAssertNil(try parser.consume(line: "data: a"))
        _ = try parser.consume(line: "")
        XCTAssertNil(try parser.consume(line: "id: bad\u{0}id"))
        XCTAssertNil(try parser.consume(line: "data: b"))
        XCTAssertEqual(try parser.consume(line: "")?.lastEventID, "7")
    }

    func testReadsRetryAndClearsItPerEvent() throws {
        XCTAssertNil(try parser.consume(line: "retry: 2500"))
        XCTAssertNil(try parser.consume(line: "data: a"))
        XCTAssertEqual(try parser.consume(line: "")?.retryMilliseconds, 2500)

        XCTAssertNil(try parser.consume(line: "data: b"))
        XCTAssertNil(try parser.consume(line: "")?.retryMilliseconds)
    }

    func testIgnoresANonNumericRetry() throws {
        XCTAssertNil(try parser.consume(line: "retry: soon"))
        XCTAssertNil(try parser.consume(line: "data: a"))
        XCTAssertNil(try parser.consume(line: "")?.retryMilliseconds)
    }

    // MARK: - End of stream

    func testFinishDrainsAFrameThatHadNoBlankLine() throws {
        XCTAssertNil(try parser.consume(line: "data: last"))
        XCTAssertEqual(parser.finish()?.data, "last")
    }

    func testFinishOnAnEmptyParserYieldsNothing() {
        XCTAssertNil(parser.finish())
    }

    func testEventTypeDoesNotLeakIntoTheNextFrame() throws {
        XCTAssertNil(try parser.consume(line: "event: progress"))
        XCTAssertNil(try parser.consume(line: "data: a"))
        XCTAssertEqual(try parser.consume(line: "")?.event, "progress")
        XCTAssertNil(try parser.consume(line: "data: b"))
        XCTAssertEqual(try parser.consume(line: "")?.event, "message")
    }

    // MARK: - The ceiling

    /// Loud, not silent: half a JSON-RPC frame is indistinguishable from a malformed one,
    /// and half a tool result reads to a model as a complete answer.
    func testRefusesAFrameOverTheCeiling() throws {
        parser = SSEFrameParser(byteLimit: 64)
        XCTAssertThrowsError(try feed(String(repeating: "x", count: 100))) { error in
            guard let failure = error as? SSEFrameParser.Failure,
                  case .frameTooLarge(let bytes, let limit) = failure else {
                return XCTFail("\(error)")
            }
            XCTAssertGreaterThan(bytes, limit)
            XCTAssertEqual(limit, 64)
        }
    }

    func testCeilingCountsAcrossDataLinesOfOneFrame() throws {
        parser = SSEFrameParser(byteLimit: 40)
        XCTAssertNil(try feedNoDispatch(String(repeating: "a", count: 20)))
        XCTAssertThrowsError(try feedNoDispatch(String(repeating: "b", count: 30)))
    }

    func testCeilingResetsBetweenFrames() throws {
        parser = SSEFrameParser(byteLimit: 40)
        XCTAssertNil(try feedNoDispatch(String(repeating: "a", count: 30)))
        XCTAssertNotNil(try parser.consume(line: ""))
        XCTAssertNoThrow(try feedNoDispatch(String(repeating: "b", count: 30)))
    }

    func testCeilingFailureTextNamesTheRepair() {
        let failure = SSEFrameParser.Failure.frameTooLarge(bytes: 100, limit: 64)
        XCTAssertTrue(failure.localizedDescription.contains("paginate"))
        XCTAssertEqual(failure.errorDescription, failure.localizedDescription)
    }

    // MARK: - Helpers

    @discardableResult
    private func feed(_ payload: String) throws -> SSEFrameParser.Frame? {
        _ = try parser.consume(line: "data: " + payload)
        return try parser.consume(line: "")
    }

    @discardableResult
    private func feedNoDispatch(_ payload: String) throws -> SSEFrameParser.Frame? {
        try parser.consume(line: "data: " + payload)
    }
}
