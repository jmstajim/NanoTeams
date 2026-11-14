import XCTest

@testable import NanoTeams

/// A registry that carries schemas for tools `ToolHandlerRegistry` has never heard of.
///
/// The reason it exists is the argument type gate: `ToolRuntime` refuses a wrong-typed value
/// before it leaves the machine, and it can only do that for a tool whose schema it can find.
/// Before this, "find" meant the static table, so every MCP call skipped the gate entirely.
final class ToolRegistryDynamicSchemaTests: XCTestCase {

    private var registry: ToolRegistry!

    override func setUp() {
        super.setUp()
        registry = ToolRegistry()
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    private func schema(_ name: String) -> ToolSchema {
        ToolSchema(
            name: name, description: "External.",
            parameters: JSONSchema.object(properties: ["limit": JSONSchema.integer()]))
    }

    private func register(_ name: String) {
        registry.register(name: name, schema: schema(name)) { _, args in
            makeSuccessResult(toolName: name, args: args, data: ["ok": true])
        }
    }

    func testAStaticToolKeepsItsOwnSchema() {
        XCTAssertEqual(registry.schema(for: ToolNames.readFile)?.name, ToolNames.readFile)
    }

    func testADynamicToolIsFoundByName() {
        register("mcp__folio__get_metadata")
        XCTAssertEqual(registry.schema(for: "mcp__folio__get_metadata")?.description, "External.")
    }

    func testAnUnregisteredNameHasNoSchema() {
        XCTAssertNil(registry.schema(for: "mcp__folio__never_registered"))
    }

    /// The runtime lowercases every name before it dispatches, so the lookup has to answer
    /// the same spelling the handler table does.
    func testTheLookupIsCaseInsensitiveLikeTheHandlerTable() {
        register("mcp__folio__get_metadata")
        XCTAssertNotNil(registry.schema(for: "MCP__FOLIO__GET_METADATA"))
        XCTAssertNotNil(registry.handler(for: "MCP__FOLIO__GET_METADATA"))
    }

    func testRegisteringASchemaAlsoRegistersItsHandler() {
        register("mcp__folio__get_metadata")
        XCTAssertNotNil(registry.handler(for: "mcp__folio__get_metadata"))
    }

    /// The handler-only overload is what every built-in tool uses; its schema lives on the
    /// type, so registering one here must not shadow the static table with nothing.
    func testTheHandlerOnlyOverloadAddsNoSchema() {
        registry.register(name: "solo") { _, args in
            makeSuccessResult(toolName: "solo", args: args, data: ["ok": true])
        }
        XCTAssertNil(registry.schema(for: "solo"))
        XCTAssertNotNil(registry.handler(for: "solo"))
    }

    /// Per REGISTRY, not process-wide: a registry is built per step, and the catalogue a step
    /// was resolved against is frozen for its whole life. A shared table would let one step
    /// type-check a call against another step's catalogue.
    func testSchemasDoNotLeakBetweenRegistries() {
        register("mcp__folio__get_metadata")
        XCTAssertNil(ToolRegistry().schema(for: "mcp__folio__get_metadata"))
    }

    func testTheDynamicListIsSortedAndHoldsOnlyWhatWasRegisteredWithASchema() {
        register("mcp__trade_room__get_orders")
        register("mcp__folio__get_metadata")
        registry.register(name: "solo") { _, args in
            makeSuccessResult(toolName: "solo", args: args, data: ["ok": true])
        }
        XCTAssertEqual(
            registry.dynamicToolSchemas.map(\.name),
            ["mcp__folio__get_metadata", "mcp__trade_room__get_orders"])
    }

    // MARK: - Through `defaultRegistry`

    private func entry(tool: String, runsUnattended: Bool) throws -> MCPToolsSnapshot.Entry {
        try MCPToolsSnapshotTests.makeEntry(
            slug: "folio", tool: tool, serverID: UUID(), runsUnattended: runsUnattended)
    }

    private final class SilentInvoker: MCPToolInvoking, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [MCPToolCall] = []
        var received: [MCPToolCall] { lock.withLock { calls } }

        func callTool(_ call: MCPToolCall) async throws -> MCPCallToolResult {
            lock.withLock { calls.append(call) }
            return MCPCallToolResult(contentBlocks: [])
        }
    }

    /// The half that ships is the half that gets a handler. Registering a withheld tool
    /// would give the model a working handler for a name its prompt never showed it — the
    /// gate running in one of the two places it has to run.
    func testDefaultRegistryRegistersOnlyTheShippedHalf() throws {
        let resolved = MCPToolsSnapshot(
            entries: [
                try entry(tool: "get_metadata", runsUnattended: true),
                try entry(tool: "get_screenshot", runsUnattended: false),
            ],
            invoker: SilentInvoker()
        ).resolved(humanPresent: false)

        let (built, _) = ToolRegistry.defaultRegistry(
            workFolderRoot: FileManager.default.temporaryDirectory,
            toolCallsLogURL: nil,
            mcpTools: resolved)

        XCTAssertNotNil(built.handler(for: "mcp__folio__get_metadata"))
        XCTAssertNil(built.handler(for: "mcp__folio__get_screenshot"))
        XCTAssertEqual(built.dynamicToolSchemas.map(\.name), ["mcp__folio__get_metadata"])
    }

    /// A catalogue with no invoker cannot run anything, and registering handlers that would
    /// all fail is worse than registering none.
    func testACatalogueWithNoInvokerRegistersNothing() throws {
        let resolved = MCPToolsSnapshot(entries: [try entry(tool: "get_metadata", runsUnattended: true)])
            .resolved(humanPresent: true)
        let (built, _) = ToolRegistry.defaultRegistry(
            workFolderRoot: FileManager.default.temporaryDirectory,
            toolCallsLogURL: nil,
            mcpTools: resolved)
        XCTAssertTrue(built.dynamicToolSchemas.isEmpty)
    }

    /// `.empty` is what every caller written before MCP passes, and it must build exactly
    /// the registry it always built.
    func testAnEmptyCatalogueAddsNothing() {
        let (built, _) = ToolRegistry.defaultRegistry(
            workFolderRoot: FileManager.default.temporaryDirectory, toolCallsLogURL: nil)
        XCTAssertTrue(built.dynamicToolSchemas.isEmpty)
    }

    /// Registering is half of it: the closure `defaultRegistry` installs has to reach the
    /// tool's own `handle`, or the schema advertises a name the runtime answers with nothing.
    func testTheRegisteredHandlerReachesTheDynamicTool() async throws {
        let entry = try entry(tool: "get_metadata", runsUnattended: true)
        let invoker = SilentInvoker()
        let resolved = MCPToolsSnapshot(entries: [entry], invoker: invoker)
            .resolved(humanPresent: true)
        let root = FileManager.default.temporaryDirectory
        let (built, _) = ToolRegistry.defaultRegistry(
            workFolderRoot: root, toolCallsLogURL: nil, mcpTools: resolved)
        let handler = try XCTUnwrap(built.handler(for: entry.modelFacingName))
        let result = try await handler(
            ToolExecutionContext(workFolderRoot: root, taskID: 1, runID: 0, roleID: "r"), [:])
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(invoker.received.first?.toolName, "get_metadata")
    }

}
