import Foundation
@testable import NanoTeams

/// Why a `message_task` scenario's tool result could not be rendered.
enum AutovisorContinuationFixtureError: Error, Equatable {
    /// The scenario has no `message_task` slot to answer.
    case notAMessageTaskScenario(AutovisorContinuationScenario)
    /// The executor composed its envelope without asking the stand-in orchestrator, so the
    /// bytes are not the answer being measured.
    case orchestratorNotConsulted(AutovisorContinuationScenario)
}

// MARK: - Production-rendered tool results of the two `message_task` scenarios

/// The tool results the `message_task_in_review` and `message_task_on_paused` scenarios replay,
/// rendered by the code that renders them for a built-in Autovisor manager, so REC.10 measures
/// the bytes that ship. Fixture data is only what those renderers read: the orchestrator's
/// verdict on the call, and the task the manager inspected before making it.
///
/// Pinned against a real orchestrator by `AutovisorContinuationTrainerEnvelopePinTests`.
extension AutovisorContinuationTrainer {

    /// What `NTMSOrchestrator.performAutovisorAction` answers a built-in manager's `message_task`
    /// on the scenario's task, per arm (the routing `AutovisorActionDispatchTests` pins):
    ///
    /// - `.before` — the wave base `147da1b1`: every message was queued, the task was started
    ///   when not running, and the reply was `messageQueued` whatever state the task was in.
    /// - `.after` — since Ш5 (`2963b3bb`): a task in Review refuses the message
    ///   (`messageDiscardedTaskFinished`), and a paused one resumes its current run to deliver
    ///   it (`messageQueuedAndResumed`).
    ///
    /// `nil` for a scenario with no `message_task` slot.
    static func messageTaskReply(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        taskID: Int
    ) -> AutovisorActionResult? {
        switch (scenario, arm) {
        case (.messageTaskInReview, .before), (.messageTaskOnPaused, .before):
            return .success(.messageQueued(taskID: taskID))
        case (.messageTaskInReview, .after):
            return .failure(.messageDiscardedTaskFinished(taskID: taskID))
        case (.messageTaskOnPaused, .after):
            return .success(.messageQueuedAndResumed(taskID: taskID))
        case (.pauseNoEngine, _), (.repeatedClose, _), (.rosterTwoQuestions, _), (.delegationChildPausedTimeout, _):
            return nil
        }
    }

    /// The envelope a built-in manager reads for `message_task(argumentsJSON)`, through the chain
    /// the tool-result dispatcher runs: `AutovisorToolDecoding.decode`, then
    /// `AutovisorCommandExecutor.execute(as: .builtInManager)` into `applyAutovisorAction`'s
    /// envelope builder, over a stand-in orchestrator that answers with `messageTaskReply`.
    ///
    /// A call production would refuse throws the decoder's own `AutovisorDecodeFailure`, so a
    /// fixture cannot measure an `INVALID_ARGS` envelope by accident.
    static func messageTaskEnvelope(
        scenario: AutovisorContinuationScenario,
        arm: AutovisorContinuationArm,
        argumentsJSON: String
    ) async throws -> String {
        let command = try AutovisorToolDecoding.decode(tool: ToolNames.messageTask, rawArgs: argumentsJSON).get()
        guard case .messageTask(let taskID, _, _) = command,
              let action = command.autovisorAction,
              let reply = messageTaskReply(scenario: scenario, arm: arm, taskID: taskID)
        else {
            throw AutovisorContinuationFixtureError.notAMessageTaskScenario(scenario)
        }
        let orchestrator = MockLLMExecutionDelegate()
        orchestrator.autovisorActionResult = reply
        let service = LLMExecutionService(repository: NTMSRepository())
        service.attach(delegate: orchestrator)
        let envelope = await AutovisorCommandExecutor(executionService: service, delegate: orchestrator)
            .execute(command, as: .builtInManager)
        // Both hold the stand-in weakly; reading it here also keeps it alive across the call.
        guard orchestrator.autovisorActions == [action] else {
            throw AutovisorContinuationFixtureError.orchestratorNotConsulted(scenario)
        }
        return envelope
    }

