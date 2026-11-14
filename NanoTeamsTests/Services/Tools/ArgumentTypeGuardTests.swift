import XCTest

@testable import NanoTeams

/// `ToolRuntime` refuses a provided argument the shared coercion cannot honour BEFORE the
/// handler runs (`argumentTypeViolations`). Until 2026-09-07 `optionalBool` /
/// `optionalStringArray` fell back to the caller's default for such a value, so
/// `search {"paths": 5}` walked the whole tree under `ok:true` and `read_lines
/// {"include_line_numbers": "off"}` re-added the gutter the model asked to drop
/// (playbook REC.5 / R3.3.4).
@MainActor
final class ArgumentTypeGuardTests: XCTestCase {

    private var workDir: URL!
    private var runtime: ToolRuntime!

    override func setUp() async throws {
        try await super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArgumentTypeGuard-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try "alpha\nbeta\n".write(to: workDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "gamma\n".write(to: workDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        runtime = ToolRegistry.defaultRegistry(workFolderRoot: workDir, toolCallsLogURL: nil).runtime
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        runtime = nil
        try await super.tearDown()
    }

    private func run(_ tool: String, _ args: String) async -> ToolExecutionResult {
        let context = ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r")
        let results = await runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: tool, argumentsJSON: args)])
        return results[0]
    }

    private func code(_ result: ToolExecutionResult) -> String? {
        guard let data = result.outputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    // MARK: - Pure

    func testViolations_nameTheKeyAndTheAcceptedForm_forTheThreeCoercedFamilies() {
        let schema = JSONSchema(type: "object", properties: [
            "flag": JSONSchemaProperty(type: "boolean", description: "d", properties: nil, required: nil, items: nil, enumValues: nil),
            "count": JSONSchemaProperty(type: "integer", description: "d", properties: nil, required: nil, items: nil, enumValues: nil),
            "paths": JSONSchemaProperty(type: "array", description: "d", properties: nil, required: nil, items: .string(), enumValues: nil),
            "name": JSONSchemaProperty(type: "string", description: "d", properties: nil, required: nil, items: nil, enumValues: nil),
        ], required: [])
        let violations = argumentTypeViolations(
            args: ["flag": "on", "count": "many", "paths": 5, "name": 42], schema: schema)
        XCTAssertEqual(violations.count, 3, "\(violations)")
        XCTAssertTrue(violations[0].hasPrefix("`count` must be an integer"), violations[0])
        XCTAssertTrue(violations[1].hasPrefix("`flag` must be a boolean — send true or false"), violations[1])
        XCTAssertTrue(violations[2].hasPrefix("`paths` must be an array of strings"), violations[2])
    }

    func testViolations_acceptEveryStandardSpelling_andTreatNullAsAbsent() {
        let schema = JSONSchema(type: "object", properties: [
            "flag": JSONSchemaProperty(type: "boolean", description: "d", properties: nil, required: nil, items: nil, enumValues: nil),
            "count": JSONSchemaProperty(type: "integer", description: "d", properties: nil, required: nil, items: nil, enumValues: nil),
            "paths": JSONSchemaProperty(type: "array", description: "d", properties: nil, required: nil, items: .string(), enumValues: nil),
        ], required: [])
        XCTAssertEqual(argumentTypeViolations(
            args: ["flag": "yes", "count": " 501 ", "paths": "one"], schema: schema), [])
        XCTAssertEqual(argumentTypeViolations(
            args: ["flag": 1, "count": "501.0", "paths": ["a", 2]], schema: schema), [])
        XCTAssertEqual(argumentTypeViolations(
            args: ["flag": NSNull(), "count": NSNull(), "paths": NSNull()], schema: schema), [])
        XCTAssertEqual(argumentTypeViolations(args: [:], schema: schema), [])
    }

    // MARK: - Through the runtime

    func testSearch_pathsAsANumber_isRefusedAsInvalidArgs_neverAWholeTreeWalk() async {
        let result = await run(ToolNames.search, #"{"query":"alpha","paths":5}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(code(result), ToolErrorCode.invalidArgs.rawValue, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("`paths` must be an array of strings"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("a.txt"), "no search ran: \(result.outputJSON)")
    }

    func testReadLines_includeLineNumbersAsOff_isRefused_andTrueStringIsAccepted() async {
        let refused = await run(ToolNames.readLines, #"{"path":"a.txt","start_line":1,"end_line":2,"include_line_numbers":"off"}"#)
        XCTAssertEqual(code(refused), ToolErrorCode.invalidArgs.rawValue, refused.outputJSON)
        XCTAssertTrue(refused.outputJSON.contains("`include_line_numbers` must be a boolean"), refused.outputJSON)

        let accepted = await run(ToolNames.readLines, #"{"path":"a.txt","start_line":"1","end_line":"2","include_line_numbers":"true"}"#)
        XCTAssertFalse(accepted.isError, "standard spellings still coerce: \(accepted.outputJSON)")
    }

    // MARK: - Argument names: the field replay (2026-11-09)

    /// `qwen3.6-35b-a3b-splash`, LM Studio, native tools: `search` sent grep's vocabulary.
    /// Until the vocabulary both keys were dropped — the keyword AND the scope — and the call
    /// was refused for "an empty query". Now both are renamed, the search stays inside the file
    /// it was sent, and the result says what was read as what.
    func testFieldReplay_grepsVocabulary_searchesOnlyTheNamedFile_andSaysSo() async throws {
        try writeTwoFilesWithTheSameLine()
        let r = await run(ToolNames.search, #"{"pattern":"5 / 0 = clear","path":"engine.test.js"}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("engine.test.js"), r.outputJSON)
        XCTAssertFalse(r.outputJSON.contains("other.js"), "scoped to the file it was sent: \(r.outputJSON)")
        let warnings = metaWarnings(in: r.outputJSON)
        XCTAssertTrue(
            warnings.contains { $0.contains("`path` as `paths`") && $0.contains("`pattern` as `query`") },
            "the model is told what it sent was read as what: \(warnings)")
    }

    /// The model's own retry: `query` right, `path` still singular. Until the vocabulary this
    /// searched the WHOLE work folder under `ok:true` and found the line in a file nobody asked
    /// about.
    func testFieldReplay_queryWithASingularPath_staysInsideThatFile() async throws {
        try writeTwoFilesWithTheSameLine()
        let r = await run(ToolNames.search, #"{"path":"engine.test.js","query":"5 / 0 = clear"}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertFalse(r.outputJSON.contains("other.js"), "never a whole-tree walk: \(r.outputJSON)")
    }

    func testAnUnknownKey_isRefusedBeforeTheHandler_namingIt() async {
        let r = await run(ToolNames.search, #"{"query":"alpha","foo":1}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("no argument `foo`"), r.outputJSON)
        XCTAssertFalse(r.outputJSON.contains("a.txt"), "nothing ran: \(r.outputJSON)")
    }

    func testAnAliasBesideItsArgument_isRefused() async {
        let r = await run(ToolNames.search, #"{"query":"alpha","path":"a.txt","paths":["b.txt"]}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("Send only `paths`"), r.outputJSON)
    }

    /// The type gate reads the RENAMED arguments, so it names the argument the tool has.
    func testAnAliasWithAValueTheCoercionCannotRead_isNamedAsTheArgument() async {
        let r = await run(ToolNames.search, #"{"query":"alpha","path":5}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("`paths` must be an array"), r.outputJSON)
    }

    func testAToolWithNoArguments_refusesOne() async {
        let r = await run(ToolNames.gitStatus, #"{"path":"."}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("takes no arguments"), r.outputJSON)
    }

    /// Refused means NOTHING ran: a write with an argument the tool does not take writes no file.
    func testAnUnknownKeyOnAWrite_writesNothing() async {
        let r = await run(ToolNames.writeFile, #"{"path":"w.txt","content":"X","overwrite":true}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("w.txt").path))
    }

    /// An ignored key runs the call — and the result says why the key did nothing.
    func testAnIgnoredKey_runs_andSaysWhy() async {
        let r = await run(ToolNames.askSupervisor, #"{"question":"Which database?","headline":"DB"}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(
            metaWarnings(in: r.outputJSON).contains("Ignored `headline`: a plain question has no headline."),
            r.outputJSON)
    }

    /// The agent harness's `file_path` reads the file, and the tool's own name is taught back.
    func testTheHarnessFilePath_isRead() async {
        let r = await run(ToolNames.readFile, #"{"file_path":"a.txt"}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("alpha"), r.outputJSON)
        XCTAssertTrue(metaWarnings(in: r.outputJSON).contains { $0.contains("`file_path` as `path`") }, r.outputJSON)
    }

    /// A basename glob with a folder in it matched nothing under `ok:true`.
    func testAFolderInFileGlob_isRefused_withWhereEachHalfGoes() async {
        let r = await run(ToolNames.search, #"{"query":"alpha","file_glob":"src/*.txt"}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("send the folder in `paths`"), r.outputJSON)
    }

    /// A type fault in an argument sent under another name: the refusal names the tool's own
    /// argument AND says the model's spelling was read as it — never a key the model did not write.
    func testATypeFaultUnderAnAlias_saysWhichSpellingWasReadAsWhat() async {
        let r = await run(ToolNames.gitLog, #"{"limit":"all"}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("`max` must be an integer"), r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("`limit` as `max`"), r.outputJSON)
    }

    /// `search {"query": 404}` was dropped and refused as "an empty query" — the incident's own
    /// false diagnosis, by a different route. It is a search for "404" now.
    func testANumberSentAsTheQuery_isSearchedFor() async throws {
        try "status 404 here\n".write(to: workDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let r = await run(ToolNames.search, #"{"query":404}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("c.txt"), r.outputJSON)
        XCTAssertTrue(metaWarnings(in: r.outputJSON).contains("`query` was read as text."), r.outputJSON)
    }

    /// grep's `pattern` is a regular expression; renamed, it is searched as one.
    func testGrepsPattern_isSearchedAsARegularExpression() async {
        let r = await run(ToolNames.search, #"{"pattern":"alph.|gamm."}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("a.txt") && r.outputJSON.contains("b.txt"), r.outputJSON)
    }

    /// `form` wins over a stray top-level `questions` (a decision of 2026-09-12) — and says so.
    func testAQuestionnaireSentTwice_asksTheForm_andSaysTheStrayCopyWasNot() async {
        let r = await run(
            ToolNames.askSupervisorForm,
            #"{"headline":"h","form":{"questions":[{"prompt":"A?","kind":"free_text"}]},"questions":[{"prompt":"B?","kind":"free_text"}]}"#)
        XCTAssertFalse(r.isError, r.outputJSON)
        XCTAssertTrue(metaWarnings(in: r.outputJSON).contains(SupervisorFormPayload.strayQuestionsNote), r.outputJSON)
    }

    /// `list_files`' `name_glob` is a basename glob too — a folder in it matched nothing.
    func testAFolderInNameGlob_isRefused_withWhereEachHalfGoes() async {
        let r = await run(ToolNames.listFiles, #"{"name_glob":"src/*.txt"}"#)
        XCTAssertEqual(code(r), ToolErrorCode.invalidArgs.rawValue, r.outputJSON)
        XCTAssertTrue(r.outputJSON.contains("send the folder in `path`"), r.outputJSON)
    }

    private func writeTwoFilesWithTheSameLine() throws {
        let line = "check('5 / 0 = clear', '0');\n"
        try line.write(to: workDir.appendingPathComponent("engine.test.js"), atomically: true, encoding: .utf8)
        try line.write(to: workDir.appendingPathComponent("other.js"), atomically: true, encoding: .utf8)
    }
}
