import Foundation

/// Exactly one case, on purpose (wave 32). Its three former siblings were declared error
/// routes the runtime deliberately replaced with RECOVERY, so none could ever fire:
/// `toolNotFound` → the missing-handler guard builds its own `tool_not_found` envelope
/// inline; `invalidArgumentsJSON` → unparseable args are wrapped as `__raw_input__` for
/// handler-side recovery; `emptyKeyInArguments` → empty keys are silently stripped
/// (gpt-oss-20b emits `{"":""}` for no-parameter tools). A declared case nobody can
/// construct makes the reader tracing "how does an unknown tool fail" end in a route that
/// never runs — the `LLMStepStop.needsAcceptance` class.
nonisolated enum ToolRuntimeError: LocalizedError {
    case argumentsNotObject

    var errorDescription: String? {
        switch self {
        case .argumentsNotObject:
            "Tool arguments must be a JSON object. Expected format: {\"param\": \"value\"}"
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

    /// How many read-only tool calls of one batch run at once.
    ///
    /// Small on purpose, and the reason is compounding rather than throughput: `search` is one
    /// of the tools admitted here, and it fans its own scan out `SearchExecutor
    /// .defaultScanConcurrency` wide. Four concurrent searches is therefore up to 32 files
    /// resident at `maxSearchableFileBytes` apiece. A model emits a handful of calls per turn
    /// and rarely two searches in one, so the width buys the realistic case (several
    /// `read_file`s, or a read beside a `git_diff`) without authorising the pathological one.
    static let readOnlyBatchConcurrency = 4

    /// Whether this batch may run concurrently.
    ///
    /// Membership comes from `ToolHandlerRegistry.readOnlyTools`, which is DERIVED from
    /// `ToolCategory` (`.fileRead` ∪ `.gitRead`) rather than listed here — so a read-only tool
    /// added later joins automatically, and a tool that changes category leaves. A hand-list
    /// would be a second home for "which tools only observe the work folder", and the one that
    /// drifts (CLAUDE.md #51).
    ///
    /// `bash` is deliberately absent even though most invocations only read: membership is a
    /// property of the TOOL, decided without seeing the command, and `bash` writes or does not
    /// depending on the string. `readOnlyTools`' own doc records the same reasoning for the same
    /// reason.
    ///
    /// A signal-emitting tool is NOT excluded, and `search` is one. Signals are consumed later,
    /// in call order, by `LLMExecutionService+ToolResultProcessing` — running the handler that
    /// produced one concurrently changes nothing about when or in what order it is handled.
    private static func isParallelisable(_ toolCalls: [StepToolCall]) -> Bool {
        toolCalls.count > 1 && toolCalls.allSatisfy {
            ToolHandlerRegistry.readOnlyTools.contains(ToolRegistry.resolveToolName($0.name))
        }
    }

    func executeAll(context: ToolExecutionContext, toolCalls: [StepToolCall]) async
        -> [ToolExecutionResult]
    {
        if Self.isParallelisable(toolCalls) {
            return await executeReadOnlyBatch(context: context, toolCalls: toolCalls)
        }
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
            results.append(await executeOne(context: context, call: call))
        }
        return results
    }

    /// Runs a batch of read-only calls concurrently, returning results in CALL order.
    ///
    /// Order is not cosmetic. The caller interleaves these back against the model's emission
    /// positions by index, and `MemoryTagStore` then stamps them — `<§R1§>`, `<§R2§>` — in that
    /// same order. Tags are handles the model refers back to across turns, so a batch that
    /// numbered them by whichever read finished first would mint a different transcript on every
    /// run for identical inputs. The stamping itself stays where it was, sequential and outside
    /// this class; all that is required here is that the array come back in the order it went in.
    ///
    /// Cancellation differs from the sequential path, deliberately. There, `Task.isCancelled` is
    /// consulted BETWEEN handlers and every remaining call gets a cancel envelope. Here every
    /// call has already started, so the check happens once, before any of them do; a cancel that
    /// lands mid-batch reaches each handler through its own `Task.isCancelled` (these are child
    /// tasks) and the ones that check it — `search` reads it per file — stop early on their own.
    /// The 1:1 result-per-call mapping the caller's `freshIdx` walk depends on holds either way.
    private func executeReadOnlyBatch(
        context: ToolExecutionContext, toolCalls: [StepToolCall]
    ) async -> [ToolExecutionResult] {
        if Task.isCancelled {
            return toolCalls.map {
                makeCancelledResult(
                    toolName: $0.name,
                    argumentsJSON: $0.argumentsJSON,
                    providerID: $0.providerID ?? UUID().uuidString)
            }
        }

        // Collected as (index, result) pairs and sorted at the end rather than written into a
        // pre-sized optional array. Same order, but no "and if a slot were somehow empty" arm:
        // the loop adds exactly `toolCalls.count` tasks and drains the group, so an empty slot
        // was unreachable — and an unreachable fallback is a branch nothing can ever exercise
        // sitting on the path a reader traces to answer "what happens if a tool call vanishes".
        var collected: [(index: Int, result: ToolExecutionResult)] = []
        collected.reserveCapacity(toolCalls.count)
        await withTaskGroup(of: (Int, ToolExecutionResult).self) { group in
            var next = 0
            let window = min(Self.readOnlyBatchConcurrency, toolCalls.count)
            while next < window {
                let index = next
                group.addTask { (index, await self.executeOne(context: context, call: toolCalls[index])) }
                next += 1
            }
            while let (index, result) = await group.next() {
                collected.append((index, result))
                if next < toolCalls.count {
                    let queued = next
                    group.addTask {
                        (queued, await self.executeOne(context: context, call: toolCalls[queued]))
                    }
                    next += 1
                }
            }
        }
        return collected.sorted { $0.index < $1.index }.map(\.result)
    }

    private func executeOne(context: ToolExecutionContext, call: StepToolCall) async
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

        // Single measurement site covering every tool. `ContinuousClock` (not `MonotonicClock`,
        // which is an ordering source — see `ToolCallLogRecord.durationMS`) and suspend-inclusive,
        // which is the right semantic for perceived tool latency. Two clock reads cost ~40 ns
        // against calls measured in milliseconds, so this is NOT gated behind `#if DEBUG` — the
        // numbers are most needed in release builds and headless runs. The sink is already gated:
        // `logger` is nil when `loggingEnabled` is off.
        let started = ContinuousClock.now
        func elapsedMS() -> Double { (ContinuousClock.now - started).milliseconds }

        do {
            let rawParsedArgs = try parseAndNormalizeArguments(rawArgs)
            let args = unwrapReentrantEnvelope(rawParsedArgs, expectedToolName: name)
            var result = try await handler(context, args)
            result.providerID = providerID
            logger?.append(baseRecord.withResult(result: result, durationMS: elapsedMS()))
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
            logger?.append(baseRecord.withResult(
                result: result, errorMessage: message, durationMS: elapsedMS()))
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
    fileprivate func withResult(
        result: ToolExecutionResult,
        errorMessage: String? = nil,
        durationMS: Double? = nil
    ) -> ToolCallLogRecord {
        ToolCallLogRecord(
            createdAt: createdAt,
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            resultJSON: result.outputJSON,
            errorMessage: errorMessage,
            durationMS: durationMS
        )
    }
}