    /// The `task_status` envelope the manager read before calling `message_task`, rendered by
    /// `LLMExecutionService.renderTaskStatusEnvelope` from a task in the scenario's state. The
    /// renderer is unchanged since `147da1b1` for a task with no step waiting on the Supervisor
    /// (the wave only added `pending_questions`), so both arms read what either build sent.
    ///
    /// `nil` for a scenario with no `message_task` slot.
    static func messageScenarioTaskStatusEnvelope(scenario: AutovisorContinuationScenario) -> String? {
        let roleID = "software_engineer"
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let task: NTMSTask
        let now: Date
        switch scenario {
        case .messageTaskInReview:
            // Finished, accepted by nobody yet, nothing at a per-role gate: Review.
            let elapsed: TimeInterval = 95
            let artifactName = "Code Changes"
            let step = StepExecution(
                id: roleID,
                role: .softwareEngineer,
                title: "Software Engineer",
                expectedArtifacts: [artifactName],
                status: .done,
                createdAt: started,
                updatedAt: started.addingTimeInterval(elapsed),
                completedAt: started.addingTimeInterval(elapsed),
                messages: stepMessages(count: 4, from: started),
                artifacts: [Artifact(
                    name: artifactName,
                    createdAt: started.addingTimeInterval(elapsed),
                    updatedAt: started.addingTimeInterval(elapsed),
                    relativePath: persistedArtifactPath(taskID: 4, roleID: roleID, artifactName: artifactName))],
                toolCalls: stepToolCalls(count: 6, from: started)
            )
            task = NTMSTask(
                id: 4,
                title: "Add unit tests",
                supervisorTask: "Add unit tests for the input parser.",
                createdAt: started,
                updatedAt: started.addingTimeInterval(elapsed),
                runs: [Run(id: 0, createdAt: started, steps: [step], roleStatuses: [roleID: .done])]
            )
            now = started.addingTimeInterval(elapsed)
        case .messageTaskOnPaused:
            // Paused mid-run, its role still `.working`: a step `control_task resume` continues.
            // The pause is status recovery's (the app quit mid-run), recorded as the recovery
            // records it — a pause with no recorded cause reads as the person's, which the
            // manager's resume is refused (D-M18, 2026-11-12).
            let elapsed: TimeInterval = 60
            let step = StepExecution(
                id: roleID,
                role: .softwareEngineer,
                title: "Software Engineer",
                expectedArtifacts: ["Code Changes"],
                status: .paused,
                createdAt: started,
                updatedAt: started.addingTimeInterval(elapsed),
                messages: stepMessages(count: 3, from: started),
                toolCalls: stepToolCalls(count: 4, from: started)
            )
            task = NTMSTask(
                id: 5,
                title: "Refactor networking",
                supervisorTask: "Refactor the networking layer onto an injected URLSessionConfiguration.",
                createdAt: started,
                updatedAt: started.addingTimeInterval(elapsed),
                runs: [Self.recoveredRun(Run(id: 0, createdAt: started, steps: [step], roleStatuses: [roleID: .working]))]
            )
            now = started.addingTimeInterval(elapsed)
        case .pauseNoEngine, .repeatedClose, .rosterTwoQuestions, .delegationChildPausedTimeout:
            return nil
        }
        return LLMExecutionService.renderTaskStatusEnvelope(
            task: task,
            team: singleEngineerTeam(roleID: roleID),
            now: now
        )
    }

    // MARK: - Task state the renderers read

    /// The team the inspected task runs on — only its roster is read, for `role_kind`.
    private static func singleEngineerTeam(roleID: String) -> Team {
        Team(
            name: "Trainer Engineering",
            roles: [TeamRoleDefinition(
                id: roleID,
                name: "Software Engineer",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: [SystemTemplates.supervisorTaskArtifactName],
                    producesArtifacts: ["Code Changes"]))],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    /// Where `NTMSRepository.persistStepArtifactFile` puts an artifact, relative to
    /// `.nanoteams/` — the form `task_status` turns into a `read_file` path.
    private static func persistedArtifactPath(taskID: Int, roleID: String, artifactName: String) -> String {
        let paths = NTMSPaths(workFolderRoot: URL(fileURLWithPath: "/TrainerProject", isDirectory: true))
        let file = paths.roleDir(taskID: taskID, runID: 0, roleID: roleID)
            .appendingPathComponent("artifact_\(Artifact.slugify(artifactName)).md", isDirectory: false)
        return paths.relativePathWithinNanoteams(for: file)
    }

    /// `task_status` reports only how many messages a step holds.
    /// `run` as status recovery leaves it after parking the work an app quit interrupted.
    private static func recoveredRun(_ run: Run) -> Run {
        var run = run
        run.pauseCause = .recovered
        return run
    }

    private static func stepMessages(count: Int, from start: Date) -> [StepMessage] {
        (0..<count).map { index in
            StepMessage(
                createdAt: start.addingTimeInterval(TimeInterval(index + 1)),
                role: .softwareEngineer,
                content: "Progress note \(index + 1).")
        }
    }

    /// `task_status` reports only how many calls a step made; every one has its result, so no
    /// call reads as still in flight.
    private static func stepToolCalls(count: Int, from start: Date) -> [StepToolCall] {
        (0..<count).map { index in
            StepToolCall(
                createdAt: start.addingTimeInterval(TimeInterval(index + 10)),
                name: ToolNames.readFile,
                argumentsJSON: #"{"path":"Sources/Parser.swift"}"#,
                resultJSON: #"{"data":{"content":"…"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#,
                isError: false)
        }
    }
}
