import Foundation

// MARK: - Response Envelope Types (Private)

nonisolated private struct SuccessEnvelope<D: Encodable>: Encodable {
    var ok: Bool
    var data: D
    var error: ToolError?
    var next: NextHint?
    var meta: ToolResultMeta
}

nonisolated private struct ErrorEnvelope: Encodable {
    var ok: Bool
    var data: String?
    var error: ToolError
    var next: NextHint?
    var meta: ToolResultMeta
}

// MARK: - Response Envelope Helpers

nonisolated func makeSuccessEnvelope<T: Encodable>(
    data: T,
    next: NextHint? = nil,
    meta: ToolResultMeta = ToolResultMeta()
) -> String {
    let envelope = SuccessEnvelope(
        ok: true,
        data: data,
        error: nil,
        next: next,
        meta: meta
    )

    return encodeToJSON(envelope)
}

nonisolated func makeErrorEnvelope(
    code: ToolErrorCode,
    message: String,
    details: [String: String]? = nil,
    next: NextHint? = nil,
    meta: ToolResultMeta = ToolResultMeta()
) -> String {
    let envelope = ErrorEnvelope(
        ok: false,
        data: nil,
        error: ToolError(code: code.rawValue, message: message, details: details),
        next: next,
        meta: meta
    )

    return encodeToJSON(envelope)
}

nonisolated func makeSuccessResult(
    toolName: String,
    args: [String: Any],
    data: some Encodable,
    next: NextHint? = nil,
    meta: ToolResultMeta = ToolResultMeta()
) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(data: data, next: next, meta: meta),
        isError: false
    )
}

nonisolated func makeErrorResult(
    toolName: String,
    args: [String: Any],
    code: ToolErrorCode,
    message: String,
    details: [String: String]? = nil,
    next: NextHint? = nil
) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeErrorEnvelope(code: code, message: message, details: details, next: next),
        isError: true
    )
}

// MARK: - Tool-not-authorized (config flavour)

/// Emits the executor-compatible `tool_not_authorized` envelope from a handler.
/// Use when a tool is wired into a role's schema but the runtime determines it
/// shouldn't be (e.g. `create_artifact` for a role with no declared deliverables).
///
/// Why this shape (not `makeErrorResult(code: .commandFailed, …)`):
/// `LLMExecutionService.buildToolErrorGuidance` switches on the top-level
/// `error` literal and routes `tool_not_authorized` into the bespoke "don't
/// retry" branch. The handler-shape envelope (`{"error":{"code":"COMMAND_FAILED",
/// …}}`) lands in the default branch, which appends "Retry the tool call with
/// the correct arguments" — a loop trap when args aren't the cause.
nonisolated func makeToolNotAuthorizedConfigResult(
    toolName: String,
    args: [String: Any],
    message: String
) -> ToolExecutionResult {
    let payload: [String: String] = [
        "error": "tool_not_authorized",
        "tool": toolName,
        "message": message,
    ]
    let outputJSON: String = {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":"tool_not_authorized","tool":"\#(toolName)","message":"\#(message)"}"#
        }
        return str
    }()
    return ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: outputJSON,
        isError: true
    )
}

// MARK: - Cancellation Result

/// Unified `cancelled` envelope. Two callers converge here so downstream
/// classifiers see one wire shape regardless of which layer cancelled:
/// - `ToolRuntime.executeAll` emits one per call in a pre/mid-cancelled batch.
/// - `ToolErrorHandler.execute` rethrows `ProcessRunnerError.cancelled` into
///   this envelope so a SIGTERMed `xcodebuild` looks identical to a Supervisor
///   pause arriving between two `list_files` calls.
nonisolated func makeCancelledResult(
    toolName: String,
    argumentsJSON: String,
    providerID: String? = nil
) -> ToolExecutionResult {
    ToolExecutionResult(
        providerID: providerID,
        toolName: toolName,
        argumentsJSON: argumentsJSON,
        outputJSON: makeErrorEnvelope(
            code: .cancelled,
            message: "Tool call cancelled by user (run paused or interrupted)."
        ),
        isError: true
    )
}

// MARK: - Supervisor Question Result

nonisolated func makeSupervisorQuestionResult(
    toolName: String,
    args: [String: Any],
    question: String
) -> ToolExecutionResult {
    return ToolExecutionResult(
        toolName: toolName,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(
            data: AskSupervisorData(question: question, status: "pending")
        ),
        isError: false,
        signal: .supervisorQuestion(question)
    )
}

// MARK: - Synthetic results (built without executing the tool)

nonisolated extension ToolExecutionResult {
    /// Builds a synthetic result for a tool call that was NOT executed, carrying
    /// the call's `providerID` so the wire `tool_call_id` resolves and the model
    /// never sees an orphaned tool call (which causes HTTP 400 / token growth).
    ///
    /// Single source of truth for the providerID-threading footgun: the bash
    /// gate (`gateBashCalls`) and any future pre-execution synthesizer must build
    /// results through here rather than re-deriving the `providerID ?? UUID()`
    /// fallback inline. Mirrors the construction already used by
    /// `makeUnavailableToolResult` / `makeIdenticalWriteLoopResult`.
    static func synthetic(
        for call: StepToolCall,
        outputJSON: String,
        isError: Bool,
        signal: ToolSignal? = nil
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: call.providerID ?? UUID().uuidString,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            outputJSON: outputJSON,
            isError: isError,
            signal: signal
        )
    }
}

// MARK: - JSON Helpers

nonisolated private func encodeToJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONCoderFactory.makeWireEncoder()
    guard let data = try? encoder.encode(value),
        let str = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return str
}

/// Renders a tool call's arguments for the envelope. Total by contract — every failure
/// answers `"{}"`.
///
/// The `isValidJSONObject` guard is what makes that contract true, and it is not
/// belt-and-braces: `data(withJSONObject:)` RAISES an ObjC `NSInvalidArgumentException` for a
/// value JSON cannot express (NaN/infinity, a non-string key, a `Date`), and `try?` catches
/// Swift errors, not ObjC exceptions — so without it this helper terminates the process
/// (measured against Foundation, 2026-08-08). It is called on every tool ERROR path, i.e.
/// precisely where the arguments are least trustworthy, and the surrounding `guard/else`
/// shape advertises a safety it did not have. `stableJSONString` already guards this way.
nonisolated func encodeArgsToJSON(_ args: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(args),
        let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
        let str = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return str
}
