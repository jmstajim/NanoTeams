import Foundation

/// Team generation flow for "Generated Team" template tasks.
///
/// When a task is started with `preferredTeamID` pointing to the Generated Team template,
/// we inject a synthetic Supervisor step containing a `create_team` tool call, then run
/// `TeamGenerationService` in the background. The tool call appears in the activity feed
/// (like `analyze_image`), and the graph shows a loader while generation is in progress.
/// On completion, `task.generatedTeam` is set and the engine proceeds with the new team.
extension NTMSOrchestrator {

    /// Checks if the given task uses the Generated Team template and hasn't generated a team yet.
    func needsTeamGeneration(taskID: Int) -> Bool {
        guard let task = loadedTask(taskID) else { return false }
        guard task.generatedTeam == nil else { return false }
        guard let preferredID = task.preferredTeamID,
              let team = workFolder?.team(withID: preferredID) else { return false }
        return team.templateID == "generated"
    }

    /// Runs the team generation flow for a task. Creates a Supervisor step with a
    /// `create_team` tool call (isAnalyzing-style placeholder), calls `TeamGenerationService`,
    /// and updates the tool call + sets `task.generatedTeam` when done.
    ///
    /// Returns `true` on success (team generated and set on the task), `false` on failure.
    @discardableResult
    func runTeamGeneration(taskID: Int) async -> Bool {
        guard let task = loadedTask(taskID) else {
            lastErrorMessage = "Cannot generate team for task \(taskID): task not loaded."
            return false
        }
        let taskDescription = task.effectiveSupervisorBrief

        guard !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorMessage = "Cannot generate a team without a task description."
            return false
        }

        // 1. Create a Supervisor step with the placeholder tool call.
        let stepID = "team_generation_\(UUID().uuidString)"
        let toolCallID = UUID()
        let placeholderArgs = Self.makeGenerationArgsJSON(taskDescription: taskDescription)
        let placeholderResult = Self.makeGeneratingEnvelope()

        let step = StepExecution(
            id: stepID,
            role: .supervisor,
            title: "Generate Team",
            status: .running,
            toolCalls: [
                StepToolCall(
                    id: toolCallID,
                    name: ToolNames.createTeam,
                    argumentsJSON: placeholderArgs,
                    resultJSON: placeholderResult,
                    isError: false
                )
            ]
        )

