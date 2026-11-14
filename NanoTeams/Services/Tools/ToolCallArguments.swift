import Foundation

/// The ONE reading of a tool call's arguments: from the document the model wrote to the
/// dictionary its handler receives, and the tool that receives it.
///
/// Everything that decides something about a call by its arguments reads THIS, never the raw
/// text — the runtime that dispatches it (`ToolRuntime.executeOne`), the approval gates that
/// judge it before it runs (`gateBashCalls`, `gateComputerUseCalls`), and the guards that
/// remember it (`ToolCallTracker`'s identical-write fingerprint and loop identity).
///
/// Until 2026-11-09 the bash gate parsed the raw text with a bare `JSONSerialization` while the
/// runtime normalised it, and four documents were judged as one command and run as another, or
/// run with no judgement at all because the gate skipped what it could not read: prose (the
/// runtime wraps it as `__raw_input__` and the handler runs it), a key with whitespace around
/// it (the runtime's trim overwrote the judged `command`), a reentrant `{name, arguments}`
/// envelope (the gate judged the outer `name`), and a raw control character inside a string
/// (the runtime sanitises what `JSONSerialization` refuses). A judgement is worth only the text
/// it was made on, so the gate and the runtime read the same function — pure, and with no step
/// that depends on a dictionary's iteration order.
///
/// The steps, in the runtime's order: the document (`ToolRuntime.dispatchedArguments`), the
/// supervisor-ask routing (`SupervisorAskRouting` — the arguments decide which of the two
/// asks runs), the tool's undeclared spellings (`ToolArgumentVocabulary` — an alias renamed,
/// an ignored key removed, anything else refused, so no key the model sent is dropped without
/// a word), and the argument type gate (`argumentTypeViolations`, over the RENAMED arguments,
/// so `path: "a.js"` sent to `search` is checked as the one-element `paths` it became).
/// `MCPDynamicTool.preflight` is the same reading for an MCP tool, whose schema the registry
/// holds per step and which no vocabulary describes.
nonisolated enum ToolCallArguments {

    /// A call that reaches its handler.
    struct Dispatch {
        /// The tool that runs: the emitted name resolved (`ToolRegistry.resolveToolName`)
        /// and, for the two supervisor-ask tools, corrected by the arguments.
        let toolName: String
        /// What the handler receives.
        let args: [String: Any]
        /// What the reading did to the call that the model should be told (REC.5): the
        /// arguments it renamed or ignored (`ToolArgumentVocabulary`) — appended to the
        /// result's `meta.warnings` by the runtime.
        let notes: [String]
    }

    enum Prepared {
        case dispatch(Dispatch)
        /// The document could not be read as arguments at all. The runtime answers with the
        /// error's own text under `execution_failed`.
        case unreadable(any Error)
        /// Read, then refused before any handler saw it: `INVALID_ARGS` naming the fault,
        /// reported against the tool that would have run.
        case invalid(toolName: String, args: [String: Any], message: String)

        /// The call as its handler would receive it, or `nil` when nothing would run.
        var dispatched: Dispatch? {
            if case .dispatch(let dispatch) = self { return dispatch }
            return nil
        }

        /// The tool and arguments the reading arrived at, whether or not the call runs — what a
        /// guard that REMEMBERS calls keys on: a refused call repeated with its keys reordered
        /// is still one call to the loop detector. `nil` only for a document with no arguments
        /// to read.
        var read: (toolName: String, args: [String: Any])? {
            switch self {
            case .dispatch(let dispatch): (dispatch.toolName, dispatch.args)
            case .invalid(let toolName, let args, _): (toolName, args)
            case .unreadable: nil
            }
        }
    }

    /// A call's arguments under its tool's own names, for a surface that READS a call by key
    /// without running it (the card summary): the reading's renames applied, or — for a call the
    /// vocabulary refuses — the arguments as the model wrote them. Idempotent: arguments already
    /// read come back unchanged, so a persisted call (stored as the handler received it) and a
    /// streaming one (stored as the model wrote it) summarize alike.
    static func displayArguments(_ args: [String: Any], toolName: String) -> [String: Any] {
        switch ToolArgumentVocabulary.apply(toolName: ToolRegistry.resolveToolName(toolName), args: args) {
        case .applied(let applied, _)?: applied
        case .refused?, nil: args
        }
    }

    /// Reads `rawJSON` as the runtime dispatches it.
    ///
    /// - Parameters:
    ///   - schema: the schema a tool's argument TYPES are checked against. The default is the
    ///     bundled one; the runtime passes its registry's lookup, which also knows the MCP tools
    ///     a step registered. For a built-in tool the two return the same schema.
    ///   - canRoute: whether a supervisor-ask correction may be adopted — the runtime adopts it
    ///     only when it holds a handler for the corrected tool.
    static func prepare(
        rawJSON: String,
        emittedName: String,
        schema: (String) -> ToolSchema? = { ToolHandlerRegistry.schema(named: $0) },
        canRoute: (String) -> Bool = { _ in true }
    ) -> Prepared {
        let resolved = ToolRegistry.resolveToolName(emittedName)
        let args: [String: Any]
        do {
            args = try ToolRuntime.dispatchedArguments(rawJSON, toolName: resolved)
        } catch {
            return .unreadable(error)
        }

        // The two supervisor-ask tools are told apart by their arguments when the name and the
        // payload disagree — re-resolved BEFORE the type check, or the payload would be checked
        // against the shape it was misnamed as.
        var toolName = resolved
        if let corrected = SupervisorAskRouting.correctedName(for: resolved, argumentKeys: Set(args.keys)),
           canRoute(corrected) {
            toolName = corrected
        }

        var dispatchedArgs = args
        var notes: [String] = []
        switch ToolArgumentVocabulary.apply(toolName: toolName, args: args) {
        case .applied(let applied, let appliedNotes)?:
            dispatchedArgs = applied
            notes = appliedNotes
        case .refused(let message)?:
            return .invalid(toolName: toolName, args: args, message: message)
        case nil:
            break  // not a built-in tool — an MCP server judges its own arguments
        }
        if let properties = ToolHandlerRegistry.schema(named: toolName)?.parameters.properties {
            switch ToolArgumentVocabulary.readingDeclaredText(args: dispatchedArgs, properties: properties) {
            case .applied(let read, let textNotes):
                dispatchedArgs = read
                notes += textNotes
            case .refused(let message):
                return .invalid(toolName: toolName, args: dispatchedArgs, message: message)
            }
        }

        // A provided argument the shared coercion cannot honour is answered as the argument
        // fault it is, instead of reaching the handler as "absent" and running the wrong branch
        // under a success envelope (`search {"paths": 5}` walked the whole tree, 2026-09-07;
        // playbook REC.5).
        if let parameters = schema(toolName)?.parameters {
            let violations = argumentTypeViolations(args: dispatchedArgs, schema: parameters)
            if !violations.isEmpty {
                // The violations name the tool's own argument; when the model sent it under
                // another name, the rename is said too — or the refusal names a key it never wrote.
                return .invalid(
                    toolName: toolName, args: dispatchedArgs,
                    message: ([violations.joined(separator: " ") + " Fix the value, or omit the argument."] + notes)
                        .joined(separator: " "))
            }
        }
        return .dispatch(Dispatch(toolName: toolName, args: dispatchedArgs, notes: notes))
    }
}
