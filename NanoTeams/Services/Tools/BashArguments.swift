import Foundation

/// Single source of truth for resolving `bash` tool arguments from a decoded
/// args dictionary OR the raw arguments JSON.
///
/// SECURITY-CRITICAL: the permission gate (`gateBashCalls`) and the handler
/// (`BashTool.handle`) MUST resolve the command identically. If they diverge, a
/// command supplied under a key the gate doesn't recognize — or a benign decoy in
/// `command` with the real command in `content` — would be *judged* on one string
/// but *executed* as another, bypassing the entire permission layer. Both sides
/// call `command(...)` here so they can never drift.
nonisolated enum BashArguments {

    /// Resolves the shell command EXACTLY as `BashTool` executes it, from the arguments as the
    /// runtime dispatches them: the declared `command` — its other spellings arrive renamed to
    /// it (`BashTool.undeclaredArguments`), and two spellings refuse the call before it gets
    /// here — or the prose a document that was not JSON carried (`__raw_input__`, through
    /// `requiredString`'s recovery). Returns `nil` when no non-empty command is present.
    ///
    /// Until 2026-11-09 a resilient resolver ran FIRST — eleven body names, then any single
    /// remaining string — so `{"command":"ls","content":"…"}` ran the `content`.
    static func command(from args: [String: Any]) -> String? {
        guard let command = try? requiredString(args, "command"),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return command
    }

    /// The command the HANDLER would run for this document, for the gate (which holds the
    /// call's text, not the handler's dictionary). Read through the runtime's own reading
    /// (`ToolCallArguments.prepare`) — never a separate parse: the gate's bare
    /// `JSONSerialization` read nothing from prose, a raw control character or a reentrant
    /// envelope that the runtime then ran, and judged one of two keys that trim to `command`
    /// while the runtime ran the other (2026-11-09). `nil` when nothing would run: the
    /// runtime refuses the document, or the handler finds no command in it.
    static func command(fromJSON argumentsJSON: String) -> String? {
        dispatchedArguments(argumentsJSON).flatMap(command(from:))
    }

    static func workingDirectory(from args: [String: Any]) -> String? {
        optionalString(args, "working_directory").flatMap { $0.isEmpty ? nil : $0 }
    }

    static func workingDirectory(fromJSON argumentsJSON: String) -> String? {
        dispatchedArguments(argumentsJSON).flatMap(workingDirectory(from:))
    }

    /// Validated foreground timeout in SECONDS. Returns `nil` for a non-positive
    /// requested value (caller surfaces `INVALID_ARGS` rather than silently
    /// masking a sign typo). A value above `maxTimeoutMilliseconds` is clamped;
    /// a sub-second value floors to 1s.
    static func resolveTimeoutSeconds(milliseconds: Int?) -> TimeInterval? {
        let ms = milliseconds ?? BashConstants.defaultTimeoutMilliseconds
        guard ms > 0 else { return nil }
        let clamped = min(ms, BashConstants.maxTimeoutMilliseconds)
        return max(Double(clamped) / 1000.0, 1)
    }

    private static func dispatchedArguments(_ json: String) -> [String: Any]? {
        ToolCallArguments.prepare(rawJSON: json, emittedName: ToolNames.bash).dispatched?.args
    }
}
