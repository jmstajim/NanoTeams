import XCTest
@testable import NanoTeams

/// XCTest entry point for the expanded-search trainer. Reads config from
/// `.nanoteams/expanded_search_trainer.json` at the project root and writes
/// results to the path the config specifies.
///
/// Auto-skips when the config file is missing or when the LLM server is
/// unreachable — same contract as `CreateTeamTrainerTests` so CI runs are
/// clean even when nobody's touching the trainer.
@MainActor
final class ExpandedSearchTrainerTests: XCTestCase {

    func testRunTrainer() async throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // project root

        let configURL = projectRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("expanded_search_trainer.json")

        // `XCTSkip` rather than silent `return`: a silent return makes a
        // genuinely-broken trainer setup indistinguishable from a benign
        // "trainer not configured" in CI metrics — the test counts as PASS.
        // `HeadlessRunnerTests` and `CreateTeamTrainerTests` use the same
        // pattern; align with it so a missing trainer file consistently shows
        // up in the skip list.
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("No trainer config at \(configURL.path).")
        }

        let configData = try Data(contentsOf: configURL)
        let config = try JSONCoderFactory.makeWireDecoder().decode(
            ExpandedSearchTrainerConfig.self, from: configData
        )

        // Pre-flight the LLM server — skip when unreachable so devs without LM
        // Studio can run the full suite.
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
            throw XCTSkip(
                "LLM server at \(config.resolvedBaseURL) is not reachable — start LM Studio to run the trainer."
            )
        }

        print("[TRAINER] ==========================================")
        print("[TRAINER] Model: \(config.resolvedModel) @ \(config.resolvedBaseURL)")
        print("[TRAINER] Corpus: \(config.corpusPath)")
        print("[TRAINER] Output: \(config.outputPath)")
        print("[TRAINER] Per-case timeout: \(config.caseTimeoutSeconds ?? 60)s")
        print("[TRAINER] ==========================================")

        let trainer = ExpandedSearchTrainer(config: config)
        let result = try await trainer.run()

        printSummary(result)

        // Structural invariants — independent of model quality.
        let corpus = try JSONCoderFactory.makeWireDecoder().decode(
            ExpandedSearchTrainerCorpus.self,
            from: Data(contentsOf: URL(fileURLWithPath: config.corpusPath))
        )
        XCTAssertEqual(
            result.cases.count, corpus.cases.count,
            "Trainer dropped cases — expected \(corpus.cases.count), got \(result.cases.count)."
        )
        for (kase, summary) in zip(corpus.cases, result.cases) {
            XCTAssertEqual(summary.tag, kase.tag, "Case order or tag drift.")
            XCTAssertEqual(summary.query, kase.query)
            XCTAssertGreaterThan(summary.elapsedSeconds, 0,
                "[\(summary.tag)] elapsedSeconds should be positive.")
        }

        // Soft signal — at least one non-adversarial case should expand.
        // Cases with `expectsExpansionFailure: true` are excluded from this
        // check since they're meant to fail.
        let eligible = result.cases.filter { !$0.expansion.expectsFailure }
        if !eligible.isEmpty {
            let anySuccess = eligible.contains {
                if case .success = $0.expansion.outcome { return true }
                return false
            }
            XCTAssertTrue(
                anySuccess,
                "All non-adversarial cases failed — see \(config.outputPath)."
            )
        }
    }

    private func printSummary(_ result: ExpandedSearchTrainerRunResult) {
        var success = 0, failure = 0, timeout = 0
        var totalHits = 0
        var recallBuckets: [Double] = []
        for c in result.cases {
            totalHits += c.posting.hitFiles.count
            if let r = c.expansion.recall { recallBuckets.append(r) }
            switch c.expansion.outcome {
            case .success: success += 1
            case .failure: failure += 1
            case .timeout: timeout += 1
            }
        }
        let avgRecall: Double = recallBuckets.isEmpty
            ? 0
            : recallBuckets.reduce(0, +) / Double(recallBuckets.count)

        print("[TRAINER] ==========================================")
        print("[TRAINER] RESULT: \(success) ok, \(failure) failed, \(timeout) timeout (of \(result.cases.count))")
        print("[TRAINER] Duration: \(Int(result.durationSeconds))s")
        print("[TRAINER] Total hit_files across all cases: \(totalHits)")
        print("[TRAINER] Expansion recall (avg over scored cases): \(Int(avgRecall * 100))%")
        print("[TRAINER] ==========================================")
    }
}
