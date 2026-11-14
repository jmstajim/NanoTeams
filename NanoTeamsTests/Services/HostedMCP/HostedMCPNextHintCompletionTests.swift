import XCTest

@testable import NanoTeams

/// `HostedMCPNextHintCompletion` — the `next` hint fitted to the hosted tool it names, as the
/// envelope leaves for an external agent. `NextHint` itself is shared with the local models and
/// stays `[String: String]`; only the external copy carries `folder_id` and integer ids.
///
/// The defect (2026-11-08, live External Autovisor session): `task_status` on a review-ready task
/// answered `{"suggested_cmd":"control_task","suggested_args":{"action":"close","task_id":"3"}}`,
/// and `control_task` requires `folder_id` — so the agent that followed the hint as the
/// instructions say was refused.
final class HostedMCPNextHintCompletionTests: XCTestCase {

    private let folderID = "0F0F0F0F-1111-2222-3333-444444444444"

    private func envelope(next: String) -> String {
        #"{"data":{"folder_id":"x","task_id":3},"error":null,"meta":{"warnings":[]},"next":"# + next + #","ok":true}"#
    }

    private func completed(_ json: String, proven: String?) -> String {
        HostedMCPNextHintCompletion.completing(json, provenFolderID: proven)
    }

    private func nextObject(of json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(envelope["next"] as? [String: Any])
    }

    /// A hosted tool of this test's own, with exactly the schema shape under test.
    private func tool(_ name: String, schema: JSONSchema) -> HostedMCPCatalog.ToolDescriptor {
        HostedMCPCatalog.ToolDescriptor(
            name: name, title: name, description: "Probe.", inputSchema: schema,
            readOnlyHint: true, maxResultSizeChars: nil)
    }

    // MARK: - Filling folder_id

