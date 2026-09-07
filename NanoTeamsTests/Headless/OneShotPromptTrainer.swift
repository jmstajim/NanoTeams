import Foundation
@testable import NanoTeams

// MARK: - Results

struct OneShotPromptTrainerRunResult: Codable {
    var provider: String
    var baseURL: String
    var model: String
    var visionModel: String
    var runs: Int
    var startedAt: Date
    var elapsedSeconds: Double
    var cases: [OneShotPromptTrainerCaseResult]
}

struct OneShotPromptTrainerCaseResult: Codable {
    var service: OneShotPromptService
    var tag: String
    var run: Int
    var input: String
    /// The reply, capped so a runaway answer cannot bloat the file; the wire log has it whole.
    var output: String
    var elapsedSeconds: Double
    var verdict: OneShotPromptVerdict
}

// MARK: - Trainer

/// Drives every configured one-shot service `runs` times with fixed inputs and records
/// reply + verdict per case. The services are called through their production entry
/// points with a `NetworkLogger` on the output directory, so the wire is the real one.
@MainActor
final class OneShotPromptTrainer {
    let config: OneShotPromptTrainerConfig
    private let client: any LLMClient
    private let logger: NetworkLogger
    private static let outputCap = 2000

    init(config: OneShotPromptTrainerConfig) {
        self.config = config
        client = LLMClientRouter()
        let dir = URL(fileURLWithPath: config.outputPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logger = NetworkLogger(logURL: dir.appendingPathComponent("network_log.jsonl"))
        // The provenance line the logger writes carries `runtimePromptVersion` only once the
        // registry has been fingerprinted. Unprimed it reads "unprimed" — and a measurement
        // of prompts whose own log cannot say WHICH prompts is not a measurement (REC.9).
        RuntimePromptFingerprint.prime()
    }

    func run() async throws -> OneShotPromptTrainerRunResult {
        let started = Date()
        var results: [OneShotPromptTrainerCaseResult] = []
        for service in config.resolvedServices {
            print("[TRAINER] ▶ \(service.rawValue)")
            for run in 1 ... config.resolvedRuns {
                results += await runService(service, run: run)
            }
        }
        let result = OneShotPromptTrainerRunResult(
            provider: config.resolvedProvider.rawValue, baseURL: config.resolvedBaseURL,
            model: config.resolvedModel, visionModel: config.resolvedVisionModel,
            runs: config.resolvedRuns, startedAt: started,
            elapsedSeconds: Date().timeIntervalSince(started), cases: results)
        try write(result)
        return result
    }

    // MARK: Per service

    private func runService(_ service: OneShotPromptService, run: Int) async -> [OneShotPromptTrainerCaseResult] {
        switch service {
        case .bashJudge:
            let policy = BashPolicy(mode: .auto, restrictionLevel: .standard)
            let cfg = config.toLLMConfig()
            return await mapCases(OneShotPromptFixtures.bashCommands, service: service, run: run,
                                  tag: \.tag, input: \.command) { [client, logger] c in
                let d = await BashJudgeService.judge(command: c.command, workingDirectory: nil, policy: policy,
                                                     config: cfg, client: client, logger: logger)
                return ("\(d.allowed ? "ALLOW" : "DENY") — \(d.reason)",
                        OneShotPromptVerdicts.judge(expectedAllowed: c.expectedAllowed, allowed: d.allowed, reason: d.reason))
            }
        case .computerUseJudge:
            let policy = ComputerUsePolicy(mode: .auto, restrictionLevel: .standard)
            let cfg = config.toLLMConfig()
            return await mapCases(OneShotPromptFixtures.computerUseActions, service: service, run: run,
                                  tag: \.tag, input: { $0.action.detail }) { [client, logger] c in
                let d = await ComputerUseJudgeService.judge(action: c.action, context: c.context, policy: policy,
                                                            config: cfg, client: client, logger: logger)
                return ("\(d.allowed ? "ALLOW" : "DENY") — \(d.reason)",
                        OneShotPromptVerdicts.judge(expectedAllowed: c.expectedAllowed, allowed: d.allowed, reason: d.reason))
            }
        case .bashExplain:
            let policy = BashPolicy(mode: .semiAutomatic, restrictionLevel: .standard)
            let cfg = config.toLLMConfig()
            return await mapCases(OneShotPromptFixtures.explainCommands, service: service, run: run,
                                  tag: \.tag, input: \.command) { [client, logger] c in
                let text = await BashExplainService.explain(command: c.command, workingDirectory: nil, policy: policy,
                                                            config: cfg, client: client, logger: logger)
                return (text, OneShotPromptVerdicts.explain(text))
            }
        case .promptImprovement:
            let cfg = config.toLLMConfig()
            let prompt = OneShotPromptFixtures.improvementPrompt
            return await mapCases([("calculator", prompt)], service: service, run: run,
                                  tag: \.0, input: \.1) { [client, logger] _ in
                let text = try await PromptImprovementService.improve(prompt: prompt, config: cfg,
                                                                      client: client, logger: logger)
                return (text, OneShotPromptVerdicts.improvement(original: prompt, rewritten: text))
            }
        case .vision:
            let cfg = config.toVisionConfig()
            return await mapCases([("red-circle", OneShotPromptFixtures.visionPrompt)], service: service, run: run,
                                  tag: \.0, input: \.1) { [client, logger] c in
                let png = try OneShotPromptFixtures.visionImagePNG()
                let text = try await VisionAnalysisService.analyze(
                    prompt: c.1, imageBase64: png.base64EncodedString(), mimeType: "image/png",
                    config: cfg, client: client, logger: logger)
                return (text, OneShotPromptVerdicts.vision(text, expectedTerms: OneShotPromptFixtures.visionExpectedTerms))
            }
        case .workFolderContext:
            let cfg = config.toLLMConfig()
            let scratch = config.workFolderPath == nil ? try? OneShotPromptFixtures.makeScratchWorkFolder() : nil
            defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
            let root = config.workFolderPath.map { URL(fileURLWithPath: $0) } ?? scratch
            guard let root else {
                return [failed(service: service, tag: "scratch", run: run, input: "-", note: "no work folder")]
            }
            let service_ = WorkFolderContextService(client: client)
            return await mapCases([("scratch", root.path)], service: service, run: run,
                                  tag: \.0, input: \.1) { _ in
                let text = try await service_.generate(workFolderRoot: root, config: cfg)
                return (text ?? "", OneShotPromptVerdicts.workFolderContext(text))
            }
        case .supervisorAutoAnswer:
            let cfg = config.toLLMConfig()
            let task = NTMSTask(
                id: 1, title: "Calculator app",
                supervisorTask: "Build a calculator app with basic arithmetic and a simple history view",
                runs: [Run(id: 0, steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "Software Engineer",
                                                        expectedArtifacts: ["Engineering Notes"], status: .running)])])
            let question = OneShotPromptFixtures.autoAnswerQuestion
            return await mapCases([("history", question)], service: service, run: run,
                                  tag: \.0, input: \.1) { [client, logger] _ in
                let text = await SupervisorAutoAnswerService.generateAnswer(
                    question: question, task: task, runIndex: 0, stepIndex: 0, client: client, config: cfg,
                    artifactReader: { _ in nil }, logger: logger)
                return (text ?? "", OneShotPromptVerdicts.autoAnswer(text))
            }
        }
    }

    // MARK: Plumbing

    private func mapCases<C>(
        _ cases: [C], service: OneShotPromptService, run: Int,
        tag: (C) -> String, input: (C) -> String,
        body: @escaping @MainActor @Sendable (C) async throws -> (String, OneShotPromptVerdict)
    ) async -> [OneShotPromptTrainerCaseResult] where C: Sendable {
        var out: [OneShotPromptTrainerCaseResult] = []
        for c in cases {
            let started = Date()
            let outcome = await withTimeout(seconds: config.resolvedCaseTimeout) {
                do { return try await body(c) } catch {
                    return ("error: \(error)", OneShotPromptVerdict(passed: false, note: "\(type(of: error))", flags: [.error]))
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            let (output, verdict) = outcome
                ?? ("", OneShotPromptVerdict(passed: false, note: "timeout after \(Int(elapsed))s", flags: [.timeout]))
            print("[TRAINER]   \(verdict.passed ? "PASS" : "FAIL") \(service.rawValue)/\(tag(c)) run \(run) — \(verdict.note) (\(Int(elapsed))s)")
            out.append(OneShotPromptTrainerCaseResult(
                service: service, tag: tag(c), run: run, input: input(c),
                output: String(output.prefix(Self.outputCap)), elapsedSeconds: elapsed, verdict: verdict))
        }
        return out
    }



    private func failed(service: OneShotPromptService, tag: String, run: Int, input: String, note: String)
        -> OneShotPromptTrainerCaseResult {
        OneShotPromptTrainerCaseResult(service: service, tag: tag, run: run, input: input, output: "",
                                       elapsedSeconds: 0, verdict: OneShotPromptVerdict(passed: false, note: note, flags: [.error]))
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval, operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func write(_ result: OneShotPromptTrainerRunResult) throws {
        let encoder = JSONCoderFactory.makeExportEncoder()
        let data = try encoder.encode(result)
        try data.write(to: URL(fileURLWithPath: config.outputPath), options: .atomic)
        print("[TRAINER] Results written to \(config.outputPath)")
    }
}
