import XCTest
@testable import NanoTeams

/// Live entry point for the one-shot prompt trainer. Skipped in the ordinary suite
/// (`NanoTeams.xctestplan` `skippedTests`); `./run_one_shot_prompt_trainer.sh <config>` lifts
/// the skip for one run. Reads `.nanoteams/one_shot_prompt_trainer.json` in the project
/// root and auto-skips when the config or the LLM server is missing.
@MainActor
final class OneShotPromptTrainerTests: XCTestCase {
    func testRunTrainer() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // project root
        let configURL = projectRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("one_shot_prompt_trainer.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[TRAINER] No config at \(configURL.path) — skipping.")
            return
        }
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            OneShotPromptTrainerConfig.self, from: Data(contentsOf: configURL))

        let probe = URLRequest(url: URL(string: config.resolvedBaseURL)!, timeoutInterval: 3)
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
        print("[TRAINER] Model: \(config.resolvedModel) (vision: \(config.resolvedVisionModel)) @ \(config.resolvedBaseURL)")
        print("[TRAINER] Services: \(config.resolvedServices.map(\.rawValue).joined(separator: ", ")) × \(config.resolvedRuns)")
        print("[TRAINER] Output: \(config.outputPath)")
        print("[TRAINER] ==========================================")

        let trainer = OneShotPromptTrainer(config: config)
        let result = try await trainer.run()
        printSummary(result)

        // Structural invariants — independent of model quality.
        let expected = config.resolvedServices.reduce(0) { $0 + OneShotPromptFixtures.cases(for: $1).count }
            * config.resolvedRuns
        XCTAssertEqual(result.cases.count, expected, "Trainer dropped cases.")

        // The fail-closed half of both judges is a safety property, not a quality signal:
        // a deny-worthy input that was allowed fails the run.
        let denyWorthy = Set(OneShotPromptFixtures.bashCommands.filter { !$0.expectedAllowed }.map(\.tag))
            .union(OneShotPromptFixtures.computerUseActions.filter { !$0.expectedAllowed }.map(\.tag))
        for c in result.cases where (c.service == .bashJudge || c.service == .computerUseJudge) && denyWorthy.contains(c.tag) {
            XCTAssertTrue(c.verdict.passed, "[\(c.service.rawValue)/\(c.tag) run \(c.run)] \(c.verdict.note)")
        }
    }

    private func printSummary(_ result: OneShotPromptTrainerRunResult) {
        print("[TRAINER] ---------- Summary ----------")
        for service in OneShotPromptService.allCases {
            let rows = result.cases.filter { $0.service == service }
            guard !rows.isEmpty else { continue }
            let passed = rows.filter(\.verdict.passed).count
            let flags = rows.flatMap(\.verdict.flags).map(\.rawValue)
            let flagText = flags.isEmpty ? "" : " flags: \(Dictionary(grouping: flags, by: { $0 }).mapValues(\.count))"
            let avg = rows.map(\.elapsedSeconds).reduce(0, +) / Double(rows.count)
            print("[TRAINER] \(service.rawValue): \(passed)/\(rows.count) passed, avg \(String(format: "%.1f", avg))s\(flagText)")
        }
        print("[TRAINER] Wall: \(Int(result.elapsedSeconds))s")
    }
}
