import Foundation
import XCTest
@testable import NanoTeams

// MARK: - Headless Result

struct HeadlessResult {
    enum Outcome: String {
        case success
        case timeout
        case failed
        case error
    }

    var outcome: Outcome
    var taskID: Int?
    var runID: Int?
    var duration: TimeInterval
    var roleResults: [RoleResult]
    var artifacts: [ArtifactResult]
    var errors: [String]
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    struct RoleResult {
        var stepID: String
        var roleName: String
        var status: RoleExecutionStatus
        var stepStatus: StepStatus?
        var messageCount: Int
        var toolCallCount: Int
    }

    struct ArtifactResult {
        var name: String
        var contentPreview: String
        var fullContentLength: Int
    }
}

// MARK: - Headless Runner

@MainActor
final class HeadlessRunner {

    private let config: HeadlessConfig
    private var orchestrator: NTMSOrchestrator!

    init(config: HeadlessConfig) {
        self.config = config
    }

    func run() async -> HeadlessResult {
        let startTime = Date()

        // 1. Validate project path
        let projectURL = URL(fileURLWithPath: config.projectPath)
        guard FileManager.default.fileExists(atPath: config.projectPath) else {
            return errorResult("Project path does not exist: \(config.projectPath)", startTime: startTime)
        }

        // 2. Create orchestrator (LM Studio needs no API keys)
        orchestrator = NTMSOrchestrator(repository: NTMSRepository())

        // 3. Configure LLM
        let provider = config.resolvedProvider
        orchestrator.configuration.llmProvider = provider
        orchestrator.configuration.llmBaseURLString = config.resolvedBaseURL
        orchestrator.configuration.llmModelName = config.resolvedModel
        if let maxTokens = config.maxTokens {
            orchestrator.configuration.llmMaxTokens = maxTokens
        }
        if let temp = config.temperature {
            orchestrator.configuration.llmTemperature = temp
        }
        if let retries = config.maxLLMRetries {
            orchestrator.configuration.maxLLMRetries = retries
        }

        // Enable logging so network_log.json and tool_calls.jsonl are written
        orchestrator.configuration.loggingEnabled = true

        // Configure vision model (enables analyze_image tool)
        if let visionModel = config.visionModel, !visionModel.isEmpty {
            orchestrator.configuration.visionModelName = visionModel
            if let visionURL = config.visionBaseURL, !visionURL.isEmpty {
                orchestrator.configuration.visionBaseURLString = visionURL
            }
        }

        print("[HEADLESS] Provider: \(provider.rawValue) | \(config.resolvedBaseURL) | \(config.resolvedModel)")

        // 4. Open project
        await orchestrator.openWorkFolder(projectURL)
        if let err = orchestrator.lastErrorMessage {
            return errorResult("openWorkFolder failed: \(err)", startTime: startTime)
        }

        // 5. Switch team if needed
        if let templateName = config.teamTemplate,
           let wf = orchestrator.workFolder,
           let team = wf.teams.first(where: { $0.templateID == templateName }) {
            await orchestrator.switchTeam(to: team.id)
            print("[HEADLESS] Team: \(team.name)")
        }

        // 6. Set scheme if provided
        if let scheme = config.selectedScheme {
            await orchestrator.mutateWorkFolder { proj in
                proj.settings.selectedScheme = scheme
            }
            print("[HEADLESS] Scheme: \(scheme)")
        }

        // 7. Set project description if provided
        if let desc = config.projectDescription {
            await orchestrator.updateWorkFolderDescription(desc)
        }

        // 8. Create task
        guard let taskID = await orchestrator.createTask(
            title: config.taskTitle,
            supervisorTask: config.supervisorTask
        ) else {
            return errorResult(
                "createTask failed: \(orchestrator.lastErrorMessage ?? "unknown")",
                startTime: startTime
            )
        }
        print("[HEADLESS] Task created: \(String(taskID).prefix(8))... — \"\(config.taskTitle)\"")

        // 9. Set supervisorMode to autonomous for headless runs
        await orchestrator.mutateWorkFolder { wf in
            if let idx = wf.teams.firstIndex(where: { $0.id == wf.activeTeamID }) {
                wf.teams[idx].settings.supervisorMode = .autonomous
            }
        }

        // 10. Start run
        await orchestrator.startRun(taskID: taskID)
        print("[HEADLESS] Run started (supervisorMode: autonomous)")

        // 11. Poll for completion
        let result = await pollUntilComplete(taskID: taskID, startTime: startTime)

        // 12. Auto-close if all roles done
        let engineState = orchestrator.engineState.taskEngineStates[taskID]
        if engineState == .done || engineState == .needsAcceptance {
            _ = await orchestrator.closeTask(taskID: taskID)
        }

        return result
    }