    /// The close hint as `AutovisorStatus.closeTaskHint` writes it, after a call that proved its
    /// folder: `folder_id` filled in, `task_id` a JSON number, the rest as it was.
    func testACloseHintGetsTheProvenFolderAndAnIntegerTaskID() throws {
        let hint = AutovisorStatus.closeTaskHint(taskID: 3, reason: "Ready to close.")
        let json = makeSuccessEnvelope(data: ["task_id": 3], next: hint)

        let next = try nextObject(of: completed(json, proven: folderID))

        XCTAssertEqual(next["suggested_cmd"] as? String, "control_task")
        XCTAssertEqual(next["reason"] as? String, "Ready to close.")
        let args = try XCTUnwrap(next["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["folder_id"] as? String, folderID)
        XCTAssertEqual(args["action"] as? String, "close")
        XCTAssertTrue(args["task_id"] is NSNumber, "task_id is an integer in the catalog: \(args)")
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, 3)
    }

    /// The exact bytes, so the shape a client parses is pinned: keys sorted like every other
    /// envelope this server writes, no escaped slashes.
    func testTheCompletedHintIsWrittenInTheWireEncodersShape() {
        let json = envelope(next: #"{"reason":"See it/now.","suggested_args":{"action":"close","task_id":"3"},"suggested_cmd":"control_task"}"#)
        XCTAssertEqual(
            completed(json, proven: folderID),
            envelope(next: #"{"reason":"See it/now.","suggested_args":{"action":"close","folder_id":"\#(folderID)","task_id":3},"suggested_cmd":"control_task"}"#))
    }

    /// No proof, no folder: a call that omitted `folder_id` or failed its check gets none —
    /// though its integers are still written as numbers.
    func testWithoutProofNoFolderIsFilled() throws {
        let json = envelope(next: #"{"suggested_args":{"task_id":"3"},"suggested_cmd":"task_status"}"#)
        let next = try nextObject(of: completed(json, proven: nil))
        let args = try XCTUnwrap(next["suggested_args"] as? [String: Any])
        XCTAssertNil(args["folder_id"])
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, 3)
    }

    /// A folder the hint already names is the handler's choice; the completion only fills a gap.
    func testAFolderTheHintAlreadyNamesIsKept() throws {
        let json = envelope(next: #"{"suggested_args":{"folder_id":"OTHER","task_id":"3"},"suggested_cmd":"task_status"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: folderID))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["folder_id"] as? String, "OTHER")
    }

    /// A hint with no arguments at all still gets the folder when its tool requires one.
    func testAHintWithoutArgumentsGetsTheFolderItsToolRequires() throws {
        let json = envelope(next: #"{"reason":"Look first.","suggested_cmd":"list_tasks"}"#)
        XCTAssertEqual(completed(json, proven: folderID), json, "list_tasks takes no folder_id")

        let status = envelope(next: #"{"reason":"Look first.","suggested_cmd":"task_status"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(status, proven: folderID))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["folder_id"] as? String, folderID)
    }

    // MARK: - What the tool's schema does and does not say

    /// A schema that names no properties types no argument: nothing becomes an integer, however
    /// numeric it reads. The folder it requires is still filled in.
    func testASchemaWithoutPropertiesTypesNoArgument_butStillNamesItsFolder() {
        let probe = tool("probe", schema: JSONSchema(type: "object", required: ["folder_id"]))
        let json = envelope(next: #"{"suggested_args":{"task_id":"3"},"suggested_cmd":"probe"}"#)
        XCTAssertEqual(
            HostedMCPNextHintCompletion.completing(json, provenFolderID: folderID, tools: [probe]),
            envelope(next: #"{"suggested_args":{"folder_id":"\#(folderID)","task_id":"3"},"suggested_cmd":"probe"}"#),
            "task_id stays a string: no property says what it is")
        XCTAssertEqual(
            HostedMCPNextHintCompletion.completing(json, provenFolderID: nil, tools: [probe]), json,
            "and with no proof there is nothing to fill, so nothing moves")
    }

    /// A schema that requires nothing requires no folder: none is filled in, proof or not, while
    /// its typed integers are still written as numbers.
    func testASchemaThatRequiresNothingGetsNoFolder_whileItsIntegersAreStillNumbers() {
        let probe = tool("probe", schema: JSONSchema(type: "object", properties: ["task_id": JSONSchema.integer("id")]))
        let json = envelope(next: #"{"suggested_args":{"task_id":"3"},"suggested_cmd":"probe"}"#)
        XCTAssertEqual(
            HostedMCPNextHintCompletion.completing(json, provenFolderID: folderID, tools: [probe]),
            envelope(next: #"{"suggested_args":{"task_id":3},"suggested_cmd":"probe"}"#))
        let numeric = envelope(next: #"{"suggested_args":{"task_id":3},"suggested_cmd":"probe"}"#)
        XCTAssertEqual(
            HostedMCPNextHintCompletion.completing(numeric, provenFolderID: folderID, tools: [probe]), numeric,
            "already a number and no folder owed: byte for byte")
    }

    /// The rewritten hint is written in the wire encoder's bytes — keys sorted, slashes unescaped,
    /// control characters and quotes escaped as `JSONEncoder` escapes them, non-ASCII raw — for
    /// everything a hint carries: prose, a nested object, an array, a bool, a null, an integer.
    /// Rendered by `JSONValue.canonicalJSONString` since 2026-11-08, so this pins the two agreeing.
    func testTheRewrittenHintMatchesTheWireEncoderByteForByte() throws {
        var members: [String: JSONValue] = [
            "reason": "Tab\there, \"quoted\", back\\slash, path/to/x, newline\n, bell\u{07}, ок 🚀",
            "also": ["z": 1, "a": [true, nil, "x/y"]],
            "flag": false,
            "suggested_args": ["action": "close", "task_id": "3"],
            "suggested_cmd": "control_task",
        ]
        let json = envelope(next: JSONValue.object(members).canonicalJSONString())
        members["suggested_args"] = ["action": "close", "folder_id": .string(folderID), "task_id": 3]
        let wireData = try JSONCoderFactory.makeWireEncoder().encode(JSONValue.object(members))
        let wire = try XCTUnwrap(String(data: wireData, encoding: .utf8))
        XCTAssertEqual(completed(json, proven: folderID), envelope(next: wire))
    }

    // MARK: - Integers

    /// Only a value that reads as an integer becomes one; anything else stays a string rather
    /// than being dropped or invented.
    func testAValueThatIsNotAnIntegerStaysAString() throws {
        let json = envelope(next: #"{"suggested_args":{"role_id":"7","task_id":"three"},"suggested_cmd":"manage_role"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: nil))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["task_id"] as? String, "three")
        XCTAssertEqual(args["role_id"] as? String, "7", "role_id is a string in the catalog, digits or not")
    }

    func testNegativeAndZeroIntegersAreNumbers() throws {
        let json = envelope(next: #"{"suggested_args":{"before":"-1","limit":"0"},"suggested_cmd":"task_log"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: nil))["suggested_args"] as? [String: Any])
        XCTAssertEqual((args["before"] as? NSNumber)?.intValue, -1)
        XCTAssertEqual((args["limit"] as? NSNumber)?.intValue, 0)
    }

    // MARK: - Lists

    /// `task_ids` is an array in the catalog, and a hint that carries the call's own writes it as
    /// JSON text (E1 review R1/R4): the text of a list becomes the list; text that is no list, and
    /// a list under a property that is not an array, stay strings.
    func testTheJSONTextOfAListBecomesTheListWhereTheSchemaSaysArray() throws {
        let json = envelope(next: #"{"suggested_args":{"after":"[1]","task_ids":"[3,4]"},"suggested_cmd":"wait_for_events"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: folderID))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["task_ids"] as? [Int], [3, 4])
        XCTAssertEqual(args["after"] as? String, "[1]", "after is a string in the catalog")
        XCTAssertNil(args["folder_id"], "wait_for_events requires no folder")

        let notAList = envelope(next: #"{"suggested_args":{"task_ids":"3"},"suggested_cmd":"wait_for_events"}"#)
        let kept = try XCTUnwrap(try nextObject(of: completed(notAList, proven: nil))["suggested_args"] as? [String: Any])
        XCTAssertEqual(kept["task_ids"] as? String, "3")
    }

    // MARK: - Only the arguments move

    /// The completion rewrites `suggested_args` and nothing else in `next`: a member the hint
    /// type does not have today — one added to `NextHint` tomorrow — comes back as it went in.
    /// Review of 2026-11-08: the hint was re-encoded through a hand-copied three-field struct, so
    /// such a member would have vanished from every hint that needed a folder or an integer.
    func testAMemberOfTheHintBesidesItsArgumentsIsKept() {
        let also = #"{"suggested_args":{"task_id":"3"},"suggested_cmd":"task_log"}"#
        let json = envelope(next: #"{"also":\#(also),"priority":2,"reason":"r","suggested_args":{"action":"close","task_id":"3"},"suggested_cmd":"control_task","urgent":true}"#)
        XCTAssertEqual(
            completed(json, proven: folderID),
            envelope(next: #"{"also":\#(also),"priority":2,"reason":"r","suggested_args":{"action":"close","folder_id":"\#(folderID)","task_id":3},"suggested_cmd":"control_task","urgent":true}"#),
            "only suggested_args changes; a nested hint's own arguments are not this hint's")
    }

    /// Arguments that are already JSON values of other kinds — a number, a boolean — are kept as
    /// they are, and the folder is still filled in. Read as `[String: String]` such a hint failed
    /// to decode and went out without the `folder_id` its tool requires.
    func testArgumentsOfOtherKindsAreKeptAndTheFolderStillFilled() throws {
        let json = envelope(next: #"{"suggested_args":{"action":"close","notify":false,"task_id":3},"suggested_cmd":"control_task"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: folderID))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["folder_id"] as? String, folderID)
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(args["notify"] as? Bool, false)
        XCTAssertEqual(args["action"] as? String, "close")
    }

    /// A `null` names no folder: the gap is filled like an absent one.
    func testANullFolderIsAGapToFill() throws {
        let json = envelope(next: #"{"suggested_args":{"folder_id":null,"task_id":"3"},"suggested_cmd":"task_status"}"#)
        let args = try XCTUnwrap(try nextObject(of: completed(json, proven: folderID))["suggested_args"] as? [String: Any])
        XCTAssertEqual(args["folder_id"] as? String, folderID)
    }

    /// Arguments that are no object are not a hint's arguments: nothing is filled into them.
    func testArgumentsThatAreNoObjectAreLeftAlone() {
        for args in [#""task_id=3""#, #"["3"]"#, "7"] {
            let json = envelope(next: #"{"suggested_args":\#(args),"suggested_cmd":"task_status"}"#)
            XCTAssertEqual(completed(json, proven: folderID), json, args)
        }
        let nullArgs = envelope(next: #"{"suggested_args":null,"suggested_cmd":"task_status"}"#)
        XCTAssertEqual(
            completed(nullArgs, proven: folderID),
            envelope(next: #"{"suggested_args":{"folder_id":"\#(folderID)"},"suggested_cmd":"task_status"}"#),
            "null arguments are no arguments, as an absent member is")
    }

    // MARK: - Left exactly as it was

    func testAnEnvelopeWithNothingToChangeIsReturnedByteForByte() {
        let cases = [
            #"{"data":{},"meta":{},"ok":true}"#,
            envelope(next: "null"),
            envelope(next: #"{"reason":"Only prose."}"#),
            envelope(next: #"{"suggested_cmd":"folder_status"}"#),
            envelope(next: #"{"suggested_args":{"path":"src"},"suggested_cmd":"list_files"}"#),
            envelope(next: #"{"suggested_args":{"action":"close","folder_id":"F","task_id":3},"suggested_cmd":"control_task"}"#),
            envelope(next: #"["not","a","hint"]"#),
            "not json at all",
        ]
        for json in cases {
            XCTAssertEqual(completed(json, proven: folderID), json, json)
        }
    }

    /// `task_result` writes its `data` in a chosen order — the index first — and only `next`
    /// may move.
    func testAnOrderedDataObjectKeepsItsOrder() {
        let data = #"{"folder_id":"x","task_id":3,"index":[{"name":"Notes"}],"deliverables":[{"content":"\"next\":{}"}],"changed_files":[]}"#
        let json = #"{"data":\#(data),"error":null,"meta":{},"next":{"suggested_args":{"action":"close","task_id":"3"},"suggested_cmd":"control_task"},"ok":true}"#
        let result = completed(json, proven: folderID)
        XCTAssertTrue(result.hasPrefix(#"{"data":\#(data),"error":null,"meta":{},"next":"#), result)
        XCTAssertTrue(result.hasSuffix(#""suggested_cmd":"control_task"},"ok":true}"#), result)
    }

    /// The catalog is the authority: a tool it does not hold — the local models' `list_files`
    /// here — is never treated as hosted.
    func testOnlyHostedToolsAreCompleted() {
        let json = envelope(next: #"{"suggested_args":{"task_id":"3"},"suggested_cmd":"list_files"}"#)
        XCTAssertEqual(completed(json, proven: folderID), json)
    }
}
