import XCTest

@testable import NanoTeams

/// A warning on a tool result — an argument the runtime renamed or ignored, a form the decoder
/// repaired — must reach the model whichever branch builds the tool turn. Until 2026-11-09 the
/// runtime had nowhere to put one, and the branches that rebuild the envelope after the handler
/// (a tagged file read, an exploratory search, a computer-use action, a collaboration reply, the
/// answer to a parked question) dropped the handler's own.
final class ToolResultWarningsTests: XCTestCase {

    var tags: MemoryTagStore!

    override func setUp() {
        super.setUp()
        tags = MemoryTagStore()
    }

    override func tearDown() {
        tags = nil
        super.tearDown()
    }

    private let withWarning = #"{"data":{"status":"pending"},"meta":{"truncated":false,"warnings":["Read `file_path` as `path`, the names `read_file` takes."]},"ok":true}"#

    // MARK: - The splice

    func testAppendingWarnings_addsToMetaWarnings_keepingWhatWasThere() {
        let out = appendingWarnings(["second"], toEnvelope: withWarning)
        XCTAssertEqual(metaWarnings(in: out), ["Read `file_path` as `path`, the names `read_file` takes.", "second"])
        XCTAssertTrue(out.contains(#""ok":true"#), out)
    }

    func testAppendingWarnings_givesAnEnvelopeWithoutMetaOne() {
        let out = appendingWarnings(["note"], toEnvelope: #"{"ok":true,"data":{}}"#)
        XCTAssertEqual(metaWarnings(in: out), ["note"])
    }

    func testAppendingWarnings_leavesNonEnvelopesAndEmptyNotesAlone() {
        XCTAssertEqual(appendingWarnings(["note"], toEnvelope: "plain text"), "plain text")
        XCTAssertEqual(appendingWarnings([], toEnvelope: withWarning), withWarning)
    }

    func testAppendingWarnings_doesNotEscapeSlashes() {
        let out = appendingWarnings(["note"], toEnvelope: #"{"ok":true,"data":{"path":"a/b.txt"}}"#)
        XCTAssertTrue(out.contains("a/b.txt"), out)
    }

    func testCarryingWarnings_movesThePlaceholdersWarningsOntoTheReplacement_once() {
        let answer = #"{"ok":true,"data":{"answer":"Use SQLite."}}"#
        let carried = carryingWarnings(from: withWarning, into: answer)
        XCTAssertEqual(metaWarnings(in: carried).count, 1)
        XCTAssertEqual(metaWarnings(in: carryingWarnings(from: withWarning, into: carried)).count, 1,
                       "carrying twice adds nothing")
    }

    func testMetaWarnings_isEmptyForAnEnvelopeWithNone_andForText() {
        XCTAssertEqual(metaWarnings(in: #"{"ok":true,"meta":{"warnings":[]}}"#), [])
        XCTAssertEqual(metaWarnings(in: "not json"), [])
    }

    /// A tagged result's warnings stand at the TOP of its object, not under `meta` — they are
    /// not the handler envelope's, and reading them as such would count them twice.
    func testMetaWarnings_readsOnlyMeta_notATaggedResultsTopLevelWarnings() {
        XCTAssertEqual(metaWarnings(in: #"{"ok":true,"warnings":["top"],"meta":{"truncated":false}}"#), [])
    }

    // MARK: - Branches that rebuild the envelope

    func testATaggedFileRead_carriesTheHandlersWarnings() {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: #"{"path":"a.txt"}"#,
            outputJSON: #"{"data":{"content":"alpha","start_line":1,"end_line":1,"total_lines":1},"meta":{"truncated":false,"warnings":["Read `file_path` as `path`, the names `read_file` takes."]},"ok":true}"#,
            isError: false)
        guard case .tagged(let content, _) = tags.processToolResult(result) else {
            return XCTFail("a read is tagged")
        }
        XCTAssertTrue(content.contains(#""warnings":["Read `file_path` as `path`"#), content)
    }

    func testATaggedWrite_carriesTheHandlersWarnings() {
        let result = ToolExecutionResult(
            toolName: ToolNames.writeFile,
            argumentsJSON: #"{"path":"w.txt","content":"x"}"#,
            outputJSON: #"{"data":{},"meta":{"truncated":false,"warnings":["Ignored `create_dirs`: missing parent folders are always created."]},"ok":true}"#,
            isError: false)
        guard case .tagged(let content, _) = tags.processToolResult(result) else {
            return XCTFail("a write is tagged")
        }
        XCTAssertTrue(content.contains("Ignored `create_dirs`"), content)
    }

    func testATaggedReadWithoutWarnings_isUnchangedInShape() {
        let result = ToolExecutionResult(
            toolName: ToolNames.readFile,
            argumentsJSON: #"{"path":"a.txt"}"#,
            outputJSON: #"{"data":{"content":"alpha","start_line":1,"end_line":1,"total_lines":1},"meta":{"truncated":false,"warnings":[]},"ok":true}"#,
            isError: false)
        guard case .tagged(let content, _) = tags.processToolResult(result) else {
            return XCTFail("a read is tagged")
        }
        XCTAssertFalse(content.contains("warnings"), content)
    }

    func testTheAnswerToAParkedAsk_carriesThePlaceholdersWarnings() {
        var messages = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ChatToolCall(id: "a1", name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"?"}"#),
            ]),
            ChatMessage(role: .tool, content: withWarning, toolCallID: "a1"),
        ]
        XCTAssertTrue(SupervisorAskWireResolution.resolve(
            ids: ["a1"], with: #"{"ok":true,"data":{"answer":"Yes"}}"#, in: &messages))
        let answer = messages[1].content ?? ""
        XCTAssertTrue(answer.contains(#""answer":"Yes""#), answer)
        XCTAssertEqual(metaWarnings(in: answer), ["Read `file_path` as `path`, the names `read_file` takes."])
    }

    /// A placeholder with no content carries nothing over, and the answer still lands.
    func testTheAnswerToAParkedAskWithAnEmptyPlaceholder_isTheAnswerAlone() {
        var messages = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ChatToolCall(id: "a1", name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"?"}"#),
            ]),
            ChatMessage(role: .tool, content: nil, toolCallID: "a1"),
        ]
        XCTAssertTrue(SupervisorAskWireResolution.resolve(
            ids: ["a1"], with: #"{"ok":true,"data":{"answer":"Yes"}}"#, in: &messages))
        let answer = messages[1].content ?? ""
        XCTAssertTrue(answer.contains(#""answer":"Yes""#), answer)
        XCTAssertEqual(metaWarnings(in: answer), [])
        XCTAssertFalse(answer.contains("format_note"), answer)
    }

    /// The parser's `format_note` on the parked placeholder rides the answer too — a key left out
    /// of a prompt-taught ask is still told after the Supervisor replies.
    func testTheAnswerToAParkedAsk_carriesThePlaceholdersFormatNote() {
        var messages = [
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ChatToolCall(id: "a1", name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"?"}"#),
            ]),
            ChatMessage(role: .tool, content: #"{"data":{"status":"pending"},"format_note":"`options` stood outside `arguments`","ok":true}"#, toolCallID: "a1"),
        ]
        XCTAssertTrue(SupervisorAskWireResolution.resolve(
            ids: ["a1"], with: #"{"ok":true,"data":{"answer":"Yes"}}"#, in: &messages))
        let answer = messages[1].content ?? ""
        XCTAssertTrue(answer.contains(#""format_note":"`options` stood outside `arguments`""#), answer)
        XCTAssertTrue(answer.contains(#""answer":"Yes""#), answer)
    }
}