        await mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.append(step)
            task.runs[ri].updatedAt = MonotonicClock.shared.now()
        }

        // 2. Call TeamGenerationService in the background.
        let generationResult: Result<GeneratedTeamBuilder.BuildResult, Error>
        do {
            let buildResult = try await TeamGenerationService.generate(
                taskDescription: taskDescription,
                config: globalLLMConfig
            )
            generationResult = .success(buildResult)
        } catch {
            generationResult = .failure(error)
        }

        // 3. Update the tool call + set task.generatedTeam on success.
        switch generationResult {
        case .success(let buildResult):
            let team = buildResult.team
            let successEnvelope = Self.makeSuccessEnvelope(team: team, warnings: buildResult.warnings)
            await mutateTask(taskID: taskID) { task in
                guard let ri = task.runs.indices.last,
                      let si = task.runs[ri].steps.firstIndex(where: { $0.id == stepID })
                else { return }
                if let ti = task.runs[ri].steps[si].toolCalls.firstIndex(where: { $0.id == toolCallID }) {
                    task.runs[ri].steps[si].toolCalls[ti].resultJSON = successEnvelope
                    task.runs[ri].steps[si].toolCalls[ti].isError = false
                }
                task.runs[ri].steps[si].status = .done
                task.runs[ri].steps[si].completedAt = MonotonicClock.shared.now()
                task.runs[ri].steps[si].updatedAt = MonotonicClock.shared.now()

                task.adoptGeneratedTeam(team)

                // Seed role statuses via the shared helper so this code path stays
                // in sync with `GeneratedTeamBuilderTests.testSeedRoleStatuses_*`.
                let producedArtifacts = TaskEngineStoreAdapter.computeProducedArtifactNames(
                    task: task, run: task.runs[ri]
                )
                GeneratedTeamBuilder.seedRoleStatuses(
                    for: team,
                    existingRun: &task.runs[ri],
                    producedArtifacts: producedArtifacts
                )
            }
            if !buildResult.warnings.isEmpty {
                lastInfoMessage = buildResult.warnings.joined(separator: " ")
            }
            return true

        case .failure(let error):
            // Distinguish user-initiated cancellation (pauseRun → cancelTeamGeneration)
            // from genuine failures. On cancellation: mark the step `.paused` so a
            // subsequent resume/retry can continue, and skip `lastErrorMessage` so
            // the user isn't shown an error banner for an action they took themselves.
            let isCancellation = Self.isCancellationError(error)
            let message = isCancellation
                ? "Team generation was cancelled"
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let errorEnvelope = Self.makeErrorEnvelope(message: message)
            await mutateTask(taskID: taskID) { task in
                guard let ri = task.runs.indices.last,
                      let si = task.runs[ri].steps.firstIndex(where: { $0.id == stepID })
                else { return }
                if let ti = task.runs[ri].steps[si].toolCalls.firstIndex(where: { $0.id == toolCallID }) {
                    task.runs[ri].steps[si].toolCalls[ti].resultJSON = errorEnvelope
                    task.runs[ri].steps[si].toolCalls[ti].isError = true
                }
                task.runs[ri].steps[si].status = isCancellation ? .paused : .failed
                task.runs[ri].steps[si].completedAt = MonotonicClock.shared.now()
                task.runs[ri].steps[si].updatedAt = MonotonicClock.shared.now()
                task.runs[ri].updatedAt = MonotonicClock.shared.now()
            }
            if !isCancellation {
                lastErrorMessage = message
            }
            return false
        }
    }

    /// Retries team generation after a previous attempt failed. Removes any prior
    /// generation step from the latest run, then re-runs the generation flow and starts
    /// the engine on success. No-ops when the task isn't using the Generated Team template.
    func retryTeamGeneration(taskID: Int) async {
        // Guard against double-retry (rapid button clicks) and against retry racing
        // a still-in-flight detached generation from `startRun`. Surface a banner
        // so the user understands why the click had no visible effect.
        guard beginTeamGeneration(taskID: taskID) else {
            lastInfoMessage = "Team generation is already in progress."
            return
        }
        defer { endTeamGeneration(taskID: taskID) }

        await mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.removeAll { step in
                step.toolCalls.contains { $0.name == ToolNames.createTeam }
            }
            task.runs[ri].updatedAt = MonotonicClock.shared.now()
        }

        // After cleanup, `needsTeamGeneration` is true again iff the template is
        // "generated" and no team has been adopted — same gate as `startRun`.
        guard needsTeamGeneration(taskID: taskID) else { return }

        let generated = await runTeamGeneration(taskID: taskID)
        guard generated else { return }
        let engine = engineForTask(taskID)
        engine.start()
    }

    /// Saves the generated team to the project (moves from task to teams.json).
    func saveGeneratedTeam(taskID: Int) async {
        guard let task = loadedTask(taskID),
              let team = task.generatedTeam else { return }

        await mutateWorkFolder { proj in
            proj.teams.removeAll { $0.id == team.id }
            proj.teams.append(team)
        }

        await mutateTask(taskID: taskID) { task in
            task.preferredTeamID = team.id
            task.clearGeneratedTeam()
        }

        lastInfoMessage = "Team '\(team.name)' saved"
    }

    // MARK: - Cancellation detection

    /// True for `CancellationError` and for `URLError.cancelled` (which
    /// `URLSession` emits when its streaming task is cancelled mid-request).
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Envelopes

    private static func makeGenerationArgsJSON(taskDescription: String) -> String {
        let payload: [String: Any] = ["task": taskDescription]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private static func makeGeneratingEnvelope() -> String {
        #"{"ok":true,"status":"generating"}"#
    }

    private static func makeSuccessEnvelope(team: Team, warnings: [String] = []) -> String {
        let roleCount = max(0, team.roles.count - 1) // exclude Supervisor
        var data: [String: Any] = [
            "team": team.name,
            "roles": "\(roleCount)",
            "status": "created",
        ]
        if !warnings.isEmpty {
            data["warnings"] = warnings
        }
        let payload: [String: Any] = ["ok": true, "data": data]
        if let blob = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: blob, encoding: .utf8) {
            return str
        }
        return #"{"ok":true}"#
    }

    #if DEBUG
    /// Test accessor — verifies the placeholder envelope string matches the substring
    /// `StepToolCall.isGeneratingTeam` looks for. Without this guard the two strings
    /// (in different files) can drift silently and the graph spinner would never appear.
    static func _testGeneratingEnvelope() -> String { makeGeneratingEnvelope() }
    static func _testSuccessEnvelope(team: Team, warnings: [String] = []) -> String {
        makeSuccessEnvelope(team: team, warnings: warnings)
    }
    static func _testErrorEnvelope(message: String) -> String { makeErrorEnvelope(message: message) }
    #endif

    private static func makeErrorEnvelope(message: String) -> String {
        let payload: [String: Any] = [
            "ok": false,
            "error": ["code": "GENERATION_FAILED", "message": message],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"ok":false}"#
    }
}
