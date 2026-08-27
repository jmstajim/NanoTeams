import XCTest

@testable import NanoTeams

/// Capture slots for probe handlers.
///
/// `ToolRegistry.ToolHandler` is `@Sendable` — the registry hands one closure to whichever
/// task runs the batch — so a probe can no longer scribble on a captured `var`. These are the
/// same shape as `ToolExecutionTests.ThreadCaptureBox`, kept local because a probe slot is not
/// a fixture: sharing one would couple two suites' capture types for no reuse.
private final class ProbeBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class ToolRegistryTests: XCTestCase {
    private var registry: ToolRegistry!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = ToolRegistry()
        context = ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
//        registry = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - Registration Tests

    func testRegister_storesHandler() {
        registry.register(name: "test_tool") { _, _ in
            ToolExecutionResult(
                toolName: "test_tool",
                argumentsJSON: "{}",
                outputJSON: "{\"ok\":true}",
                isError: false
            )
        }

        XCTAssertNotNil(registry.handler(for: "test_tool"))
    }

    func testRegister_multipleTools() {
        registry.register(name: "tool_a") { _, _ in
            ToolExecutionResult(toolName: "tool_a", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }
        registry.register(name: "tool_b") { _, _ in
            ToolExecutionResult(toolName: "tool_b", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }
        registry.register(name: "tool_c") { _, _ in
            ToolExecutionResult(toolName: "tool_c", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        XCTAssertNotNil(registry.handler(for: "tool_a"))
        XCTAssertNotNil(registry.handler(for: "tool_b"))
        XCTAssertNotNil(registry.handler(for: "tool_c"))
    }

    func testRegister_overwritesExisting() async {
        let callCount = ProbeBox(0)

        registry.register(name: "my_tool") { _, _ in
            callCount.value = 1
            return ToolExecutionResult(toolName: "my_tool", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        // Overwrite with new handler
        registry.register(name: "my_tool") { _, _ in
            callCount.value = 2
            return ToolExecutionResult(toolName: "my_tool", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        // Execute the handler
        _ = try? await registry.handler(for: "my_tool")?(context, [:])

        XCTAssertEqual(callCount.value, 2, "Should use the overwritten handler")
    }

    // MARK: - Handler Lookup Tests

    func testHandler_caseInsensitiveLookup() {
        registry.register(name: "Read_File") { _, _ in
            ToolExecutionResult(toolName: "read_file", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        XCTAssertNotNil(registry.handler(for: "read_file"))
        XCTAssertNotNil(registry.handler(for: "READ_FILE"))
        XCTAssertNotNil(registry.handler(for: "Read_File"))
        XCTAssertNotNil(registry.handler(for: "rEaD_fIlE"))
    }

    func testHandler_returnsNilForUnregistered() {
        XCTAssertNil(registry.handler(for: "nonexistent_tool"))
    }

    func testHandler_returnsNilForEmptyName() {
        XCTAssertNil(registry.handler(for: ""))
    }

    // MARK: - Registered Tool Names Tests

    func testRegisteredToolNames_initiallyEmpty() {
        XCTAssertTrue(registry.registeredToolNames.isEmpty)
    }

    func testRegisteredToolNames_containsRegisteredTools() {
        registry.register(name: "alpha") { _, _ in
            ToolExecutionResult(toolName: "alpha", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }
        registry.register(name: "beta") { _, _ in
            ToolExecutionResult(toolName: "beta", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        let names = registry.registeredToolNames
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("alpha"))
        XCTAssertTrue(names.contains("beta"))
    }

    func testRegisteredToolNames_storesLowercased() {
        registry.register(name: "MyTool") { _, _ in
            ToolExecutionResult(toolName: "mytool", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }

        let names = registry.registeredToolNames
        XCTAssertTrue(names.contains("mytool"))
        XCTAssertFalse(names.contains("MyTool"))
    }

    // MARK: - Handler Execution Tests

    func testHandler_executesWithCorrectArguments() async throws {
        let receivedArgs = ProbeBox<[String: Any]?>(nil)

        registry.register(name: "capture_tool") { _, args in
            receivedArgs.value = args
            return ToolExecutionResult(
                toolName: "capture_tool",
                argumentsJSON: "{}",
                outputJSON: "{}",
                isError: false
            )
        }

        let args: [String: Any] = ["path": "/test/file.txt", "maxBytes": 1000]
        _ = try await registry.handler(for: "capture_tool")?(context, args)

        XCTAssertNotNil(receivedArgs.value)
        XCTAssertEqual(receivedArgs.value?["path"] as? String, "/test/file.txt")
        XCTAssertEqual(receivedArgs.value?["maxBytes"] as? Int, 1000)
    }

    func testHandler_executesWithCorrectContext() async throws {
        let receivedContext = ProbeBox<ToolExecutionContext?>(nil)

        registry.register(name: "context_tool") { ctx, _ in
            receivedContext.value = ctx
            return ToolExecutionResult(
                toolName: "context_tool",
                argumentsJSON: "{}",
                outputJSON: "{}",
                isError: false
            )
        }

        let taskID = 0
        let runID = 0
        let roleID = "test_role"
        let workFolderRoot = URL(fileURLWithPath: "/my/project")

        let customContext = ToolExecutionContext(
            workFolderRoot: workFolderRoot,
            taskID: taskID,
            runID: runID,
            roleID: roleID
        )

        _ = try await registry.handler(for: "context_tool")?(customContext, [:])

        XCTAssertNotNil(receivedContext.value)
        XCTAssertEqual(receivedContext.value?.workFolderRoot, workFolderRoot)
        XCTAssertEqual(receivedContext.value?.taskID, taskID)
        XCTAssertEqual(receivedContext.value?.runID, runID)
        XCTAssertEqual(receivedContext.value?.roleID, roleID)
    }

    func testHandler_returnsResult() async throws {
        registry.register(name: "result_tool") { _, _ in
            ToolExecutionResult(
                toolName: "result_tool",
                argumentsJSON: "{\"key\":\"value\"}",
                outputJSON: "{\"ok\":true,\"data\":{\"message\":\"success\"}}",
                isError: false
            )
        }

        let result = try await registry.handler(for: "result_tool")?(context, [:])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.toolName, "result_tool")
        XCTAssertFalse(result?.isError ?? true)
        XCTAssertTrue(result?.outputJSON.contains("success") ?? false)
    }

    func testHandler_canThrowError() async {
        registry.register(name: "throwing_tool") { _, _ in
            throw ToolArgumentError.missingRequired("required_arg")
        }

        // `XCTAssertThrowsError` takes an autoclosure, which is not an async context.
        do {
            _ = try await registry.handler(for: "throwing_tool")?(context, [:])
            XCTFail("handler must rethrow")
        } catch let error as ToolArgumentError {
            XCTAssertTrue(
                error.localizedDescription.contains("required_arg"),
                "got: \(error.localizedDescription)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Alias Tests

    func testResolveAlias_creatArtifact() {
        // "creat_artifact" is a common LLM typo for "create_artifact"
        let resolved = ToolRegistry.defaultAliases["creat_artifact"]
        XCTAssertEqual(resolved, ToolNames.createArtifact)
    }

    func testResolveAlias_submitArtifact() {
        let resolved = ToolRegistry.defaultAliases["submit_artifact"]
        XCTAssertEqual(resolved, ToolNames.createArtifact)
    }

    func testResolveAlias_saveArtifact() {
        let resolved = ToolRegistry.defaultAliases["save_artifact"]
        XCTAssertEqual(resolved, ToolNames.createArtifact)
    }

    func testResolveAlias_registeredAliasResolvesHandler() {
        registry.register(name: "create_artifact") { _, _ in
            ToolExecutionResult(toolName: "create_artifact", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }
        registry.registerAlias("creat_artifact", for: "create_artifact")

        XCTAssertEqual(registry.canonicalName(for: "creat_artifact"), "create_artifact")
        XCTAssertNotNil(registry.handler(for: registry.canonicalName(for: "creat_artifact")))
    }

    // MARK: - resolveToolName (prefix + alias canonicalization)

    /// Regression — Run 9 (2026-04-18). `openai/gpt-oss-20b` emitted
    /// `repo_browser.list_files` / `.search` / `.request_changes`. Previously the
    /// executor lowercased-and-aliased but never stripped the prefix, so every
    /// prefixed call came back as `tool_not_authorized`. Single canonicalization
    /// point now handles it uniformly across the main executor, runtime dispatch,
    /// and meeting-tool filtering.
    func testResolveToolName_stripsRepoBrowserPrefix() {
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.list_files"), "list_files")
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.search"), "search")
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.request_changes"), "request_changes")
    }

    func testResolveToolName_stripsFunctionsPrefix() {
        // Harmony protocol (gpt-oss, other OpenAI-aligned models) emits `functions.X`.
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.write_file"), "write_file")
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.create_artifact"), "create_artifact")
    }

    func testResolveToolName_caseInsensitivePrefix() {
        XCTAssertEqual(ToolRegistry.resolveToolName("Repo_Browser.search"), "search")
        XCTAssertEqual(ToolRegistry.resolveToolName("FUNCTIONS.read_file"), "read_file")
    }

    func testResolveToolName_stripsWhitespaceBeforePrefixCheck() {
        XCTAssertEqual(ToolRegistry.resolveToolName("  repo_browser.search  "), "search")
    }

    func testResolveToolName_stripsPrefixThenAppliesAlias() {
        // After stripping `repo_browser.`, `grep` aliases to `search`.
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser.grep"), ToolNames.search)
        // After stripping `functions.`, `touch` aliases to `write_file`.
        XCTAssertEqual(ToolRegistry.resolveToolName("functions.touch"), ToolNames.writeFile)
    }

    func testResolveToolName_bareNameAppliesAliasOnly() {
        XCTAssertEqual(ToolRegistry.resolveToolName("grep"), ToolNames.search)
        XCTAssertEqual(ToolRegistry.resolveToolName("ls"), ToolNames.listFiles)
    }

    func testResolveToolName_canonicalNameUnchanged() {
        // Already-canonical names must pass through untouched (no accidental rewrite).
        XCTAssertEqual(ToolRegistry.resolveToolName("write_file"), "write_file")
        XCTAssertEqual(ToolRegistry.resolveToolName("create_artifact"), "create_artifact")
        XCTAssertEqual(ToolRegistry.resolveToolName("ask_supervisor"), "ask_supervisor")
    }

    func testResolveToolName_unknownNameReturnedTrimmed() {
        // No prefix, no alias — preserves the name (lets the runtime report tool_not_found).
        XCTAssertEqual(ToolRegistry.resolveToolName("  totally_made_up  "), "totally_made_up")
    }

    /// `_repo_browser.search` is NOT prefixed — the `repo_browser.` segment
    /// is a substring, not a prefix. Stripping here would be a bug: the model
    /// might be legitimately emitting an unknown tool and deserves a
    /// tool_not_found signal with the raw name intact.
    func testResolveToolName_substringNotPrefix_isPreserved() {
        XCTAssertEqual(ToolRegistry.resolveToolName("my_repo_browser.search"), "my_repo_browser.search")
        XCTAssertEqual(ToolRegistry.resolveToolName("xrepo_browser.search"), "xrepo_browser.search")
        XCTAssertEqual(ToolRegistry.resolveToolName("xfunctions.write_file"), "xfunctions.write_file")
    }

    /// Empty suffix after the prefix (`repo_browser.`) must return the empty
    /// string (unchanged by aliases). The resulting `""` is an invalid handler
    /// name that `ToolRuntime` will reject as `tool_not_found` — never silently
    /// dispatched to something else.
    func testResolveToolName_emptyAfterPrefix_returnsEmpty() {
        XCTAssertEqual(ToolRegistry.resolveToolName("repo_browser."), "")
        XCTAssertEqual(ToolRegistry.resolveToolName("functions."), "")
    }

    func testResolveToolName_onlyFirstMatchingPrefixStripped() {
        // Safety: never strip more than one prefix. A name like
        // `repo_browser.functions.search` is a bug we want to surface, not silently
        // rewrite all the way down to `search`.
        XCTAssertEqual(
            ToolRegistry.resolveToolName("repo_browser.functions.search"),
            "functions.search"
        )
    }

    /// End-to-end through `handler(for:)`: register a handler under the canonical
    /// name, then look it up via a `repo_browser.` prefix. Proves the runtime
    /// dispatch path resolves the prefix.
    func testHandler_dispatchesAfterPrefixStrip() async {
        let callCount = ProbeBox(0)
        registry.register(name: "search") { _, _ in
            callCount.value += 1
            return ToolExecutionResult(toolName: "search", argumentsJSON: "{}", outputJSON: "{}", isError: false)
        }
        let resolved = ToolRegistry.resolveToolName("repo_browser.search")
        let handler = registry.handler(for: resolved)
        XCTAssertNotNil(handler, "Handler must be found after prefix strip")
        _ = try? await handler?(context, [:])
        XCTAssertEqual(callCount.value, 1)
    }
}

// MARK: - ToolExecutionContext Tests

final class ToolExecutionContextTests: XCTestCase {

    func testContext_hashable() {
        let context1 = ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )

        let context2 = context1

        XCTAssertEqual(context1, context2)
        XCTAssertEqual(context1.hashValue, context2.hashValue)
    }

    func testContext_differentContextsNotEqual() {
        let context1 = ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: 0,
            runID: 0,
            roleID: "test_role"
        )

        let context2 = ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: 1,
            runID: 0,
            roleID: "test_role"
        )

        XCTAssertNotEqual(context1, context2)
    }
}

// MARK: - ToolExecutionResult Tests

final class ToolExecutionResultTests: XCTestCase {

    func testResult_basicProperties() {
        let result = ToolExecutionResult(
            toolName: "test_tool",
            argumentsJSON: "{\"path\":\"/file\"}",
            outputJSON: "{\"ok\":true}",
            isError: false
        )

        XCTAssertEqual(result.toolName, "test_tool")
        XCTAssertEqual(result.argumentsJSON, "{\"path\":\"/file\"}")
        XCTAssertEqual(result.outputJSON, "{\"ok\":true}")
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.signal)
    }

    func testResult_withSupervisorQuestion() {
        let result = ToolExecutionResult(
            toolName: "ask_supervisor",
            argumentsJSON: "{}",
            outputJSON: "{}",
            isError: false,
            signal: .supervisorQuestion("What priority?")
        )

        XCTAssertEqual(result.signal, .supervisorQuestion("What priority?"))
    }

    func testResult_hashable() {
        let result1 = ToolExecutionResult(
            toolName: "tool",
            argumentsJSON: "{}",
            outputJSON: "{}",
            isError: false
        )

        let result2 = result1

        XCTAssertEqual(result1, result2)
        XCTAssertEqual(result1.hashValue, result2.hashValue)
    }
}
