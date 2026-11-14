import XCTest
@testable import NanoTeams

/// Live entry point for the Autovisor continuation trainer (REC.10).
///
/// Skipped in the ordinary suite (`NanoTeams.xctestplan` `skippedTests`);
/// `./run_autovisor_continuation_trainer.sh <config>` lifts the skip for one run. Reads
/// `.nanoteams/autovisor_continuation_trainer.json` in the project root and auto-skips when
/// the config or the LLM server is missing.
///
/// Everything that can be verified without an LLM server — config decoding, real
/// `PromptBuilder` + `LLMExecutionService.resolveToolSchemas` assembly for all six scenarios,
/// next-turn classification, and a scripted trainer run — lives in
/// `AutovisorContinuationTrainerOfflineTests` and runs on every build.
@MainActor
final class AutovisorContinuationTrainerTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // repo root
    }

    func testRunTrainer() async throws {
        let configURL = Self.repoRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("autovisor_continuation_trainer.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[TRAINER] No config at \(configURL.path) — skipping.")
            return
        }
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            AutovisorContinuationTrainerConfig.self,
            from: Data(contentsOf: configURL)
        )

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
        print("[TRAINER] Variant: \(config.resolvedVariant.rawValue) × \(config.resolvedRuns)")
        print("[TRAINER] Scenarios: \(config.resolvedScenarios.map(\.rawValue).joined(separator: ", "))")
        print("[TRAINER] Output: \(config.outputPath)")
        print("[TRAINER] ==========================================")

        let trainer = AutovisorContinuationTrainer(config: config)
        let result = try await trainer.run()
        Self.printSummary(result)

        let expectedArms = config.resolvedScenarios.reduce(0) { count, scenario in
            let armsForScenario = config.resolvedVariant.activeArms.filter { arm in
                arm != .before || scenario.supportsBeforeArm
            }
            return count + armsForScenario.count
        }
        XCTAssertEqual(
            result.cases.count,
            expectedArms * config.resolvedRuns,
            "Trainer dropped continuation cases."
        )
    }

    private static func printSummary(_ result: AutovisorContinuationTrainerRunResult) {
        print("[TRAINER] ---------- Summary ----------")
        print("[TRAINER] model=\(result.model) mode=\(result.toolCallingMode) promptVersion=\(result.runtimePromptVersion)")
        for scenario in AutovisorContinuationScenario.allCases {
            for arm in AutovisorContinuationArm.allCases {
                let rows = result.cases.filter { $0.scenario == scenario && $0.arm == arm }
                guard !rows.isEmpty else { continue }
                let passed = rows.filter(\.verdict.passed).count
                let repeats = rows.filter(\.repeatedSameAction).count
                let idles = rows.filter(\.wentIdle).count
                let toolsSummary = rows.map { $0.toolNames.joined(separator: "+") }.joined(separator: " | ")
                let avg = rows.map(\.elapsedSeconds).reduce(0, +) / Double(rows.count)
                print(
                    "[TRAINER] \(scenario.rawValue) [\(arm.rawValue)]: "
                    + "\(passed)/\(rows.count) pass, repeats=\(repeats), idle=\(idles), "
                    + "tools=[\(toolsSummary)], sys_chars=\(rows[0].systemPromptChars), "
                    + "avg=\(String(format: "%.1f", avg))s"
                )
            }
        }
        print("[TRAINER] Wall: \(Int(result.elapsedSeconds))s")
    }
}
