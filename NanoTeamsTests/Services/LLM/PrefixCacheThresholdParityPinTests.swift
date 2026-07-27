import XCTest

@testable import NanoTeams

/// `PrefixCachePolicy.minimumLoadMsForReload` and `benchmark_prompt_processing.sh`'s
/// `MODEL_RELOAD_MS` must hold the same number, and that number must still separate the
/// measurement it was derived from.
///
/// The duplication is unavoidable: the harness runs standalone against a live server with the
/// app unbuilt, so it cannot read a Swift `static let`, and a generated include would defeat the
/// point of a script you can copy to another machine. What IS avoidable is silent drift — hence
/// a pin rather than a "keep in sync" comment.
///
/// The two sites want OPPOSITE error directions, which is worth stating: for the harness a false
/// "model_reloaded" only discards a sample while a missed one poisons the baseline, so it would
/// prefer a low threshold; for the app a false positive costs the whole always-on banner, so it
/// prefers a high one. One shared value is defensible only because the measured gap is ~89× wide
/// (25.1 ms warm vs 2236.6 ms cold) and 1000 sits comfortably inside it — which is exactly what
/// `testThresholdSeparatesEveryBaselineSample` re-checks rather than taking on faith.
///
/// House source-pin shape (`PrefixCacheLedgerOwnershipPinTests`): line comments stripped before
/// matching, needles assembled at RUNTIME so this file's own prose cannot satisfy its own scan.
final class PrefixCacheThresholdParityPinTests: XCTestCase {

    // MARK: - Scaffolding

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// Everything before an unquoted `#` — the shell's comment marker.
    private static func strippingShellComments(_ line: String) -> String {
        var out = ""
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for character in line {
            if character == "'", previous != "\\", !inDouble { inSingle.toggle() }
            if character == "\"", previous != "\\", !inSingle { inDouble.toggle() }
            if character == "#", !inSingle, !inDouble { return out }
            out.append(character)
            previous = character
        }
        return out
    }

    private func harnessLines() throws -> [String] {
        let url = repoRoot.appendingPathComponent("benchmark_prompt_processing.sh")
        // The public mirror ships build sources only — no harness there means nothing to
        // drift against; the pin stays armed in the checkout where the harness is edited.
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "benchmark_prompt_processing.sh is not in this checkout — parity pin skipped")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map(Self.strippingShellComments)
    }

    private static var assignmentNeedle: String { "MODEL_RELOAD" + "_MS=" }
    private static var variableNeedle: String { "$reload" + "_ms" }
    private static var voidNeedle: String { "model_" + "reloaded" }

    // MARK: - Parity

    func testTheHarnessAndThePolicyShareOneThreshold() throws {
        let assignments = try harnessLines()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(Self.assignmentNeedle) }

        XCTAssertEqual(
            assignments.count, 1,
            "expected exactly one MODEL_RELOAD_MS assignment, found \(assignments)")

        let raw = assignments[0].dropFirst(Self.assignmentNeedle.count)
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            return XCTFail("MODEL_RELOAD_MS is not a number: \(assignments[0])")
        }
        XCTAssertEqual(
            value, PrefixCachePolicy.minimumLoadMsForReload,
            "the harness produced the baseline the Swift constant is justified by — they cannot "
                + "hold different numbers")
    }

    /// Without this, someone re-inlines the literal, the variable keeps existing, and the test
    /// above passes while meaning nothing.
    func testTheHarnessVoidRuleUsesTheVariableNotALiteral() throws {
        let code = try harnessLines()
        XCTAssertTrue(
            code.contains { $0.contains(Self.variableNeedle) },
            "the void rule must read MODEL_RELOAD_MS, not a hardcoded number")

        let inlined = code.filter { line in
            guard line.contains("load_ms") else { return false }
            // A comparison against a bare number rather than the variable.
            return line.range(of: #"load_ms[^|]*>\s*[0-9]"#, options: .regularExpression) != nil
        }
        XCTAssertTrue(inlined.isEmpty, "load_ms compared against a literal: \(inlined)")
    }

    // MARK: - The constant still fits the measurement

    /// Makes the justification executable, and non-circular in the direction that matters:
    /// lowering the threshold toward the warm band turns the baseline's own ACCEPTED samples
    /// red, because Ollama reports 20-25 ms of bookkeeping on every one of them.
    func testThresholdSeparatesEveryBaselineSample() throws {
        let rows = try baselineRows()
        var accepted = 0
        var reloaded = 0

        for row in rows {
            let load = (row["load_ms"] as? Double) ?? 0
            let void = row["void"] as? String
            if void == Self.voidNeedle {
                reloaded += 1
                XCTAssertGreaterThan(
                    load, PrefixCachePolicy.minimumLoadMsForReload,
                    "a sample the harness voided as a reload must clear the app's threshold too")
            } else if void == nil {
                accepted += 1
                XCTAssertLessThan(
                    load, PrefixCachePolicy.minimumLoadMsForReload,
                    "a sample the harness accepted is a WARM turn — if it clears the threshold, "
                        + "the app banners a cache miss on every one of them")
            }
        }

        XCTAssertGreaterThan(accepted, 40, "baseline too small to prove anything")
        XCTAssertGreaterThan(reloaded, 0, "baseline contains no real reload to separate against")
    }

    private func baselineRows() throws -> [[String: Any]] {
        let url = repoRoot.appendingPathComponent("bench_baseline/results.jsonl")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "bench_baseline/results.jsonl is not in this checkout — parity pin skipped")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
    }

    func testThePinIsNotVacuous() throws {
        let code = try harnessLines()
        XCTAssertGreaterThan(code.count, 40, "harness did not parse")
        XCTAssertTrue(
            code.contains { $0.contains(Self.voidNeedle) },
            "the void reason this pin is about is gone — the pin now proves nothing")
        XCTAssertGreaterThan(try baselineRows().count, 40, "baseline did not parse")
    }
}
