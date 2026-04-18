import Foundation
@testable import NanoTeams

/// Runs `TeamGenerationService.generateWithDiagnostics(...)` over a corpus and
/// writes a results JSON.
final class CreateTeamTrainer {

    /// Closure form of the generator — the seam that lets unit tests inject a
    /// deterministic stub instead of hitting a live LLM. The `Double?` parameter
    /// carries the first-content deadline so the generator can surface a
    /// reasoning-loop timeout distinct from the overall case timeout.
    typealias Generator = @Sendable (String, LLMConfig, Double?) async -> TeamGenerationService.GenerationOutcome

    private let config: CreateTeamTrainerConfig
    private let generator: Generator

    init(
        config: CreateTeamTrainerConfig,
        generator: @escaping Generator = { task, llm, deadline in
            await TeamGenerationService.generateWithDiagnostics(
                taskDescription: task, config: llm, firstContentDeadlineSeconds: deadline
            )
        }
    ) {
        self.config = config
        self.generator = generator
    }

    func run() async throws -> TrainerRunResult {
        let corpus = try loadCorpus()
        print("[TRAINER] Loaded \(corpus.cases.count) case(s) from \(config.corpusPath)")

        let llmConfig = config.toLLMConfig()
        let timeout = config.resolvedTimeout

        var caseResults: [TrainerCaseResult] = []
        let runStart = MonotonicClock.shared.now()

        for (index, kase) in corpus.cases.enumerated() {
            print("[TRAINER] [\(index + 1)/\(corpus.cases.count)] \(kase.tag): \(kase.task.prefix(80))…")
            let result = await runOneCase(kase: kase, llmConfig: llmConfig, timeout: timeout)
            caseResults.append(result)
            printCaseSummary(result)
        }

        let runResult = TrainerRunResult(
            startedAt: runStart,
            durationSeconds: Date().timeIntervalSince(runStart),
            model: config.resolvedModel,
            baseURL: config.resolvedBaseURL,
            cases: caseResults
        )

        try writeOutput(runResult)
        return runResult
    }

    // MARK: - Per-case execution

    /// Retries up to `maxAttempts` times on failure (decode errors, stream
    /// failures, first-content deadlines). Each attempt runs under its own
    /// `timeout` so a hung attempt doesn't burn the budget for the rest.
    /// Returns the first successful result; otherwise the last attempt's result.
    private func runOneCase(
        kase: CreateTeamTrainerCase,
        llmConfig: LLMConfig,
        timeout: TimeInterval
    ) async -> TrainerCaseResult {
        let maxAttempts = config.resolvedMaxAttempts
        let deadline = config.resolvedFirstContentDeadline
        var lastResult: TrainerCaseResult?
        for attempt in 1...maxAttempts {
            let result = await runOneAttempt(kase: kase, llmConfig: llmConfig, timeout: timeout, firstContentDeadline: deadline, attempt: attempt, totalAttempts: maxAttempts)
            if case .success = result.outcome { return result }
            lastResult = result
        }
        return lastResult ?? failedCaseResult(kase: kase)
    }

