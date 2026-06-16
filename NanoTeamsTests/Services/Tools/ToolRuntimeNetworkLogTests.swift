import XCTest

@testable import NanoTeams

/// Verifies that `ToolRuntime` mirrors every executed tool call into the shared
/// `network_log.json` as a `.toolCall` record (the user-facing goal: the wire
/// audit matches the activity feed). The runtime keeps writing `tool_calls.jsonl`
/// as before — these tests only assert the new network-log mirror.
final class ToolRuntimeNetworkLogTests: XCTestCase {
    private let fileManager = FileManager.default
    private var workFolderRoot: URL!
    private var networkLogURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workFolderRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        networkLogURL = workFolderRoot.appendingPathComponent("network_log.json")
    }

    override func tearDownWithError() throws {
        if let workFolderRoot { try? fileManager.removeItem(at: workFolderRoot) }
        workFolderRoot = nil
        networkLogURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeRuntime(networkLogger: NetworkLogger?) -> ToolRuntime {
        let toolCallsLogURL = workFolderRoot.appendingPathComponent("tool_calls.jsonl")
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot,
            toolCallsLogURL: toolCallsLogURL,
            networkLogger: networkLogger
        )
        return runtime
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: workFolderRoot, taskID: 0, runID: 0, roleID: "eng")
    }

    private func toolCallRecords() throws -> [NetworkLogRecord] {
        guard fileManager.fileExists(atPath: networkLogURL.path) else { return [] }
        let data = try Data(contentsOf: networkLogURL)
        let all = try JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
        return all.filter { $0.direction == .toolCall }
    }

    // MARK: - Tests

    func testExecutedCall_appendsToolCallNetworkRecord() throws {
        let runtime = makeRuntime(networkLogger: NetworkLogger(logURL: networkLogURL))
        let call = StepToolCall(name: "list_files", argumentsJSON: #"{"path":"."}"#)

        let result = runtime.executeAll(context: context(), toolCalls: [call]).first!
        XCTAssertFalse(result.isError, "list_files on the work folder root should succeed")

        let records = try toolCallRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].stepID, "eng")
        XCTAssertNil(records[0].errorMessage, "A clean success carries no errorMessage")
        XCTAssertTrue(records[0].body?.contains("list_files") == true)
    }

    func testToolNotFound_appendsRecordWithErrorMessage() throws {
        let runtime = makeRuntime(networkLogger: NetworkLogger(logURL: networkLogURL))
        let call = StepToolCall(name: "definitely_not_a_tool", argumentsJSON: "{}")

        let result = runtime.executeAll(context: context(), toolCalls: [call]).first!
        XCTAssertTrue(result.isError)

        let records = try toolCallRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[0].errorMessage)
        XCTAssertTrue(records[0].body?.contains("definitely_not_a_tool") == true)
    }

    func testNilNetworkLogger_writesNoNetworkLog() throws {
        let runtime = makeRuntime(networkLogger: nil)
        let call = StepToolCall(name: "list_files", argumentsJSON: #"{"path":"."}"#)

        _ = runtime.executeAll(context: context(), toolCalls: [call])

        XCTAssertFalse(
            fileManager.fileExists(atPath: networkLogURL.path),
            "With logging disabled (nil networkLogger) no network_log.json is written")
    }
}
