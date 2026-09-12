import Foundation
@testable import NanoTeams

// MARK: - Results

struct AskSupervisorFormTrainerRunResult: Codable {
    var provider: String
    var baseURL: String
    var model: String
    var team: String
    var supervisorTask: String
    var taskID: Int?
    var startedAt: Date
    var elapsedSeconds: Double
    var cases: [AskSupervisorFormTrainerCaseResult]
    var summary: FormEmissionSummary
}

struct AskSupervisorFormTrainerCaseResult: Codable {
    /// Where the run ended up. Read off the LOG, not off the engine: the engine says only
    /// "waiting for the human", and which of the two ask tools it is waiting on — or whether
    /// it is an approval card waiting instead — is what the measurement is about.
    enum Outcome: String, Codable {
        /// A questionnaire the handler accepted. The outcome the trainer exists to count.
        case parkedOnForm = "parked_on_form"
        /// The model fell back to the plain ask. Not a failure of the run, but it is a form
        /// the human did not get.
        case parkedOnPlainAsk = "parked_on_plain_ask"
        /// Waiting for the human on something that is neither ask — an approval card.
        case parkedOnSomethingElse = "parked_on_something_else"
        /// The run finished or failed without ever parking.
        case gaveUp = "gave_up"
        case timeout
    }

    var run: Int
    var runID: Int?
    var outcome: Outcome
    /// Every form attempt the run made, in order. `attempts == emissions.count`.
    var emissions: [FormEmission]
    var elapsedSeconds: Double
    var errors: [String]
}

// MARK: - Trainer

/// Asks one fixed question N times, each in a fresh run, and scores the questionnaire the
/// model emitted.
///
/// Three decisions are load-bearing and each cost a field run to learn:
///
///  - **Full stack, not the handler.** `MALFORMED_TOOL_CALL` — the outer envelope failing to
///    parse — was 2 of the 7 field emissions, and a harness that hands arguments to
///    `AskSupervisorFormTool` cannot see that layer at all.
///  - **`.manual` supervisor mode.** Under `.autonomous` the auto-answerer replies to the park
///    (`handleSupervisorAutoAnswer` covers the form too) and the step rolls on, so the run has
///    no stopping point and the measurement blurs into whatever came after. Restored at the
///    end, because the folder is the user's.
///  - **Closed after every iteration.** A run left parked keeps its step in
///    `.needsSupervisorInput`, which `NTMSRepository.busyRoleIDs` counts as busy and which
///    therefore DEFERS the next open's bundled-content reconcile — the exact way MeditationApp
///    task 60 measured the old templates on 2026-09-11. `closeTask` finalizes the steps;
///    `startRun` clears `closedAt` again through `createNewRun`.
@MainActor
final class AskSupervisorFormTrainer {

    private let config: AskSupervisorFormTrainerConfig
    private let makeOrchestrator: @MainActor (StoreConfiguration) -> NTMSOrchestrator
    private var orchestrator: NTMSOrchestrator!

    /// - Parameter makeOrchestrator: the orchestrator for this run. `nil` gets the real one — a
    ///   trainer run is SUPPOSED to talk to the configured server; the offline test hands in
    ///   `TestOrchestrator.make` around a scripted client, the same seam `HeadlessRunner` uses.
    init(config: AskSupervisorFormTrainerConfig,
         makeOrchestrator: (@MainActor (StoreConfiguration) -> NTMSOrchestrator)? = nil) {
        self.config = config
        self.makeOrchestrator = makeOrchestrator ?? { configuration in
            // NTMS-ALLOW-REAL-LLM-CLIENT: production-intent driver, as in `HeadlessRunner`.
            NTMSOrchestrator(repository: NTMSRepository(), configuration: configuration)
        }
        // The provenance line carries `runtimePromptVersion` only once the registry has been
        // fingerprinted; unprimed it reads "unprimed", and a measurement of prompts whose own
        // log cannot say WHICH prompts is not a measurement (REC.9).
        RuntimePromptFingerprint.prime()
    }