    // MARK: - Polling

    private func pollUntilComplete(taskID: Int, startTime: Date) async -> HeadlessResult {
        let timeout = config.resolvedTimeout
        let pollNanos: UInt64 = 2_000_000_000 // 2 seconds

        while true {
            let elapsed = Date().timeIntervalSince(startTime)

            if elapsed >= timeout {
                print("[HEADLESS] TIMEOUT after \(Int(elapsed))s")
                return buildResult(taskID: taskID, outcome: .timeout, startTime: startTime,
                                   errors: ["Timeout after \(Int(elapsed))s"])
            }

            let state = orchestrator.engineState.taskEngineStates[taskID] ?? .pending

            switch state {
            case .done, .needsAcceptance:
                print("[HEADLESS] Run completed (\(state.rawValue))")
                return buildResult(taskID: taskID, outcome: .success, startTime: startTime)

            case .failed:
                let msg = orchestrator.lastErrorMessage ?? "Engine failed"
                print("[HEADLESS] Run FAILED: \(msg)")
                return buildResult(taskID: taskID, outcome: .failed, startTime: startTime,
                                   errors: [msg])

            case .paused:
                print("[HEADLESS] Engine paused — resuming...")
                await orchestrator.resumeRun(taskID: taskID)

            case .running, .pending, .needsSupervisorInput:
                printProgress(taskID: taskID, elapsed: elapsed)
            }

            try? await Task.sleep(nanoseconds: pollNanos)
        }
    }

    private func printProgress(taskID: Int, elapsed: TimeInterval) {
        guard let task = orchestrator.loadedTask(taskID),
              let run = task.runs.last else { return }

        let working = run.roleStatuses
            .filter { $0.value == .working }
            .map(\.key)
        let doneCount = run.roleStatuses
            .filter { $0.value == .done || $0.value == .accepted }
            .count
        let total = run.roleStatuses.count

        let workingNames = working.isEmpty ? "—" : working.joined(separator: ", ")
        print("[HEADLESS] \(Int(elapsed))s | Done: \(doneCount)/\(total) | Working: \(workingNames)")
    }

    // MARK: - Result Building

    private func buildResult(
        taskID: Int,
        outcome: HeadlessResult.Outcome,
        startTime: Date,
        errors: [String] = []
    ) -> HeadlessResult {
        let task = orchestrator.loadedTask(taskID)
        let run = task.flatMap { $0.runs.last }
        let team = orchestrator.resolvedTeam(for: task)

        var roleResults: [HeadlessResult.RoleResult] = []
        if let run {
            for (stepID, status) in run.roleStatuses {
                let roleDef = team.roles.first(where: { $0.id == stepID })
                let step = run.steps.first(where: { $0.effectiveRoleID == stepID })
                roleResults.append(HeadlessResult.RoleResult(
                    stepID: stepID,
                    roleName: roleDef?.name ?? stepID,
                    status: status,
                    stepStatus: step?.status,
                    messageCount: step?.messages.count ?? 0,
                    toolCallCount: step?.toolCalls.count ?? 0
                ))
            }
        }

        var artifactResults: [HeadlessResult.ArtifactResult] = []
        if let run {
            for step in run.steps {
                for artifact in step.artifacts {
                    artifactResults.append(HeadlessResult.ArtifactResult(
                        name: artifact.name,
                        contentPreview: "",
                        fullContentLength: 0
                    ))
                }
            }
        }

        var totalInput = 0
        var totalOutput = 0
        if let run {
            for step in run.steps {
                if let usage = step.tokenUsage {
                    totalInput += usage.inputTokens
                    totalOutput += usage.outputTokens
                }
            }
        }

        return HeadlessResult(
            outcome: outcome,
            taskID: taskID,
            runID: run?.id,
            duration: Date().timeIntervalSince(startTime),
            roleResults: roleResults,
            artifacts: artifactResults,
            errors: errors,
            inputTokens: totalInput,
            outputTokens: totalOutput
        )
    }

    private func errorResult(_ message: String, startTime: Date) -> HeadlessResult {
        print("[HEADLESS] ERROR: \(message)")
        return HeadlessResult(
            outcome: .error,
            duration: Date().timeIntervalSince(startTime),
            roleResults: [],
            artifacts: [],
            errors: [message]
        )
    }
}