    private func runOneAttempt(
        kase: CreateTeamTrainerCase,
        llmConfig: LLMConfig,
        timeout: TimeInterval,
        firstContentDeadline: Double,
        attempt: Int,
        totalAttempts: Int
    ) async -> TrainerCaseResult {
        if totalAttempts > 1 {
            print("[TRAINER]   attempt \(attempt)/\(totalAttempts)")
        }
        let outcome = await withTimeout(seconds: timeout) { [generator] in
            await generator(kase.task, llmConfig, firstContentDeadline)
        }

        guard let outcome else {
            return TrainerCaseResult(
                tag: kase.tag,
                task: kase.task,
                parsingPath: .timeout,
                inputTokens: nil,
                outputTokens: nil,
                elapsedSeconds: timeout,
                rawContentPreview: "",
                rawContentLength: 0,
                warnings: [],
                outcome: .timeout,
                lastArgumentsJSON: nil
            )
        }

        let diag = outcome.diagnostics
        let rawPreview = String(diag.rawContent.prefix(2000))
        let parsingPath = TrainerParsingPath(diag.parsingPath)

        let trainerOutcome: TrainerOutcome
        switch outcome.result {
        case .success(let build):
            trainerOutcome = .success(team: TrainerTeamSummary(team: build.team))
        case .failure(let error):
            trainerOutcome = .failure(
                type: errorTypeName(error),
                message: errorMessage(error)
            )
        }

        let warnings: [String] = {
            if case .success(let build) = outcome.result { return build.warnings }
            return []
        }()

        return TrainerCaseResult(
            tag: kase.tag,
            task: kase.task,
            parsingPath: parsingPath,
            inputTokens: diag.inputTokens,
            outputTokens: diag.outputTokens,
            elapsedSeconds: diag.elapsedSeconds,
            rawContentPreview: rawPreview,
            rawContentLength: diag.rawContent.count,
            warnings: warnings,
            outcome: trainerOutcome,
            lastArgumentsJSON: diag.lastArgumentsJSON.map { String($0.prefix(4000)) }
        )
    }

    private func failedCaseResult(kase: CreateTeamTrainerCase) -> TrainerCaseResult {
        TrainerCaseResult(
            tag: kase.tag,
            task: kase.task,
            parsingPath: .none,
            inputTokens: nil,
            outputTokens: nil,
            elapsedSeconds: 0,
            rawContentPreview: "",
            rawContentLength: 0,
            warnings: [],
            outcome: .failure(type: "GenerationError", message: "No attempts produced a result"),
            lastArgumentsJSON: nil
        )
    }

    /// Returns nil on timeout. Cancels the generation Task on expiry so the LLM
    /// stream stops eating tokens (cooperatively — see `Task.checkCancellation`
    /// inside `generateWithDiagnostics`).
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// `DecodingError` carries the field path that failed — the trainer's whole
    /// purpose is parser auditing, so flattening to `localizedDescription` would
    /// throw away the most useful diagnostic.
    private func errorMessage(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return String(describing: decoding)
        }
        return error.localizedDescription
    }

    private func errorTypeName(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    // MARK: - I/O

    private func loadCorpus() throws -> CreateTeamTrainerCorpus {
        let url = URL(fileURLWithPath: config.corpusPath)
        let data = try Data(contentsOf: url)
        return try JSONCoderFactory.makeWireDecoder().decode(CreateTeamTrainerCorpus.self, from: data)
    }

    private func writeOutput(_ result: TrainerRunResult) throws {
        let url = URL(fileURLWithPath: config.outputPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONCoderFactory.makeExportEncoder().encode(result)
        try data.write(to: url)
        print("[TRAINER] Results → \(url.path)")
    }

    private func printCaseSummary(_ r: TrainerCaseResult) {
        let tokensIn = r.inputTokens.map(String.init) ?? "?"
        let tokensOut = r.outputTokens.map(String.init) ?? "?"
        switch r.outcome {
        case .success(let team):
            let warn = r.warnings.isEmpty ? "" : " warnings=\(r.warnings.count)"
            print("[TRAINER]   ✓ OK   parsing=\(r.parsingPath.rawValue) tokens=\(tokensIn)/\(tokensOut) team='\(team.name)' roles=\(team.roles.count) artifacts=\(team.artifacts.count) chatMode=\(team.isChatMode)\(warn)")
        case .failure(let type, let message):
            print("[TRAINER]   ✗ FAIL parsing=\(r.parsingPath.rawValue) tokens=\(tokensIn)/\(tokensOut) error=\(type): \(message.prefix(120))")
        case .timeout:
            print("[TRAINER]   ✗ TIMEOUT after \(Int(r.elapsedSeconds))s")
        }
    }
}

// MARK: - Parsing path (extends ParsingPath with a .timeout sentinel)

enum TrainerParsingPath: String, Codable {
    case toolCall = "tool_call"
    case harmony
    case jsonExtract = "json_extract"
    case none
    case timeout

    init(_ servicePath: TeamGenerationService.GenerationDiagnostics.ParsingPath) {
        switch servicePath {
        case .toolCall: self = .toolCall
        case .harmony: self = .harmony
        case .jsonExtract: self = .jsonExtract
        case .none: self = .none
        }
    }
}

// MARK: - Outcome (sum type — illegal combinations unrepresentable)

enum TrainerOutcome: Codable {
    case success(team: TrainerTeamSummary)
    case failure(type: String, message: String)
    case timeout

    enum CodingKeys: String, CodingKey {
        case status, team, errorType, errorMessage
    }

    enum Status: String, Codable {
        case success, failure, timeout
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let team):
            try c.encode(Status.success, forKey: .status)
            try c.encode(team, forKey: .team)
        case .failure(let type, let message):
            try c.encode(Status.failure, forKey: .status)
            try c.encode(type, forKey: .errorType)
            try c.encode(message, forKey: .errorMessage)
        case .timeout:
            try c.encode(Status.timeout, forKey: .status)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(Status.self, forKey: .status)
        switch status {
        case .success:
            let team = try c.decode(TrainerTeamSummary.self, forKey: .team)
            self = .success(team: team)
        case .failure:
            let type = try c.decode(String.self, forKey: .errorType)
            let message = try c.decode(String.self, forKey: .errorMessage)
            self = .failure(type: type, message: message)
        case .timeout:
            self = .timeout
        }
    }
}