    /// A FRESH install plus exactly the fields the config names — never `UserDefaults.standard`.
    /// The test host is `NanoTeams.app` itself, so the default storage is the developer's live
    /// app preferences: a trainer reading them would measure under whatever was last picked in
    /// Settings and would write seven fields back through `didSet` (the same trap
    /// `HeadlessRunner.makeConfiguration` was built to close, 2026-09-07).
    static func makeConfiguration(config: AskSupervisorFormTrainerConfig) -> StoreConfiguration {
        let configuration = StoreConfiguration(storage: InMemoryConfigurationStorage())
        configuration.llmProvider = config.resolvedProvider
        configuration.llmBaseURLString = config.resolvedBaseURL
        configuration.llmModelName = config.resolvedModel
        // `tool_calls.jsonl` IS the measurement, so this is not optional decoration.
        configuration.loggingEnabled = true
        configuration.roleConcurrencyMode = .providerLimited
        return configuration
    }

    func run() async throws -> AskSupervisorFormTrainerRunResult {
        let started = Date()
        let configuration = Self.makeConfiguration(config: config)
        orchestrator = makeOrchestrator(configuration)

        let projectURL = URL(fileURLWithPath: config.projectPath)
        await orchestrator.openWorkFolder(projectURL)
        if let error = orchestrator.lastErrorMessage {
            throw TrainerError.openFailed(error)
        }

        let teamName = await selectTeam()
        // Restored on every exit including the throwing one — the folder belongs to the user,
        // and a trainer that leaves a team on a mode nobody chose has changed the thing it was
        // measuring. `defer` cannot do it: the restore is `async`.
        let previousMode = await setSupervisorMode(.manual)

        let taskID: Int
        let cases: [AskSupervisorFormTrainerCaseResult]
        do {
            guard let created = await orchestrator.createTask(
                title: config.resolvedTaskTitle, supervisorTask: config.resolvedSupervisorTask)
            else {
                throw TrainerError.taskCreationFailed(orchestrator.lastErrorMessage ?? "unknown")
            }
            taskID = created
            var collected: [AskSupervisorFormTrainerCaseResult] = []
            for iteration in 1 ... config.resolvedRuns {
                let result = await runOnce(iteration: iteration, taskID: taskID, workFolder: projectURL)
                collected.append(result)
                print("[TRAINER] run \(iteration)/\(config.resolvedRuns): \(result.outcome.rawValue), "
                    + "\(result.emissions.count) emission(s), \(Int(result.elapsedSeconds))s")
            }
            cases = collected
        } catch {
            if let previousMode { _ = await setSupervisorMode(previousMode) }
            throw error
        }
        if let previousMode { _ = await setSupervisorMode(previousMode) }

        let result = AskSupervisorFormTrainerRunResult(
            provider: config.resolvedProvider.rawValue,
            baseURL: config.resolvedBaseURL,
            model: config.resolvedModel,
            team: teamName,
            supervisorTask: config.resolvedSupervisorTask,
            taskID: taskID,
            startedAt: started,
            elapsedSeconds: Date().timeIntervalSince(started),
            cases: cases,
            summary: FormEmissionClassifier.summarize(cases.map(\.emissions)))
        try write(result)
        return result
    }

    // MARK: - One iteration

    private func runOnce(iteration: Int, taskID: Int, workFolder: URL) async
        -> AskSupervisorFormTrainerCaseResult
    {
        let started = Date()
        var errors: [String] = []

        // `startRun` materializes a new run through `createNewRun` before launching, so each
        // iteration writes its own `runs/{runID}/tool_calls.jsonl` without a separate call.
        await orchestrator.startRun(taskID: taskID)
        let runID = orchestrator.loadedTask(taskID)?.runs.last?.id

        let stop = await waitForPark(taskID: taskID, started: started)
        _ = await orchestrator.pauseRun(taskID: taskID)

        // The tool-call log is appended from a detached Task, so the last record of a run that
        // has only just parked may not have landed. One short settle beats a missing emission.
        try? await Task.sleep(for: .milliseconds(500))

        var emissions: [FormEmission] = []
        var records: [ToolCallLogRecord] = []
        if let runID {
            do {
                records = try ToolCallLogReader.records(
                    workFolderRoot: workFolder, taskID: taskID, runID: runID)
                emissions = FormEmissionClassifier.emissions(in: records)
            } catch {
                errors.append("tool_calls.jsonl unreadable: \(error)")
            }
        } else {
            errors.append("run was never materialized")
        }

        _ = await orchestrator.closeTask(taskID: taskID)
        // The reason the close is here rather than at the end of the whole measurement
        // (see the type's doc comment). Stated as an assertion the trainer itself reports,
        // so a regression shows up in the results file and not only in the pinned test.
        if let task = orchestrator.loadedTask(taskID) {
            let busy = NTMSRepository.busyRoleIDs(task)
            if !busy.isEmpty {
                errors.append("team still pinned busy after close: \(busy.joined(separator: ", "))")
            }
        }

        return AskSupervisorFormTrainerCaseResult(
            run: iteration,
            runID: runID,
            outcome: outcome(stop: stop, emissions: emissions, records: records),
            emissions: emissions,
            elapsedSeconds: Date().timeIntervalSince(started),
            errors: errors)
    }

