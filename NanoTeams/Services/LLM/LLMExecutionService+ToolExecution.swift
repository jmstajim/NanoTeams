import Foundation

/// Extension for tool call execution: authorization, caching, and runtime delegation.
extension LLMExecutionService {

    // MARK: - Tool Execution

    /// Result of tool execution including which indices were served from cache.
    struct ToolExecutionBatch {
        var results: [ToolExecutionResult]
        var cachedIndices: Set<Int>
    }

    /// Executes resolved tool calls (with caching and authorization) and returns results in order,
    /// along with the set of indices that were served from cache.
    /// Tool calls not in `allowedToolNames` are rejected with a `tool_not_authorized` error.
    func executeToolCalls(
        resolvedToolCalls: [StepToolCall],
        allowedToolNames: Set<String>,
        runtime: ToolRuntime,
        memory: ToolCallCache,
        task: NTMSTask,
        runIndex: Int,
        roleID: String
    ) -> ToolExecutionBatch {
        guard let delegate else { return ToolExecutionBatch(results: [], cachedIndices: []) }

        let context = ToolExecutionContext(
            workFolderRoot: delegate.workFolderURL ?? URL(fileURLWithPath: "/"),
            taskID: task.id,
            runID: task.runs[runIndex].id,
            roleID: roleID
        )

        var results: [ToolExecutionResult] = []
        var toolsToExecute: [StepToolCall] = []
        var cachedResults: [Int: ToolExecutionResult] = [:]
        var rejectedResults: [Int: ToolExecutionResult] = [:]

        for (idx, call) in resolvedToolCalls.enumerated() {
            // Normalize before authorization; call.name stays as-emitted for display / history.
            let name = ToolRegistry.resolveToolName(call.name)

            // Reject tool calls not in the role's allowed set
            if !allowedToolNames.contains(name) {
                rejectedResults[idx] = Self.makeToolNotAuthorizedResult(
                    call: call, canonicalName: name, scope: "for this role"
                )
                continue
            }

            if let cachedJSON = memory.getCachedResultIfRedundant(
                toolName: call.name, argumentsJSON: call.argumentsJSON)
            {
                let cached = ToolExecutionResult(
                    providerID: call.providerID ?? UUID().uuidString,
                    toolName: call.name,
                    argumentsJSON: call.argumentsJSON,
                    outputJSON: cachedJSON,
                    isError: false
                )
                cachedResults[idx] = cached
            } else {
                toolsToExecute.append(call)
            }
        }

        let freshResults = runtime.executeAll(context: context, toolCalls: toolsToExecute)

        var freshIdx = 0
        for (idx, _) in resolvedToolCalls.enumerated() {
            if let rejected = rejectedResults[idx] {
                results.append(rejected)
            } else if let cached = cachedResults[idx] {
                results.append(cached)
            } else {
                results.append(freshResults[freshIdx])
                freshIdx += 1
            }
        }

        return ToolExecutionBatch(results: results, cachedIndices: Set(cachedResults.keys))
    }

    /// Builds a `tool_not_authorized` error result. `call.name` is preserved as-emitted
    /// for display; `canonicalName` goes into the error envelope's `tool` field. `scope`
    /// disambiguates executor ("for this role") vs meeting ("in this meeting").
    static func makeToolNotAuthorizedResult(
        call: StepToolCall,
        canonicalName: String,
        scope: String
    ) -> ToolExecutionResult {
        let msg = "Tool '\(call.name)' is not available \(scope). Use only tools listed in your system prompt."
        return ToolExecutionResult(
            providerID: call.providerID ?? UUID().uuidString,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            outputJSON: #"{"error":"tool_not_authorized","tool":""# + canonicalName + #"","message":""# + msg + #""}"#,
            isError: true
        )
    }
}
