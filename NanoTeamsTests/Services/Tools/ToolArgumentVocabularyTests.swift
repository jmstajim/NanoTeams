import XCTest

@testable import NanoTeams

/// `ToolArgumentVocabulary` — what happens to every key a model sends that a built-in tool's
/// schema does not declare. Pure: value types only, no app class built.
final class ToolArgumentVocabularyTests: XCTestCase {

    private typealias V = ToolArgumentVocabulary

    /// A tool shaped like `search` as far as the rule is concerned.
    private let declared: Set<String> = ["query", "paths", "mode"]
    private let vocabulary: [String: UndeclaredArgument] = [
        "pattern": .alias(of: "query", detail: "`query` is literal."),
        "path": .alias(of: "paths"),
        "glob": .alias(of: "paths"),
        "headline": .ignored(reason: "a plain question has no headline"),
        "questions": .readByHandler,
    ]

    private func apply(_ args: [String: Any]) -> V.Outcome {
        V.apply(toolName: "t", args: args, declared: declared, vocabulary: vocabulary)
    }

    private func applied(_ args: [String: Any], file: StaticString = #filePath, line: UInt = #line)
        -> (args: [String: Any], notes: [String])?
    {
        guard case .applied(let out, let notes) = apply(args) else {
            XCTFail("expected the call to be dispatched", file: file, line: line)
            return nil
        }
        return (out, notes)
    }

    private func refusal(_ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .refused(let message) = apply(args) else {
            XCTFail("expected a refusal", file: file, line: line)
            return nil
        }
        return message
    }

    // MARK: - The field emission (2026-11-09)

    func testGrepsVocabulary_isRenamed_andTheModelIsTold() throws {
        let out = try XCTUnwrap(applied(["pattern": "5 / 0 = clear", "path": "calculator/tests/engine.test.js"]))
        XCTAssertEqual(out.args["query"] as? String, "5 / 0 = clear")
        XCTAssertEqual(out.args["paths"] as? String, "calculator/tests/engine.test.js",
                       "renamed only — the type gate coerces the bare string to one element afterwards")
        XCTAssertNil(out.args["pattern"]); XCTAssertNil(out.args["path"])
        XCTAssertEqual(out.notes.count, 1, "one sentence for every rename")
        let note = try XCTUnwrap(out.notes.first)
        XCTAssertTrue(note.contains("`path` as `paths`") && note.contains("`pattern` as `query`"), note)
        XCTAssertTrue(note.hasSuffix("`query` is literal."), "the alias detail rides the note: \(note)")
    }

    func testTheDeclaredNames_passUntouched_withNoNote() throws {
        let out = try XCTUnwrap(applied(["query": "x", "paths": ["a"], "mode": "regex"]))
        XCTAssertEqual(out.args.count, 3)
        XCTAssertTrue(out.notes.isEmpty)
    }

    // MARK: - Two spellings of one argument

    func testAnAliasBesideItsArgument_isRefused_namingBoth() throws {
        let message = try XCTUnwrap(refusal(["query": "x", "path": "a", "paths": ["b"]]))
        XCTAssertTrue(message.contains("`path` and `paths`"), message)
        XCTAssertTrue(message.contains("Send only `paths`"), message)
    }

    func testTwoAliasesOfOneArgument_areRefused_neverPicked() throws {
        let message = try XCTUnwrap(refusal(["query": "x", "path": "a", "glob": "b"]))
        XCTAssertTrue(message.contains("`glob` and `path`"), "sorted, both named: \(message)")
    }

    /// The gate and the runtime each read their own dictionary; the answer must not depend on
    /// which order a dictionary happened to iterate in.
    func testTheAnswer_doesNotDependOnInsertionOrder() {
        let orders: [[(String, Any)]] = [
            [("path", "a"), ("glob", "b"), ("query", "x")],
            [("query", "x"), ("glob", "b"), ("path", "a")],
            [("glob", "b"), ("query", "x"), ("path", "a")],
        ]
        var messages: Set<String> = []
        for order in orders {
            var args: [String: Any] = [:]
            for (k, v) in order { args[k] = v }
            if case .refused(let message) = apply(args) { messages.insert(message) }
        }
        XCTAssertEqual(messages.count, 1, "one refusal, worded once: \(messages)")
    }

    // MARK: - Absent values

    func testABlankOrNullAlias_carriesNothing_andIsDroppedWithoutANote() throws {
        for blank in ["", "   ", NSNull()] as [Any] {
            let out = try XCTUnwrap(applied(["query": "x", "path": blank]))
            XCTAssertNil(out.args["path"])
            XCTAssertTrue(out.notes.isEmpty)
        }
    }

    func testABlankArgument_isFilledByItsAlias() throws {
        let out = try XCTUnwrap(applied(["query": "  ", "pattern": "x"]))
        XCTAssertEqual(out.args["query"] as? String, "x", "a blank `query` is no query")
    }

    func testANullUnknownKey_isNotSent_andNotRefused() throws {
        let out = try XCTUnwrap(applied(["query": "x", "foo": NSNull()]))
        XCTAssertNil(out.args["foo"])
    }

    // MARK: - The other cells

    func testAnIgnoredKey_isRemoved_withItsReason() throws {
        let out = try XCTUnwrap(applied(["query": "x", "headline": "h"]))
        XCTAssertNil(out.args["headline"])
        XCTAssertEqual(out.notes, ["Ignored `headline`: a plain question has no headline."])
    }

    func testAKeyTheHandlerReads_stays() throws {
        let out = try XCTUnwrap(applied(["questions": [1]]))
        XCTAssertNotNil(out.args["questions"])
    }

    func testTheRuntimesRecoveryKey_isNeverRefused() throws {
        let out = try XCTUnwrap(applied([ToolRuntime.rawInputKey: "prose"]))
        XCTAssertEqual(out.args[ToolRuntime.rawInputKey] as? String, "prose")
    }

    func testAnUnknownKey_isRefused_namingItAndEveryArgument() throws {
        let message = try XCTUnwrap(refusal(["query": "x", "foo": 1]))
        XCTAssertTrue(message.hasPrefix("`t` has no argument `foo`, so this call did not run."), message)
        XCTAssertTrue(message.contains("`mode`, `paths` and `query`"), message)
        XCTAssertTrue(message.contains("omit it"), message)
        XCTAssertFalse(message.contains("pattern"), "only the tool's own names (R1.8.3): \(message)")
    }

    func testAToolWithNoArguments_saysSo() {
        guard case .refused(let message) = V.apply(
            toolName: "git_status", args: ["path": "."], declared: [], vocabulary: [:])
        else { return XCTFail("refused") }
        XCTAssertTrue(message.hasPrefix("`git_status` takes no arguments"), message)
    }

    // MARK: - The registry's own tables

    func testABuiltInTool_isReadThroughItsHandlersTable() throws {
        guard case .applied(let args, let notes)? = V.apply(
            toolName: ToolNames.search, args: ["pattern": "x", "path": "a.js"])
        else { return XCTFail("search renames grep's vocabulary") }
        XCTAssertEqual(args["query"] as? String, "x")
        XCTAssertEqual(args["paths"] as? String, "a.js")
        XCTAssertEqual(notes.count, 1)
    }

    func testAToolTheTablesDoNotDescribe_isLeftAlone() {
        XCTAssertNil(V.apply(toolName: "mcp__srv__tool", args: ["anything": 1]))
        XCTAssertNil(V.acceptedKeys(toolName: "mcp__srv__tool"))
    }

    func testAcceptedKeys_areTheDeclaredOnesAndTheTableOnes_underAnyNameSpelling() throws {
        let keys = try XCTUnwrap(V.acceptedKeys(toolName: "functions.grep"))
        XCTAssertTrue(keys.isSuperset(of: ["query", "paths", "pattern", "path"]), "\(keys)")
        XCTAssertFalse(keys.contains("thought"))
    }

    // MARK: - A spelling that carries a meaning

    func testAnAliasThatSetsAnArgument_setsItOnlyWhenTheModelDidNot() throws {
        let vocabulary: [String: UndeclaredArgument] = [
            "pattern": .alias(of: "query", detail: "Read as a regular expression.", sets: ["mode": "regex"]),
        ]
        guard case .applied(let set, let notes) = V.apply(
            toolName: "t", args: ["pattern": "foo|bar"], declared: declared, vocabulary: vocabulary)
        else { return XCTFail("dispatched") }
        XCTAssertEqual(set["mode"] as? String, "regex", "grep's pattern is a regular expression")
        XCTAssertTrue(notes.first?.hasSuffix("Read as a regular expression.") ?? false, "\(notes)")

        guard case .applied(let kept, let keptNotes) = V.apply(
            toolName: "t", args: ["pattern": "x", "mode": "substring"], declared: declared, vocabulary: vocabulary)
        else { return XCTFail("dispatched") }
        XCTAssertEqual(kept["mode"] as? String, "substring", "the model's own `mode` stands")
        XCTAssertFalse(keptNotes.first?.contains("regular expression") ?? true, "no claim about a meaning not applied")
    }

    // MARK: - Declared text arguments

    func testANumberOrABoolSentAsText_isReadAsItsSpelling_andSaid() throws {
        let properties: [String: JSONSchemaProperty] = ["query": JSONSchema.string(), "target": JSONSchema.string()]
        guard case .applied(let args, let notes) = V.readingDeclaredText(
            args: ["query": 404, "target": true], properties: properties)
        else { return XCTFail("read") }
        XCTAssertEqual(args["query"] as? String, "404", "the incident's false diagnosis came from dropping this")
        XCTAssertEqual(args["target"] as? String, "true")
        XCTAssertEqual(notes, ["`query` was read as text.", "`target` was read as text."])
    }

    func testAListOrAnObjectSentAsText_isRefusedByName() throws {
        let properties: [String: JSONSchemaProperty] = ["working_directory": JSONSchema.string()]
        guard case .refused(let message) = V.readingDeclaredText(
            args: ["working_directory": ["sub"]], properties: properties)
        else { return XCTFail("refused") }
        XCTAssertTrue(message.hasPrefix("`working_directory` must be text; received an array"), message)
    }

    func testTextAndAbsentValues_passUntouched() throws {
        let properties: [String: JSONSchemaProperty] = ["query": JSONSchema.string(), "n": JSONSchema.integer()]
        guard case .applied(let args, let notes) = V.readingDeclaredText(
            args: ["query": "x", "n": 5, "other": NSNull()], properties: properties)
        else { return XCTFail("read") }
        XCTAssertEqual(args["query"] as? String, "x")
        XCTAssertEqual(args["n"] as? Int, 5, "only text arguments are read as text")
        XCTAssertTrue(notes.isEmpty)
    }

    /// A reader counting another source's warnings (the form trainer counts its decoder's
    /// repairs) tells this step's notes apart by their shapes.
    func testItsOwnNotes_areRecognised_andNothingElseIs() {
        XCTAssertTrue(V.isNote(V.renameNote(tool: "search", renames: [("path", "paths", nil)])))
        XCTAssertTrue(V.isNote(V.ignoredNote(key: "headline", reason: "a plain question has no headline")))
        XCTAssertTrue(V.isNote(V.readAsTextNote(key: "headline")))
        XCTAssertFalse(V.isNote("Read the form's guillemets as JSON string quotes."))
        XCTAssertFalse(V.isNote("Dropped 1 surplus closing bracket after the form."))
    }

    /// A name no built-in carries — an MCP tool, a typo — has no vocabulary, and the vocabulary
    /// says so rather than lending it another tool's.
    func testANameNoBuiltInCarries_hasNoVocabulary() {
        XCTAssertTrue(ToolHandlerRegistry.undeclaredArguments(named: "mcp__docs__search").isEmpty)
        XCTAssertNil(ToolArgumentVocabulary.apply(toolName: "mcp__docs__search", args: ["pattern": "x"]))
    }
}
