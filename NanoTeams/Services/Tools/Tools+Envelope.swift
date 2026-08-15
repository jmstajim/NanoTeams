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
/// `ToolErrorNotePolicy` switches on the top-level
/// `error` literal and routes `tool_not_authorized` into the bespoke "don't
/// retry" branch. The handler-shape envelope (`{"error":{"code":"COMMAND_FAILED",
/// …}}`) lands in the default branch, which tells the model to fix its arguments
/// and retry — a loop trap when args aren't the cause.
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

// MARK: - Plan-required (argument flavour)

/// Emits the executor-compatible `plan_required` envelope from a HANDLER — for the case where
/// the TOOL is authorized this iteration but one ARGUMENT is not, which the name-keyed
/// authorization layer in `+ToolExecution` structurally cannot express.
///
/// Sole caller today: `bash` with `run_in_background: true` during a role's planning phase.
///
/// Same shape and same reason as `makeToolNotAuthorizedConfigResult` above:
/// `ToolErrorNotePolicy` switches on the TOP-LEVEL `error` literal, and only this shape
/// reaches its `plan_required` arm — the one arm that appends NOTHING, precisely because
/// this envelope's own message already says "record your plan, then call it again". That
/// silence is the point: the message is the only place in the codebase telling a model to
/// repeat an identical call, and anything appended after it competes with it. A
/// `makeErrorResult(code:)` envelope is
/// `{"error":{"code":…}}` and lands in the default branch, which tells the model to correct
/// arguments that are in fact correct — a loop trap.
///
/// No new `ToolErrorCode` case: `plan_required` is an executor-level literal (it has no
/// `ToolErrorCode` today either), and minting one would create two spellings of one condition.
nonisolated func makePlanRequiredResult(
    toolName: String,
    args: [String: Any],
    message: String
) -> ToolExecutionResult {
    let payload: [String: String] = [
        "error": "plan_required",
        "tool": toolName,
        "message": message,
    ]
    let outputJSON: String = {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":"plan_required","tool":"\#(toolName)","message":"\#(message)"}"#
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
