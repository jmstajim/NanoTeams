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
}
