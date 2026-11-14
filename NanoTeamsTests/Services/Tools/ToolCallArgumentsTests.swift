import XCTest

@testable import NanoTeams

/// `ToolCallArguments.prepare` — the one reading of a call's arguments that the runtime, the
/// approval gates and the write/loop guards share. Pure: every test here is synchronous over
/// value types, and none builds an app class.
final class ToolCallArgumentsTests: XCTestCase {

    private func dispatched(_ raw: String, _ tool: String) -> ToolCallArguments.Dispatch? {
        ToolCallArguments.prepare(rawJSON: raw, emittedName: tool).dispatched
    }

    // MARK: - The document

    func testAPlainObject_dispatchesUnderTheResolvedName() throws {
        let call = try XCTUnwrap(dispatched(#"{"path":"a.txt"}"#, "functions.read_file"))
        XCTAssertEqual(call.toolName, ToolNames.readFile)
        XCTAssertEqual(call.args["path"] as? String, "a.txt")
    }

    func testAToolNameAlias_resolvesBeforeAnythingElse() throws {
        let call = try XCTUnwrap(dispatched(#"{"command":"ls"}"#, "shell"))
        XCTAssertEqual(call.toolName, ToolNames.bash)
    }

    func testProse_reachesTheHandlerUnderTheRecoveryKey() throws {
        let call = try XCTUnwrap(dispatched("touch pwned.txt", ToolNames.bash))
        XCTAssertEqual(call.args[ToolRuntime.rawInputKey] as? String, "touch pwned.txt")
    }

    func testEmptyAndNullDocuments_areNoArguments() throws {
        for raw in ["", "   ", "null"] {
            let call = try XCTUnwrap(dispatched(raw, ToolNames.gitStatus), "document: \(raw)")
            XCTAssertTrue(call.args.isEmpty, "document: \(raw)")
        }
    }

    func testANonObjectDocument_isUnreadable() {
        guard case .unreadable = ToolCallArguments.prepare(rawJSON: "[1,2,3]", emittedName: ToolNames.readFile)
        else { return XCTFail("a list is not arguments") }
    }

    func testAReentrantEnvelope_isUnwrapped() throws {
        let call = try XCTUnwrap(dispatched(
            #"{"name":"bash","arguments":{"command":"touch pwned.txt"}}"#, ToolNames.bash))
        XCTAssertEqual(call.args["command"] as? String, "touch pwned.txt")
        XCTAssertNil(call.args["name"])
    }

    func testARawControlCharacterInsideAString_isSanitisedAndRead() throws {
        let call = try XCTUnwrap(dispatched("{\"command\":\"echo a\tb\"}", ToolNames.bash))
        XCTAssertNotNil(call.args["command"] as? String)
    }

    func testAPaddedKey_isTrimmed_andAnEmptyKeyDropped() throws {
        let call = try XCTUnwrap(dispatched(#"{"\npath":"a.txt","":""}"#, ToolNames.readFile))
        XCTAssertEqual(call.args["path"] as? String, "a.txt")
        XCTAssertEqual(Array(call.args.keys), ["path"])
    }

    // MARK: - Two keys that trim to one name

    /// Which of the two survived the trim depended on dictionary order — the gate judged one
    /// and the runtime ran the other. Neither is chosen now.
    func testTwoKeysThatTrimToOneName_areUnreadable_namingTheArgument() {
        for raw in [
            #"{"command":"ls","\ncommand":"touch pwned.txt"}"#,
            #"{" command":"ls","command\n":"touch pwned.txt"}"#,
        ] {
            guard case .unreadable(let error) = ToolCallArguments.prepare(rawJSON: raw, emittedName: ToolNames.bash)
            else { XCTFail("refused: \(raw)"); continue }
            let message = ToolErrorHandler.classify(error).message
            XCTAssertTrue(message.contains("`command`"), message)
        }
    }

    /// The inner object of a reentrant envelope is the model's document too: its keys are
    /// trimmed, and two that are one name are refused — not only the outer ones.
    func testAReentrantEnvelopesInnerKeys_areReadLikeTheOuterOnes() throws {
        let call = try XCTUnwrap(dispatched(
            #"{"name":"write_file","arguments":{" path":"a.js","content":"X"}}"#, ToolNames.writeFile))
        XCTAssertEqual(call.args["path"] as? String, "a.js")
        guard case .unreadable = ToolCallArguments.prepare(
            rawJSON: #"{"name":"bash","arguments":{"command":"ls","\ncommand":"touch pwned.txt"}}"#,
            emittedName: ToolNames.bash)
        else { return XCTFail("a collision inside the envelope is refused too") }
    }

    /// What a remembering guard keys on: a REFUSED call still has the arguments it was read as.
    func testARefusedCall_stillExposesWhatItWasReadAs() throws {
        let read = try XCTUnwrap(
            ToolCallArguments.prepare(rawJSON: #"{"query":"x","paths":5}"#, emittedName: "grep").read)
        XCTAssertEqual(read.toolName, ToolNames.search)
        XCTAssertEqual(read.args["paths"] as? Int, 5)
        XCTAssertNil(ToolCallArguments.prepare(rawJSON: "[1]", emittedName: ToolNames.search).read)
    }

    // MARK: - Routing and the type gate

    func testAMisnamedQuestionnaire_routesToTheForm() throws {
        let call = try XCTUnwrap(dispatched(#"{"headline":"h","form":{}}"#, ToolNames.askSupervisor))
        XCTAssertEqual(call.toolName, ToolNames.askSupervisorForm)
    }

    func testRouting_isNotAdoptedWhenTheCallerHasNoHandlerForIt() throws {
        // Left under the plain ask, the form's `form` is not one of its arguments.
        let read = try XCTUnwrap(ToolCallArguments.prepare(
            rawJSON: #"{"headline":"h","form":{}}"#, emittedName: ToolNames.askSupervisor,
            canRoute: { _ in false }).read)
        XCTAssertEqual(read.toolName, ToolNames.askSupervisor)
    }

    func testAValueTheCoercionCannotRead_isInvalid_underTheCanonicalName() {
        guard case .invalid(let tool, _, let message) = ToolCallArguments.prepare(
            rawJSON: #"{"query":"x","paths":5}"#, emittedName: "grep")
        else { return XCTFail("`paths: 5` is refused") }
        XCTAssertEqual(tool, ToolNames.search, "reported against the tool that would have run")
        XCTAssertTrue(message.contains("`paths`"), message)
        XCTAssertTrue(message.hasSuffix("Fix the value, or omit the argument."), message)
    }

    func testStandardSpellings_passTheTypeGate() throws {
        let call = try XCTUnwrap(dispatched(
            #"{"path":"a.txt","start_line":"3","include_line_numbers":"false"}"#, ToolNames.readLines))
        XCTAssertEqual(call.args["start_line"] as? String, "3", "coercion is the handler's — the reading passes it through")
    }

    // MARK: - Determinism

    /// The gate and the runtime each call `prepare` on the same text; the answer must not
    /// depend on which dictionary instance iterated first.
    func testTheSameDocument_preparesTheSameWay_everyTime() {
        let raw = #"{"command":"ls","\ncommand":"touch pwned.txt","timeout":"10"}"#
        for _ in 0..<50 {
            guard case .unreadable = ToolCallArguments.prepare(rawJSON: raw, emittedName: ToolNames.bash)
            else { return XCTFail("a collision is refused on every reading") }
        }
    }
}