    /// How a run stopped. Three ways, and the results file must keep them apart: a run that
    /// finished without asking is a different fact about the prompt than one that was still
    /// working when the clock ran out.
    private enum Stop {
        case parked
        case finished
        case timedOut
    }

    /// Polls until the run is waiting for the human, has finished, or runs out of time.
    private func waitForPark(taskID: Int, started: Date) async -> Stop {
        while Date().timeIntervalSince(started) < config.resolvedRunTimeout {
            switch orchestrator.engineState.taskEngineStates[taskID] ?? .pending {
            case .needsSupervisorInput:
                return .parked
            case .done, .needsAcceptance, .failed:
                return .finished
            case .running, .pending, .paused:
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return .timedOut
    }

    /// What the run did, decided by its own log.
    ///
    /// Log-derived rather than engine-derived so the trainer's verdict and the classifier's
    /// numbers cannot disagree, and so a run recorded in the field can be scored the same way
    /// with no engine at all.
    private func outcome(stop: Stop, emissions: [FormEmission], records: [ToolCallLogRecord])
        -> AskSupervisorFormTrainerCaseResult.Outcome
    {
        // An accepted questionnaire wins over every other reading, including a timeout: the
        // form parked, and whatever the engine did afterwards is a different question.
        if emissions.contains(where: { $0.envelopeParsed && $0.documentAccepted }) {
            return .parkedOnForm
        }
        switch stop {
        case .timedOut: return .timeout
        case .finished: return .gaveUp
        case .parked:
            let askedPlainly = records.contains { record in
                record.toolName == ToolNames.askSupervisor && record.errorMessage == nil
            }
            return askedPlainly ? .parkedOnPlainAsk : .parkedOnSomethingElse
        }
    }

    // MARK: - Folder setup

    /// Selects the configured team and returns the name of the team that will actually run.
    /// `templateID` first, then the display name — the same order and the same reason as
    /// `HeadlessRunner`: the id is the stable identity, and a rename must not silently pick
    /// another team, while the name arm is what lets a folder-local team be measured at all.
    private func selectTeam() async -> String {
        guard let projection = orchestrator.workFolder else { return "—" }
        if let wanted = config.teamTemplate,
           let team = projection.teams.first(where: { $0.templateID == wanted })
           ?? projection.teams.first(where: { $0.name == wanted }) {
            await orchestrator.switchTeam(to: team.id)
            return team.name
        }
        return projection.activeTeam?.name ?? "—"
    }

    /// Sets the active team's supervisor mode, returning what it was.
    private func setSupervisorMode(_ mode: SupervisorMode) async -> SupervisorMode? {
        let previous = orchestrator.workFolder?.activeTeam?.settings.supervisorMode
        await orchestrator.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == projection.activeTeamID })
            else { return }
            projection.teams[index].settings.supervisorMode = mode
        }
        return previous
    }

    // MARK: - Output

    private func write(_ result: AskSupervisorFormTrainerRunResult) throws {
        let url = URL(fileURLWithPath: config.outputPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoderFactory.makeExportEncoder().encode(result).write(to: url, options: .atomic)
        print("[TRAINER] Results written to \(config.outputPath)")
    }

    enum TrainerError: Error, CustomStringConvertible {
        case openFailed(String)
        case taskCreationFailed(String)

        var description: String {
            switch self {
            case .openFailed(let message): return "openWorkFolder failed: \(message)"
            case .taskCreationFailed(let message): return "createTask failed: \(message)"
            }
        }
    }
}
