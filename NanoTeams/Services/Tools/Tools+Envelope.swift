import Foundation

// MARK: - Response Envelope Types (Private)

private struct SuccessEnvelope<D: Encodable>: Encodable {
    var ok: Bool
    var data: D
    var error: ToolError?
    var next: NextHint?
    var meta: ToolResultMeta
}

private struct ErrorEnvelope: Encodable {
    var ok: Bool
    var data: String?
    var error: ToolError
    var next: NextHint?
    var meta: ToolResultMeta
}

// MARK: - Response Envelope Helpers

func makeSuccessEnvelope<T: Encodable>(
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

func makeErrorEnvelope(
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

func makeSuccessResult(
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

func makeErrorResult(
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

// MARK: - Supervisor Question Result

func makeSupervisorQuestionResult(
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

// MARK: - JSON Helpers

private func encodeToJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONCoderFactory.makeWireEncoder()
    guard let data = try? encoder.encode(value),
        let str = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return str
}

func encodeArgsToJSON(_ args: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
        let str = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return str
}
