import XCTest

@testable import NanoTeams

/// The three shared pieces of the native wire: the JSON value a call's arguments round-trip
/// through, the tool declaration both providers accept, and the pairing of `.tool` turns
/// with the calls they answer.
final class NativeToolWireTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValue_roundTripsEveryShape() throws {
        let text = #"{"a":[1,2.5,"s",true,null,{"b":{}}],"z":"é"}"#
        let value = try XCTUnwrap(JSONValue(json: text))
        XCTAssertTrue(value.isObject)
        let again = try XCTUnwrap(JSONValue(json: value.stableString))
        XCTAssertEqual(again, value)
    }

    /// The stable spelling: sorted keys, compact, integral numbers as integers — the bytes
    /// every reader of a call's arguments sees, whichever provider produced them.
    func testStableString_sortsKeys_andKeepsIntegersIntegral() throws {
        let value = try XCTUnwrap(JSONValue(json: #"{"depth": 1, "path": "a/b", "ratio": 0.5}"#))
        XCTAssertEqual(value.stableString, #"{"depth":1,"path":"a/b","ratio":0.5}"#)
    }

    func testJSONValue_refusesNonJSON() {
        XCTAssertNil(JSONValue(json: "not json"))
        XCTAssertNil(JSONValue(json: ""))
    }

    func testJSONValue_scalarIsNotAnObject() throws {
        XCTAssertFalse(try XCTUnwrap(JSONValue(json: "[1]")).isObject)
        XCTAssertFalse(try XCTUnwrap(JSONValue(json: "\"s\"")).isObject)
    }

    // MARK: - NativeToolDeclaration

    func testDeclaration_isTheOpenAIShape_withTheAppsOwnSchema() throws {
        let schema = ToolSchema(
            name: "read_file", description: "Read a file.",
            parameters: JSONSchema(type: "object",
                                   properties: ["path": JSONSchema.string("Relative path")],
                                   required: ["path"]))
        let data = try JSONCoderFactory.makeWireEncoder().encode(NativeToolDeclaration(schema))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"function":{"description":"Read a file.","name":"read_file","parameters":{"properties":{"path":{"description":"Relative path","type":"string"}},"required":["path"],"type":"object"}},"type":"function"}"#)
    }

    /// `nativeToolsText` is what the ledger prices and fingerprints for a native request —
    /// the same encoder, the same array, so it cannot drift from what either builder sends.
    func testNativeToolsText_isTheEncodedDeclarationArray() throws {
        let tools = [ToolSchema(name: "git_status", description: "Status.", parameters: JSONSchema(type: "object"))]
        let expected = String(decoding: try JSONCoderFactory.makeWireEncoder().encode(tools.map(NativeToolDeclaration.init)), as: UTF8.self)
        XCTAssertEqual(NativeLMStudioClient.nativeToolsText(tools: tools), expected)
        XCTAssertEqual(NativeLMStudioClient.nativeToolsText(tools: []), "")
    }

    // MARK: - NativeToolTurnPairing

    private func assistant(_ calls: [(String, String)]) -> ChatMessage {
        ChatMessage(role: .assistant, content: nil,
                    toolCalls: calls.map { ChatToolCall(id: $0.0, name: $0.1, argumentsJSON: "{}") })
    }

    func testPairing_byID_consumesTheMatchingCall() {
        let wire = [
            assistant([("a", "read_file"), ("b", "git_status")]),
            ChatMessage(role: .tool, content: "r-b", toolCallID: "b"),
            ChatMessage(role: .tool, content: "r-a", toolCallID: "a"),
        ]
        let pairs = NativeToolTurnPairing.pairs(in: wire)
        XCTAssertEqual(pairs[1], .init(id: "b", name: "git_status"))
        XCTAssertEqual(pairs[2], .init(id: "a", name: "read_file"))
    }

    /// The two producers that write no id — the Supervisor's answer on re-entry and the
    /// delegation-interruption envelope — answer the preceding turn's calls IN ORDER.
    func testPairing_withoutID_isPositional() {
        let wire = [
            assistant([("a", "ask_supervisor"), ("b", "read_file")]),
            ChatMessage(role: .tool, content: "answer"),
            ChatMessage(role: .tool, content: "file"),
        ]
        let pairs = NativeToolTurnPairing.pairs(in: wire)
        XCTAssertEqual(pairs[1], .init(id: "a", name: "ask_supervisor"))
        XCTAssertEqual(pairs[2], .init(id: "b", name: "read_file"))
    }

    func testPairing_mixed_idFirstThenPositionOverTheRest() {
        let wire = [
            assistant([("a", "x"), ("b", "y"), ("c", "z")]),
            ChatMessage(role: .tool, content: "r-b", toolCallID: "b"),
            ChatMessage(role: .tool, content: "r-?"),
        ]
        let pairs = NativeToolTurnPairing.pairs(in: wire)
        XCTAssertEqual(pairs[1]?.id, "b")
        XCTAssertEqual(pairs[2], .init(id: "a", name: "x"), "the first UNCLAIMED call, not the first call")
    }

    func testPairing_unknownID_keepsItAndNamesNothing() {
        let wire = [
            assistant([("a", "x")]),
            ChatMessage(role: .tool, content: "r", toolCallID: "stranger"),
        ]
        XCTAssertEqual(NativeToolTurnPairing.pairs(in: wire)[1], .init(id: "stranger", name: nil))
    }

    func testPairing_toolWithNoPrecedingAssistant_getsAFreshID() {
        let pairs = NativeToolTurnPairing.pairs(in: [ChatMessage(role: .tool, content: "orphan")])
        XCTAssertNotNil(pairs[0]?.id)
        XCTAssertNil(pairs[0]?.name)
    }

    /// A new assistant turn resets the pending list: a result after it cannot claim a call
    /// from two turns back.
    func testPairing_resetsAtEachAssistantTurn() {
        let wire = [
            assistant([("a", "x")]),
            ChatMessage(role: .tool, content: "r-a"),
            assistant([("b", "y")]),
            ChatMessage(role: .tool, content: "r-b"),
            ChatMessage(role: .tool, content: "extra"),
        ]
        let pairs = NativeToolTurnPairing.pairs(in: wire)
        XCTAssertEqual(pairs[3]?.id, "b")
        XCTAssertNotEqual(pairs[4]?.id, "a")
        XCTAssertNil(pairs[4]?.name)
    }


    /// The decoder's last arm: a value that is none of the JSON shapes. JSON itself cannot
    /// produce one, so a property-list `Date` stands in for "not a JSON value" — inside a
    /// dictionary, since a plist cannot carry a bare date at its top level.
    func testJSONValue_refusesAValueThatIsNotJSON() throws {
        let plist = try PropertyListEncoder().encode(["when": Date(timeIntervalSince1970: 0)])
        XCTAssertThrowsError(try PropertyListDecoder().decode([String: JSONValue].self, from: plist)) { error in
            guard case DecodingError.dataCorrupted(let context)? = error as? DecodingError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(context.debugDescription, "not a JSON value")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["when"])
        }
    }
}
