import XCTest
@testable import NanoTeams

@MainActor
final class CreateTeamTrainerTests: XCTestCase {

    /// Reads config from `.nanoteams/create_team_trainer.json` in the project root.
    /// Auto-skips if the config or LLM server is missing.
    func testRunTrainer() async throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // project root

        let configURL = projectRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("create_team_trainer.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[TRAINER] No config at \(configURL.path) — skipping.")
            return
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            CreateTeamTrainerConfig.self, from: configData
        )

        let serverURL = URL(string: config.resolvedBaseURL)!
        let probe = URLRequest(url: serverURL, timeoutInterval: 3)
        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: probe)
            reachable = (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            reachable = false
        }
        guard reachable else {
            print("[TRAINER] LLM server at \(config.resolvedBaseURL) is not reachable — skipping.")
            return
        }

        print("[TRAINER] ==========================================")
        print("[TRAINER] Model: \(config.resolvedModel) @ \(config.resolvedBaseURL)")
        print("[TRAINER] Corpus: \(config.corpusPath)")
        print("[TRAINER] Output: \(config.outputPath)")
        print("[TRAINER] Per-case timeout: \(config.caseTimeoutSeconds ?? 90)s")
        print("[TRAINER] ==========================================")

        let trainer = CreateTeamTrainer(config: config)
        let result = try await trainer.run()

        printSummary(result)

        // Structural invariants — independent of model quality. These catch
        // bugs in the trainer/parser even when every case fails to produce a team.
        let corpus = try JSONCoderFactory.makeWireDecoder().decode(
            CreateTeamTrainerCorpus.self, from: Data(contentsOf: URL(fileURLWithPath: config.corpusPath))
        )
        XCTAssertEqual(
            result.cases.count, corpus.cases.count,
            "Trainer dropped cases — expected \(corpus.cases.count), got \(result.cases.count)."
        )
        for (kase, summary) in zip(corpus.cases, result.cases) {
            XCTAssertEqual(summary.tag, kase.tag, "Case order or tag drift.")
            if case .success(let team) = summary.outcome {
                XCTAssertFalse(team.name.isEmpty, "[\(summary.tag)] generated team has empty name.")
                XCTAssertFalse(team.roles.isEmpty, "[\(summary.tag)] generated team has no roles.")
                XCTAssertGreaterThan(
                    summary.elapsedSeconds, 0,
                    "[\(summary.tag)] elapsedSeconds should be positive on success."
                )
            }
        }

        // Soft signal — most runs should produce at least one team. Failure here
        // usually means the LLM server returned errors for every prompt or the
        // model isn't loaded. This is a model-quality check, not a parser check.
        let anySuccess = result.cases.contains {
            if case .success = $0.outcome { return true }
            return false
        }
        XCTAssertTrue(
            anySuccess,
            "All \(result.cases.count) cases failed — no team was generated. See \(config.outputPath)."
        )
    }

    private func printSummary(_ result: TrainerRunResult) {
        var success = 0, failure = 0, timeout = 0
        var byPath: [TrainerParsingPath: Int] = [:]
        var totalIn = 0, totalOut = 0
        for c in result.cases {
            byPath[c.parsingPath, default: 0] += 1
            totalIn += c.inputTokens ?? 0
            totalOut += c.outputTokens ?? 0
            switch c.outcome {
            case .success: success += 1
            case .failure: failure += 1
            case .timeout: timeout += 1
            }
        }

        let pathSummary = byPath
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: " ")

        print("[TRAINER] ==========================================")
        print("[TRAINER] RESULT: \(success) ok, \(failure) failed, \(timeout) timeout (of \(result.cases.count))")
        print("[TRAINER] Duration: \(Int(result.durationSeconds))s")
        print("[TRAINER] Tokens: \(totalIn) in / \(totalOut) out")
        print("[TRAINER] Parsing: \(pathSummary)")
        print("[TRAINER] ==========================================")
    }
}
