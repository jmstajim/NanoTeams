import Foundation

/// Summary of a single bash command run during a task execution round.
nonisolated struct BashRunSummaryDTO: Codable, Hashable, Sendable {
    var command: String
    var exit_code: Int?
    var outcome: String
}

/// Round execution metrics and bash history attached to the `review` event and `task_status`.
nonisolated struct RoundSummaryDTO: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case round
        case bash_runs
        case bash_run_count
        case tool_error_count
        case tool_errors
    }

    var round: Int
    var bash_runs: [BashRunSummaryDTO]
    var bash_run_count: Int?
    var tool_error_count: Int
    var tool_errors: [String: Int]?
    var isForeign: Bool = false

    init(
        round: Int,
        bash_runs: [BashRunSummaryDTO] = [],
        bash_run_count: Int? = nil,
        tool_error_count: Int,
        tool_errors: [String: Int]? = nil,
        isForeign: Bool = false
    ) {
        self.round = round
        self.bash_runs = bash_runs
        self.bash_run_count = bash_run_count
        self.tool_error_count = tool_error_count
        self.tool_errors = tool_errors
        self.isForeign = isForeign
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(round, forKey: .round)
        try container.encode(tool_error_count, forKey: .tool_error_count)
        if isForeign {
            try container.encode(bash_run_count ?? bash_runs.count, forKey: .bash_run_count)
        } else {
            try container.encode(bash_runs, forKey: .bash_runs)
            try container.encodeIfPresent(tool_errors, forKey: .tool_errors)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        round = try container.decode(Int.self, forKey: .round)
        bash_runs = try container.decodeIfPresent([BashRunSummaryDTO].self, forKey: .bash_runs) ?? []
        bash_run_count = try container.decodeIfPresent(Int.self, forKey: .bash_run_count)
        tool_error_count = try container.decode(Int.self, forKey: .tool_error_count)
        tool_errors = try container.decodeIfPresent([String: Int].self, forKey: .tool_errors)
        isForeign = container.contains(.bash_run_count) && !container.contains(.bash_runs)
    }

    func redactedForForeignTask() -> RoundSummaryDTO {
        RoundSummaryDTO(
            round: round,
            bash_runs: [],
            bash_run_count: bash_runs.count,
            tool_error_count: tool_error_count,
            tool_errors: nil,
            isForeign: true
        )
    }
}

/// Approval pending details reported in the wait-for-events heartbeat.
nonisolated struct HeartbeatApprovalDTO: Codable, Hashable, Sendable {
    var kind: String
    var detail: String
}

/// Diagnostic in-memory task status summary returned upon `wait_for_events` timeout.
nonisolated struct TaskHeartbeatSummary: Codable, Hashable, Sendable {
    var task_id: Int
    var status: String
    var phase: String?
    var elapsed_seconds: Int?
    var tool_call_count: Int?
    var last_activity_at: String?
    var awaiting_approval: HeartbeatApprovalDTO?
}

extension RoundSummaryDTO {
    static func build(for run: Run) -> RoundSummaryDTO {
        let round = run.round
        let roundStartedAt = run.roundStartedAt

        // All steps' tool calls belonging to this round
        var roundCalls: [StepToolCall] = []
        for step in run.steps {
            for call in step.toolCalls {
                if round == 1 || call.createdAt >= roundStartedAt {
                    roundCalls.append(call)
                }
            }
        }

        var bashRuns: [BashRunSummaryDTO] = []
        var toolErrorCount = 0
        var toolErrors: [String: Int] = [:]

        for call in roundCalls {
            let isErr = call.isError == true
            if call.name == ToolNames.bash {
                let parsedArgs = ToolCallDataUtils.parseJSON(call.argumentsJSON)
                let cmdRaw = parsedArgs?["command"] as? String ?? ToolCallSummarizer.cardSummary(
                    toolName: call.name,
                    argumentsJSON: call.argumentsJSON,
                    resultJSON: call.resultJSON,
                    isError: isErr
                )
                let command = MCPTextSanitizer.singleLine(cmdRaw)

                let parsedResult = call.resultJSON.flatMap { ToolCallDataUtils.parseJSON($0) }
                let resultData = (parsedResult?["data"] as? [String: Any]) ?? parsedResult
                let exitCode = resultData?["exit_code"] as? Int
                let timedOut = resultData?["timed_out"] as? Bool == true

                let rawOutcome = ToolCallSummarizer.outcomeSummary(toolName: ToolNames.bash, resultJSON: call.resultJSON ?? "")
                    ?? (isErr ? "failed" : (exitCode == 0 ? "exit 0" : (exitCode != nil ? "failed: exit \(exitCode!)" : "ok")))
                let outcome = MCPTextSanitizer.singleLine(rawOutcome == "ok" && exitCode == 0 ? "exit 0" : rawOutcome)

                bashRuns.append(BashRunSummaryDTO(command: command, exit_code: exitCode, outcome: outcome))

                let bashFailed = (exitCode != nil && exitCode != 0) || timedOut || isErr
                if bashFailed {
                    toolErrorCount += 1
                    toolErrors[call.name, default: 0] += 1
                }
            } else {
                if isErr {
                    toolErrorCount += 1
                    toolErrors[call.name, default: 0] += 1
                }
            }
        }

        return RoundSummaryDTO(
            round: round,
            bash_runs: bashRuns,
            tool_error_count: toolErrorCount,
            tool_errors: toolErrors.isEmpty ? nil : toolErrors
        )
    }
}
