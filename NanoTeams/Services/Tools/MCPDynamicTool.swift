import Foundation

/// One external tool, as the tool runtime sees it: arguments in, envelope out.
///
/// **Deliberately not a `ToolHandler`.** That protocol's conformers are listed in
/// `ToolHandlerRegistry.allTypes`, which feeds fifteen sets — the schema catalogue, the
/// meeting exclusions, the default-storage blocks, the "51 tools" pin, the word budget, the
/// category grants. An MCP tool belongs in none of them: it has no static name (the name is a
/// server's, folded), no static schema (the schema is a projection of what a server published
/// a moment ago), and no fixed availability (a server can be off). Joining that protocol would
/// mean teaching all fifteen sets about a family whose membership changes while the app runs.
/// So this is a plain value, registered with its schema through
/// `ToolRegistry.register(name:schema:handler:)`, and the ONE thing it shares with a real
/// handler is the contract that matters: a non-throwing body wrapped in
/// `ToolErrorHandler.execute`, so every failure leaves as an envelope.
nonisolated struct MCPDynamicTool: Sendable {

    let entry: MCPToolsSnapshot.Entry
    let invoker: any MCPToolInvoking
    /// Where binary blocks of this SERVER's results are written. `nil` when the run has no
    /// work folder — the mapper then reports an unsaved block instead of losing it.
    let attachmentsDirectory: URL?
    /// What returned paths are relative to.
    let workFolderRoot: URL
    /// Names the files of one call. Injected so a test can assert a path; production passes
    /// the default, and a fresh id per CALL is what keeps two calls of the same tool in one
    /// step from overwriting each other's screenshots.
    let makeCallID: @Sendable () -> String

    init(
        entry: MCPToolsSnapshot.Entry,
        invoker: any MCPToolInvoking,
        attachmentsDirectory: URL?,
        workFolderRoot: URL,
        makeCallID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.entry = entry
        self.invoker = invoker
        self.attachmentsDirectory = attachmentsDirectory
        self.workFolderRoot = workFolderRoot
        self.makeCallID = makeCallID
    }

    var name: String { entry.modelFacingName }

    /// The schema the model is shown and the runtime type-checks against — the projection,
    /// never the server's raw JSON Schema.
    var schema: ToolSchema { Self.registeredSchema(of: entry) }

    /// The schema a step registers `entry` under (`Tools.swift`, `register(name:schema:handler:)`)
    /// — the one the runtime's argument type gate reads back (`ToolRuntime.executeOne` →
    /// `ToolRegistry.schema(for:)`). Spelled once, so the preflight checks a call against the
    /// schema the runtime will check it against, never a copy of it.
    nonisolated static func registeredSchema(of entry: MCPToolsSnapshot.Entry) -> ToolSchema {
        ToolSchema(
            name: entry.modelFacingName,
            description: entry.descriptor.displayDescription,
            parameters: entry.descriptor.inputSchema)
    }

    /// Whether the arguments a handler received can go to a server. Not when the document was
    /// not a JSON object: the runtime hands such text to a handler under its own recovery key
    /// (`ToolRuntime.rawInputKey`), which a built-in handler reads and no server declared.
    nonisolated static func sends(_ args: [String: Any]) -> Bool { args[ToolRuntime.rawInputKey] == nil }

    /// Exactly what one call puts on the wire: the `arguments` object of `tools/call`, and the
    /// `Mcp-Param-*` headers the server's schema asked its values to be mirrored into — in the
    /// modern era only; the legacy era has no header channel, and there a header parameter is
    /// an ordinary body argument (`MCPArgumentCoercion.coerce`, which decides the split from the
    /// era of the session the call goes to). Both leave the machine — a header is readable by
    /// every intermediary on the way — so the approval card shows both.
    nonisolated struct OutgoingCall: Hashable, Sendable {
        /// Always an object — the empty object for a call that sends no argument.
        let arguments: JSONValue
        /// Header name → value, each value as the server decodes it (the transport may spell it
        /// in the specification's Base64 sentinel — `StreamableHTTPTransport.headerValue(_:)`).
        let headerParameters: [String: String]

        init(arguments: JSONValue, headerParameters: [String: String]) {
            self.arguments = arguments
            self.headerParameters = headerParameters
        }

        /// The call `handle` assembles from a coercion — the one conversion, read by `handle`
        /// for the wire and by the preflight for the card.
        init(_ coerced: MCPArgumentCoercion.Coerced) {
            self.init(arguments: coerced.arguments, headerParameters: coerced.headerParameters)
        }

        /// Nothing the model wrote leaves the machine: no argument in the body, no header.
        var sendsNothing: Bool { arguments == .object([:]) && headerParameters.isEmpty }
    }

    /// What a call of `entry` with this arguments document would do before anything is sent.
    nonisolated enum Preflight: Hashable, Sendable {
        /// It is sent, as exactly this.
        case sends(OutgoingCall)
        /// Something between the model and the wire refuses it — the runtime's reading of the
        /// document, the runtime's argument type gate, `sends(_:)` or the coercion — and nothing
        /// is sent. The model reads that refusal, from the runtime or from `handle`.
        case refused
    }

    /// The call as the send path would assemble it, computed by the SAME functions in the
    /// runtime's order, from the document, the name the runtime dispatched it under, and the
    /// entry the step registered (the frozen one — `registeredSchema(of:)` is what the runtime
    /// checks against, and its era the one the call is assembled for): the runtime's reading of
    /// the document (`ToolRuntime.dispatchedArguments` — the envelope unwrapped, empty keys
    /// dropped, keys trimmed), the runtime's argument type gate (`argumentTypeViolations`, which
    /// `ToolRuntime.executeOne` runs before it calls the handler), then `handle`'s own two steps:
    /// `sends(_:)` and the coercion it sends (`MCPArgumentCoercion.coerce`). Pure, and never a
    /// copy of those rules.
    ///
    /// The approval gate reads it FIRST (`LLMExecutionService.resolveMCPAsk`): a call it refuses
    /// is passed on to that refusal — with no card, and whether or not anyone is there to
    /// approve — so no card is held for a call these steps refuse before sending, and the model
    /// is told what is wrong with its arguments rather than that nobody can approve them. A card
    /// shows the outgoing call it computed, so the arguments box shows what the server will
    /// receive. ADVISORY about the card: what is sent is still decided at send time, by the
    /// runtime and by `handle`, which refuse by the same functions; and a call assembled for an
    /// era its server's session no longer speaks is refused at dispatch (`MCPToolCall.era`).
    nonisolated static func preflight(
        argumentsJSON: String, toolName: String, entry: MCPToolsSnapshot.Entry
    ) -> Preflight {
        guard let args = try? ToolRuntime.dispatchedArguments(argumentsJSON, toolName: toolName),
              argumentTypeViolations(args: args, schema: registeredSchema(of: entry).parameters).isEmpty,
              sends(args),
              let coerced = try? MCPArgumentCoercion.coerce(args: args, descriptor: entry.descriptor, era: entry.era)
        else { return .refused }
        return .sends(OutgoingCall(coerced))
    }

    func handle(args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: name, args: args) {
            // A document that was not a JSON object reaches a handler under the runtime's own
            // recovery key. A built-in handler knows that key; a server never declared it, and
            // sending it would send what the approval card never showed — so nothing is sent,
            // with the refusal the runtime gives a document that parses to a list. Until
            // 2026-10-28 a server received `{"__raw_input__": "<the text>"}`.
            guard Self.sends(args) else { throw ToolRuntimeError.argumentsNotObject }
            let descriptor = entry.descriptor
            let coerced = try MCPArgumentCoercion.coerce(args: args, descriptor: descriptor, era: entry.era)
            let outgoing = OutgoingCall(coerced)
            let resolvedResourceURI = try descriptor.resourceTarget?.resolveURI(arguments: outgoing.arguments)
            let result: MCPCallToolResult
            do {
                result = try await invoker.callTool(MCPToolCall(
                    serverID: entry.serverID,
                    // The server's OWN name. The folded one exists for the model and for
                    // collision-free namespacing; sending it would name a tool the server may
                    // not have, or a different one whose name folds the same way.
                    toolName: descriptor.originalName,
                    // The text this step was set up with — what the model read and called.
                    expectedHash: descriptor.pinHash,
                    arguments: outgoing.arguments,
                    headerParameters: outgoing.headerParameters,
                    // The era the split was decided for — the frozen entry's, which the card
                    // was built against — or `nil` when the tool's call reads the same in both.
                    // A session that has negotiated another since refuses the call rather than
                    // send a shape nobody saw.
                    era: coerced.era,
                    resourceURI: resolvedResourceURI))
            } catch let refusal as MCPDispatchRefusal {
                return refused(refusal, args: args)
            }
            return MCPToolResultMapper.map(
                result: result,
                toolName: name,
                args: args,
                callID: makeCallID(),
                destination: attachmentsDirectory.map {
                    MCPToolResultMapper.Destination(directory: $0, workFolderRoot: workFolderRoot)
                },
                argumentWarnings: coerced.warnings)
        }
    }

    /// A call the invoker stopped before it was sent, answered with the refusal the executor
    /// gives the same fact when the iteration already knew it (`ToolUnavailabilityReason`).
    /// One fact, one text: whether the server moved before the iteration's drift check or
    /// after it — during the generation, a held card, the batch's earlier calls — is timing,
    /// not something the model can act on differently.
    private func refused(_ refusal: MCPDispatchRefusal, args: [String: Any]) -> ToolExecutionResult {
        LLMExecutionService.makeUnavailableToolResult(
            call: StepToolCall(name: name, argumentsJSON: encodeArgsToJSON(args)),
            canonicalName: name,
            scope: "for this role",
            reason: LLMExecutionService.ToolUnavailabilityReason(refusal))
    }
}