// MARK: - Result Models

struct TrainerRunResult: Codable {
    var startedAt: Date
    var durationSeconds: Double
    var model: String
    var baseURL: String
    var cases: [TrainerCaseResult]
}

struct TrainerCaseResult: Codable {
    var tag: String
    var task: String
    var parsingPath: TrainerParsingPath
    var inputTokens: Int?
    var outputTokens: Int?
    var elapsedSeconds: Double
    var rawContentPreview: String
    var rawContentLength: Int
    var warnings: [String]
    var outcome: TrainerOutcome
    /// The arguments JSON that was passed to `decodeTeamConfig` on the last parsing
    /// attempt — populated by `TeamGenerationService.GenerationDiagnostics` so the
    /// trainer can diff what the parser extracted vs. what the LLM emitted. Only
    /// the last attempt is preserved; trimmed to 4000 chars for log sanity.
    var lastArgumentsJSON: String?
}

struct TrainerTeamSummary: Codable {
    var name: String
    var description: String
    var isChatMode: Bool
    var supervisorMode: String
    var acceptanceMode: String
    var supervisorRequires: [String]
    var roles: [TrainerRoleSummary]
    var artifacts: [TrainerArtifactSummary]

    init(team: Team) {
        self.name = team.name
        self.description = team.description
        self.isChatMode = team.isChatMode
        self.supervisorMode = team.settings.supervisorMode.rawValue
        self.acceptanceMode = team.settings.defaultAcceptanceMode.rawValue
        self.supervisorRequires = team.supervisorRequiredArtifacts
        self.roles = team.roles.map(TrainerRoleSummary.init)
        self.artifacts = team.artifacts.map(TrainerArtifactSummary.init)
    }
}

struct TrainerRoleSummary: Codable {
    var name: String
    var completionType: RoleCompletionType
    var requiresArtifacts: [String]
    var producesArtifacts: [String]
    var tools: [String]
    var promptLength: Int

    init(_ role: TeamRoleDefinition) {
        self.name = role.name
        self.completionType = role.completionType
        self.requiresArtifacts = role.dependencies.requiredArtifacts
        self.producesArtifacts = role.dependencies.producesArtifacts
        self.tools = role.toolIDs
        self.promptLength = role.prompt.count
    }
}

struct TrainerArtifactSummary: Codable {
    var name: String
    var description: String
    var icon: String

    init(_ artifact: TeamArtifact) {
        self.name = artifact.name
        self.description = artifact.description
        self.icon = artifact.icon
    }
}
