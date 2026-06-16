import Foundation

nonisolated enum ToolRuntimeError: LocalizedError {
    case toolNotFound(String)
    case invalidArgumentsJSON(String)
    case argumentsNotObject
    case emptyKeyInArguments

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            "Tool not found: \(name)"
        case .invalidArgumentsJSON(let raw):
            "Tool arguments are not valid JSON: \(raw). Expected format: {\"param\": \"value\"}"
        case .argumentsNotObject:
            "Tool arguments must be a JSON object. Expected format: {\"param\": \"value\"}"
        case .emptyKeyInArguments:
            "Tool arguments contain empty key. Expected format: {\"param\": \"value\"}, not {\"\"} or {\"\": \"\"}"
        }
    }
}

nonisolated final class ToolRuntime: @unchecked Sendable {
    private let registry: ToolRegistry
    private let logger: ToolCallLogger?
    /// The per-run `network_log.json` writer, SHARED with the streaming client so
    /// every tool call lands in the same audit file (one instance = one serial
    /// queue = no read-rewrite race). Nil when logging is disabled.
    private let networkLogger: NetworkLogger?

    init(
        registry: ToolRegistry,
        logger: ToolCallLogger?,
        networkLogger: NetworkLogger? = nil
    ) {
        self.registry = registry
        self.logger = logger
        self.networkLogger = networkLogger
    }

    func executeAll(context: ToolExecutionContext, toolCalls: [StepToolCall])
        -> [ToolExecutionResult]
    {
        var results: [ToolExecutionResult] = []
        results.reserveCapacity(toolCalls.count)
        for (i, call) in toolCalls.enumerated() {
            // Emit one cancellation envelope per remaining call so the caller's
            // index-paired interleave in `LLMExecutionService.executeToolCalls`
            // still gets a 1:1 result-per-call mapping. Without 1:1, `freshIdx`
            // walks off the end of the results array.
            if Task.isCancelled {
                for remaining in toolCalls[i...] {
                    results.append(makeCancelledResult(
                        toolName: remaining.name,
                        argumentsJSON: remaining.argumentsJSON,
                        providerID: remaining.providerID ?? UUID().uuidString
                    ))
                }
                return results
            }
            results.append(executeOne(context: context, call: call))
        }
        return results
    }

    private func executeOne(context: ToolExecutionContext, call: StepToolCall)
        -> ToolExecutionResult
    {
        let name = ToolRegistry.resolveToolName(call.name)
        let rawArgs = call.argumentsJSON

        let baseRecord = ToolCallLogRecord(
            createdAt: MonotonicClock.shared.now(),
            taskID: context.taskID,
            runID: context.runID,
            roleID: context.roleID,
            toolName: call.name,
            argumentsJSON: rawArgs,
            resultJSON: nil,
            errorMessage: nil
        )

        let providerID = call.providerID ?? UUID().uuidString

        guard let handler = registry.handler(for: name) else {
            let hint = name == call.name
                ? "No handler for '\(call.name)'. Check the tool list in your system prompt."
                : "No handler for '\(call.name)' (resolved to '\(name)'). Check the tool list in your system prompt."
            let result = ToolExecutionResult(
                providerID: providerID,
                toolName: call.name,
                argumentsJSON: rawArgs,
                outputJSON: toolErrorJSON(type: "tool_not_found", message: hint),
                isError: true
            )
            logger?.append(baseRecord.withResult(result: result))
            appendNetworkRecord(context: context, call: call, result: result, errorMessage: hint)
            return result
        }

        do {
            let rawParsedArgs = try parseAndNormalizeArguments(rawArgs)
            let args = unwrapReentrantEnvelope(rawParsedArgs, expectedToolName: name)
            var result = try handler(context, args)
            result.providerID = providerID
            logger?.append(baseRecord.withResult(result: result))
            appendNetworkRecord(context: context, call: call, result: result, errorMessage: nil)
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let result = ToolExecutionResult(
                providerID: providerID,
                toolName: call.name,
                argumentsJSON: rawArgs,
                outputJSON: toolErrorJSON(type: "execution_failed", message: message),
                isError: true
            )
            logger?.append(baseRecord.withResult(result: result, errorMessage: message))
            appendNetworkRecord(context: context, call: call, result: result, errorMessage: message)
            return result
        }
    }

    /// Mirrors an executed tool call into the shared `network_log.json` as a
    /// `.toolCall` record (no-op when network logging is disabled). Cancellation
    /// envelopes (built in `executeAll`, never through `executeOne`) are NOT
    /// logged — parity with `tool_calls.jsonl`.
    private func appendNetworkRecord(
        context: ToolExecutionContext,
        call: StepToolCall,
        result: ToolExecutionResult,
        errorMessage: String?
    ) {
        guard let networkLogger else { return }
        networkLogger.append(NetworkLogger.createToolCallRecord(
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            resultJSON: result.outputJSON,
            errorMessage: errorMessage,
            stepID: context.roleID
        ))
    }

    /// Records a tool call that did NOT go through `executeOne` — pre-runtime
    /// rejections (unauthorized / duplicate-write) and parse failures (malformed /
    /// missing-name). Writes to BOTH per-run sinks the runtime owns:
    /// `tool_calls.jsonl` and `network_log.json`. Each is a single shared instance
    /// (one serial queue), so this is the race-free home for "log a non-executed
    /// call". No-ops for whichever sink has logging disabled.
    func logNonExecutedCall(
        taskID: Int,
        runID: Int,
        roleID: String,
        toolName: String,
        argumentsJSON: String,
        resultJSON: String?,
        errorMessage: String?
    ) {
        logger?.append(ToolCallLogRecord(
            createdAt: MonotonicClock.shared.now(),
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            resultJSON: resultJSON,
            errorMessage: errorMessage
        ))
        networkLogger?.append(NetworkLogger.createToolCallRecord(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            resultJSON: resultJSON,
            errorMessage: errorMessage,
            stepID: roleID
        ))
    }

    /// Parses raw JSON arguments string into a normalized [String: Any] dictionary.
    /// Handles empty args, non-JSON plain strings (wraps as __raw_input__), and sanitizes keys.
    private func parseAndNormalizeArguments(_ rawArgs: String) throws -> [String: Any] {
        let trimmedArgs = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let argsAny: Any
        if trimmedArgs.isEmpty {
            argsAny = [:]
        } else {
            let sanitized = JSONUtilities.sanitizeJSONControlCharacters(trimmedArgs)
            if let data = sanitized.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
            {
                argsAny = parsed
            } else {
                // LLM passed a plain string instead of a JSON object — wrap it so
                // tool handlers can recover via the __raw_input__ fallback key.
                argsAny = ["__raw_input__": trimmedArgs] as [String: Any]
            }
        }

        guard var args = argsAny as? [String: Any] else {
            throw ToolRuntimeError.argumentsNotObject
        }

        // Sanitize argument keys — LLMs sometimes emit keys with leading/trailing whitespace or newlines
        // (e.g., "\nnew_text" instead of "new_text"). Auto-fix rather than rejecting.
        // Some models (gpt-oss-20b) emit {"":""} for no-parameter tools — strip empty keys silently.
        for key in Array(args.keys) {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                args.removeValue(forKey: key)
                continue
            }
            if key != trimmedKey {
                args[trimmedKey] = args.removeValue(forKey: key)
            }
        }

        return args
    }

    /// Builds an error JSON string for ToolExecutionResult.outputJSON.
    private func toolErrorJSON(type: String, message: String?) -> String {
        if let message {
            return #"{"error":""# + type + #"","message":""# + escapeJSON(message) + #""}"#
        }
        return #"{"error":""# + type + #""}"#
    }

    private func escapeJSON(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(#"\""#)  // "
            case 0x5C: out.append(#"\\"#)  // \
            case 0x0A: out.append(#"\n"#)
            case 0x0D: out.append(#"\r"#)
            case 0x09: out.append(#"\t"#)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.append(String(scalar))
            }
        }
        return out
    }

    nonisolated deinit {}
}

nonisolated extension ToolCallLogRecord {
    fileprivate func withResult(result: ToolExecutionResult, errorMessage: String? = nil)
        -> ToolCallLogRecord
    {
        ToolCallLogRecord(
            createdAt: createdAt,
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            resultJSON: result.outputJSON,
            errorMessage: errorMessage
        )
    }
}
