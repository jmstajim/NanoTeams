import XCTest

@testable import NanoTeams

/// The `~` marker is a property of the FIGURE, not of the table that happens to draw it — so the
/// rule has to hold everywhere a rate is rendered, not wherever someone remembered it.
///
/// It was remembered in one place out of four. `Best run` shipped bare in the cell NEXT to a
/// marked `Generation` holding the same quantity from the same runs, so one leaderboard row read
/// `~47 | 51`. The Runs tab printed a bare `47` for the identical client-timed figure the
/// leaderboard marked `~47`. The sweep card passed a literal `false` on the one screen that
/// measures a dozen unfamiliar models back to back. A guard placed at one of N sites is a
/// coincidence, not a defence (CLAUDE.md #51) — so this pin's scope is every file that renders a
/// rate, with the opt-outs named rather than implied.
final class BenchmarkRateProvenancePinTests: XCTestCase {

    /// Every surface that formats a tokens-per-second figure.
    private static let rateBearingFiles = [
        "BenchmarkResultsCard.swift",
        "BenchmarkSweepCard.swift",
        "BenchmarkSummaryRows.swift",
        "BenchmarkRunDetailSheet+Rows.swift",
    ]

    /// RED: revert the Runs generation cell to `value(BenchmarkMetricsPolicy.formatRate(…))`, or
    /// drop the marker on `Best run` → either one puts the bare shape back and fails here.
    func testNoRateIsRenderedWithoutItsProvenance() throws {
        for file in Self.rateBearingFiles {
            let code = try Self.strippedSource(file)
            // Anti-vacuum first: a stripper that ate the file, or a renamed formatter, would make
            // every assertion below pass by describing nothing (CLAUDE.md #104).
            XCTAssertTrue(
                code.contains("BenchmarkMetricsPolicy.formatRate("),
                "\(file) no longer formats a rate at all — this pin has stopped covering it")
            XCTAssertFalse(
                code.contains("value(BenchmarkMetricsPolicy.formatRate("),
                "\(file) renders a rate straight into a cell, with no way to mark it approximate")
        }
    }

    /// The other half of the same property, and a separate pin because a single mutation must not
    /// be able to satisfy both (CLAUDE.md #60): a call may wrap the figure correctly and still
    /// hard-code the answer.
    ///
    /// Scoped to calls that actually format a RATE. `approximate: false` is legitimate beside
    /// `formatDuration` and `formatShare` — a TTFT the app timed itself and a percentage of a
    /// count have no source to be uncertain about.
    /// RED: restore `approximate: false` in `BenchmarkSweepCard.detail(for:targetPhase:)` → fails.
    func testNoDecoratedRateClaimsExactnessWithALiteral() throws {
        var checked = 0
        for file in Self.rateBearingFiles {
            let code = try Self.strippedSource(file)
            for body in RatchetSourceScan.argumentLists(after: "decorate(", in: code)
                where body.contains("formatRate(") {
                checked += 1
                XCTAssertFalse(
                    body.contains("approximate: false"),
                    "\(file) hard-codes a rate as exact: \(body)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            checked, 3, "the scanner matched almost no decorate() calls — it is measuring itself")
    }

    /// The wiring, not the callee. Asserting that `rateCell` marks an approximate figure would be
    /// vacuous here: the change under test is whether the Runs table CALLS it (CLAUDE.md #57).
    /// RED: delete the prefill cell from `historyTable` → fails.
    func testTheRunsTableAsksForBothItsRatesThroughTheSharedCell() throws {
        let code = try Self.strippedSource("BenchmarkResultsCard.swift")
        let table = try XCTUnwrap(
            RatchetSourceScan.functionBody(after: "private func historyTable(", in: code))
        XCTAssertTrue(
            table.contains("historyHeader(Self.dateColumn)"),
            "the scanner did not find the Runs table at all")
        XCTAssertTrue(
            table.contains("prefillTokensPerSecond"),
            "the Runs table no longer draws prefill — the column the user asked for")
        XCTAssertTrue(
            table.contains("BenchmarkRunCard.prefillTip"),
            "the Runs prefill cell offers no explanation of its ~")
        XCTAssertTrue(
            table.contains("generationRateIsApproximate"),
            "the Runs generation cell dropped the approximate flag it holds")
        XCTAssertTrue(
            table.contains("wasThrottled"),
            "a run measured while throttled draws identically to a clean one")
    }

    // MARK: - Scanning

    /// Comments stripped: the doc comment above `rateCell` spells the very shapes this scans for,
    /// so a raw read would find the code being right in the prose describing it wrong
    /// (CLAUDE.md #89). Primitives from `RatchetSourceScan` — this suite and its sibling
    /// `BenchmarkRunRowInteractionPinTests` used to hold byte-identical local copies
    /// (CLAUDE.md #51).
    private static func strippedSource(_ name: String) throws -> String {
        let url = RatchetSourceScan.repoRoot
            .appendingPathComponent("NanoTeams/Views/Settings/Benchmark/\(name)")
        return RatchetSourceScan.strippingLineComments(
            try String(contentsOf: url, encoding: .utf8))
    }

}
