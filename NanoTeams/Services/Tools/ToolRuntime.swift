import Foundation

enum ToolRuntimeError: LocalizedError {
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

final class ToolRuntime {
    private let registry: ToolRegistry
    private let logger: ToolCallLogger?

    init(
        registry: ToolRegistry,
        logger: ToolCallLogger?
    ) {
        self.registry = registry
        self.logger = logger
    }

    func executeAll(context: ToolExecutionContext, toolCalls: [StepToolCall])
        -> [ToolExecutionResult]
    {
        toolCalls.map { executeOne(context: context, call: $0) }
    }

    private func executeOne(context: ToolExecutionContext, call: StepToolCall)
        -> ToolExecutionResult
    {
        let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawArgs = call.argumentsJSON

        let baseRecord = ToolCallLogRecord(
            createdAt: MonotonicClock.shared.now(),
            taskID: context.taskID,
            runID: context.runID,
            roleID: context.roleID,
            toolName: name,
            argumentsJSON: rawArgs,
            resultJSON: nil,
            errorMessage: nil
        )

        // Resolve providerID: use from call or generate UUID for strict OpenAI compliance
        let providerID = call.providerID ?? UUID().uuidString

        guard let handler = registry.handler(for: name) else {
            let result = ToolExecutionResult(
                providerID: providerID,
                toolName: name,
                argumentsJSON: rawArgs,
                outputJSON: toolErrorJSON(type: "tool_not_found", message: nil),
                isError: true
            )
            logger?.append(baseRecord.withResult(result: result))
            return result
        }

        do {
            let args = try parseAndNormalizeArguments(rawArgs)
            var result = try handler(context, args)
            result.providerID = providerID
            logger?.append(baseRecord.withResult(result: result))
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let result = ToolExecutionResult(
                providerID: providerID,
                toolName: name,
                argumentsJSON: rawArgs,
                outputJSON: toolErrorJSON(type: "execution_failed", message: message),
                isError: true
            )
            logger?.append(baseRecord.withResult(result: result, errorMessage: message))
            return result
        }
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
}

extension ToolCallLogRecord {
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
