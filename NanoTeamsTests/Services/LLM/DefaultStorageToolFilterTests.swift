import XCTest

@testable import NanoTeams

/// Tests for default storage tool filtering — verifies that file read + vision tools
/// are available while write/git/xcode tools are blocked and hidden from LLM schemas.
@MainActor
final class DefaultStorageToolFilterTests: XCTestCase {

    // MARK: - filterForDefaultStorage

    func testFilterForDefaultStorage_removesBlockedTools() {
        let tools = [
            ToolSchema(name: "read_file", description: "Read", parameters: .object(properties: [:])),
            ToolSchema(name: "list_files", description: "List", parameters: .object(properties: [:])),
            ToolSchema(name: "write_file", description: "Write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_status", description: "Git", parameters: .object(properties: [:])),
            ToolSchema(name: "run_xcodebuild", description: "Build", parameters: .object(properties: [:])),
            ToolSchema(name: "ask_supervisor", description: "Ask", parameters: .object(properties: [:])),
        ]

        let filtered = LLMExecutionService.filterForDefaultStorage(tools, isDefaultStorage: true)
        let names = Set(filtered.map(\.name))

        XCTAssertTrue(names.contains("read_file"), "File read tools should pass through")
        XCTAssertTrue(names.contains("list_files"), "File read tools should pass through")
        XCTAssertTrue(names.contains("ask_supervisor"), "Collaboration tools should pass through")
        XCTAssertFalse(names.contains("write_file"), "File write tools should be filtered")
        XCTAssertFalse(names.contains("git_status"), "Git tools should be filtered")
        XCTAssertFalse(names.contains("run_xcodebuild"), "Xcode tools should be filtered")
    }

    func testFilterForDefaultStorage_keepsAllWhenNotDefaultStorage() {
        let tools = [
            ToolSchema(name: "write_file", description: "Write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_status", description: "Git", parameters: .object(properties: [:])),
        ]

        let filtered = LLMExecutionService.filterForDefaultStorage(tools, isDefaultStorage: false)

        XCTAssertEqual(filtered.count, 2, "All tools should pass when not default storage")
    }

    func testFilterForDefaultStorage_allowsVisionTool() {
        let tools = [
            ToolSchema(name: "analyze_image", description: "Vision", parameters: .object(properties: [:])),
        ]

        let filtered = LLMExecutionService.filterForDefaultStorage(tools, isDefaultStorage: true)

        XCTAssertEqual(filtered.count, 1, "Vision tool should pass through in default storage")
    }

    // MARK: - defaultStorageBlockedTools consistency

    func testDefaultStorageBlockedTools_doesNotContainReadTools() {
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        let readTools = ToolHandlerRegistry.fileReadTools

        for tool in readTools {
            XCTAssertFalse(blocked.contains(tool), "\(tool) is a read tool and should not be blocked")
        }
    }

    func testDefaultStorageBlockedTools_doesNotContainVisionTools() {
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        let visionTools = ToolHandlerRegistry.visionTools

        for tool in visionTools {
            XCTAssertFalse(blocked.contains(tool), "\(tool) is a vision tool and should not be blocked")
        }
    }

    func testDefaultStorageBlockedTools_containsAllWriteGitXcodeTools() {
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        let expected = ToolHandlerRegistry.fileWriteTools
            .union(ToolHandlerRegistry.gitReadTools)
            .union(ToolHandlerRegistry.gitWriteTools)
            .union(ToolHandlerRegistry.xcodeTools)

        XCTAssertEqual(blocked, expected, "Blocked set should exactly match write + git + xcode tools")
    }

    // MARK: - Registry behavior in default storage

    func testDefaultStorageRegistry_fileReadToolsWork() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: tempDir.appendingPathComponent("tool_calls.jsonl"),
            isDefaultStorage: true
        )

        let context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )

        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError, "list_files should work in default storage mode")
    }

    func testDefaultStorageRegistry_writeToolsBlocked() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: tempDir.appendingPathComponent("tool_calls.jsonl"),
            isDefaultStorage: true
        )

        let context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )

        let call = StepToolCall(name: "write_file", argumentsJSON: "{\"path\": \"test.txt\", \"content\": \"hello\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, "write_file should be blocked in default storage mode")
        XCTAssertTrue(results[0].outputJSON.contains("No work folder"), "Error should mention no work folder")
    }
}
