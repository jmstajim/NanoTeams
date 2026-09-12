import XCTest
@testable import NanoTeams

/// Live entry point for the `ask_supervisor_form` trainer.
///
/// Skipped in the ordinary suite (`NanoTeams.xctestplan` `skippedTests`);
/// `./run_ask_supervisor_form_trainer.sh <config>` lifts the skip for one run. Reads
/// `.nanoteams/ask_supervisor_form_trainer.json` in the project root and auto-skips when the
/// config or the LLM server is missing.
///
/// The whole class is the live entry point, so the plan can skip it by NAME the way it skips
/// the other three trainers. Everything that can be checked without a server —
/// the classifier over three real field runs, and one full iteration of the trainer itself —
/// lives in `AskSupervisorFormTrainerOfflineTests` and runs on every build.
@MainActor
final class AskSupervisorFormTrainerTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // repo root
    }

    func testRunTrainer() async throws {
        let configURL = Self.repoRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("ask_supervisor_form_trainer.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[TRAINER] No config at \(configURL.path) — skipping.")
            return
        }
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            AskSupervisorFormTrainerConfig.self, from: Data(contentsOf: configURL))

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
        print("[TRAINER] Model: \(config.resolvedModel) @ \(config.resolvedBaseURL)")
        print("[TRAINER] Folder: \(config.projectPath) | Team: \(config.teamTemplate ?? "(active)")")
        print("[TRAINER] Ask: \"\(config.resolvedSupervisorTask)\" × \(config.resolvedRuns)")
        print("[TRAINER] ==========================================")

        let result = try await AskSupervisorFormTrainer(config: config).run()
        Self.printSummary(result)

        // Structural only — the quality is recorded, never asserted, exactly as in the three
        // trainers that came before. A pass/fail on a rate would make the suite red for a
        // model's bad afternoon.
        XCTAssertEqual(result.cases.count, config.resolvedRuns, "Trainer dropped runs.")
        for row in result.cases {
            XCTAssertTrue(row.errors.isEmpty, "[run \(row.run)] \(row.errors.joined(separator: "; "))")
        }
    }

    private static func printSummary(_ result: AskSupervisorFormTrainerRunResult) {
        let summary = result.summary
        print("[TRAINER] ---------- Summary ----------")
        for outcome in Dictionary(grouping: result.cases, by: \.outcome).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("[TRAINER] \(outcome.key.rawValue): \(outcome.value.count)")
        }
        print("[TRAINER] emissions=\(summary.emissions) "
            + "clean-on-first=\(summary.cleanOnFirst)/\(summary.runs) "
            + "parked=\(summary.parked)/\(summary.runs) "
            + "calls-per-park=\(String(format: "%.2f", summary.callsPerPark))")
        print("[TRAINER] shapes: \(summary.shapeCounts.sorted(by: { $0.key < $1.key }))")
        print("[TRAINER] diagnoses: \(summary.diagnosisCounts.sorted(by: { $0.key < $1.key }))")
        print("[TRAINER] Wall: \(Int(result.elapsedSeconds))s")
    }
}
