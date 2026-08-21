import XCTest

@testable import NanoTeams

/// The Runs tab, and the cells both tables now share.
///
/// The tab held strictly MORE than a leaderboard row — the whole `GenerationBenchmarkRun` and the
/// whole `RunSummary` — and drew the least of the three surfaces. These pin what it draws now.
final class BenchmarkRunsTabTests: XCTestCase {

    // MARK: - The shared rate cell

    /// RED: drop the `noValue` guard inside `rateCell` → `~—`, which claims an approximate
    /// measurement of a thing that was never measured.
    func testRateCell_neverDecoratesAnAbsentFigure() {
        let cell = BenchmarkResultsCard.rateCell(rate: nil, approximate: true, tip: "explanation")
        XCTAssertEqual(cell.text, BenchmarkMetricsPolicy.noValue)
        XCTAssertNil(cell.tip, "an explanation of an inference nobody made")
    }

    /// RED: return `tip` unconditionally → every exact figure grows a popover explaining an
    /// approximation it does not have.
    func testRateCell_offersNoExplanationForAnExactFigure() {
        let cell = BenchmarkResultsCard.rateCell(rate: 47, approximate: false, tip: "explanation")
        XCTAssertEqual(cell.text, "47")
        XCTAssertNil(cell.tip)
    }

    /// RED: pass `approximate: false` through to `decorate` → the marker disappears and an
    /// inferred figure reads as a measured one.
    func testRateCell_marksAnInferredFigureAndExplainsIt() {
        let cell = BenchmarkResultsCard.rateCell(rate: 47, approximate: true, tip: "explanation")
        XCTAssertEqual(cell.text, "~47")
        XCTAssertEqual(cell.tip, "explanation")
    }

    // MARK: - Counts that name what went missing

    /// RED: return `"\(priced)"` always → a row built from two runs after five attempts reads
    /// exactly like a row where nothing failed.
    func testRunsCell_namesTheRunsThatProducedNothing() {
        XCTAssertEqual(BenchmarkResultsCard.runsCell(priced: 2, failed: 3), "2 of 5")
    }

    /// The other half, and its own mutation (CLAUDE.md #59): the long form must NOT appear when
    /// nothing failed. RED: always print "N of N" → every healthy row grows noise, and the form
    /// that means "something went wrong" stops meaning anything.
    func testRunsCell_staysBareWhenNothingFailed() {
        XCTAssertEqual(BenchmarkResultsCard.runsCell(priced: 2, failed: 0), "2")
    }

    func testSamplesCell_namesTheVoidedOnes() {
        XCTAssertEqual(BenchmarkResultsCard.samplesCell(usable: 2, voided: 3), "2 of 5")
    }

    func testSamplesCell_staysBareWhenEverySampleCounted() {
        XCTAssertEqual(BenchmarkResultsCard.samplesCell(usable: 5, voided: 0), "5")
    }

    // MARK: - Timestamps

    private static let reference = Date(timeIntervalSince1970: 1_755_000_000)

    /// RED: always include the year → five rows repeat it down the column and the widest
    /// single-line cell in the table gets wider. RED (second): never include it → two runs a year
    /// apart to the minute render identically.
    func testRunTimestamp_showsTheYearOnlyWhenItIsNotTheCurrentOne() {
        let sameYear = BenchmarkResultsCard.runTimestamp(
            Self.reference, now: Self.reference, includingTime: true)
        let yearEarlier = BenchmarkResultsCard.runTimestamp(
            Self.reference.addingTimeInterval(-365 * 24 * 3600),
            now: Self.reference, includingTime: true)
        XCTAssertNotEqual(sameYear, yearEarlier)
        XCTAssertFalse(sameYear.contains("2025"), sameYear)
        XCTAssertFalse(sameYear.contains("2024"), sameYear)
        XCTAssertTrue(yearEarlier.contains("2024") || yearEarlier.contains("2025"), yearEarlier)
    }

    /// The leaderboard's `Last run` cell drops the time; the Runs tab's `Date` keeps it.
    /// RED: ignore `includingTime` → one of the two columns says the wrong thing.
    func testRunTimestamp_omitsTheTimeWhenTheColumnHasNoRoomForIt() {
        let withTime = BenchmarkResultsCard.runTimestamp(
            Self.reference, now: Self.reference, includingTime: true)
        let withoutTime = BenchmarkResultsCard.runTimestamp(
            Self.reference, now: Self.reference, includingTime: false)
        XCTAssertNotEqual(withTime, withoutTime)
        XCTAssertTrue(withTime.count > withoutTime.count, "\(withTime) vs \(withoutTime)")
    }

    /// RED: point the tooltip and the delete button's accessibility label at the abbreviated form
    /// → "Delete the … run from 21 Aug" cannot tell two runs on one day apart.
    func testRunTimestampFull_keepsBothTheDateAndTheTime() {
        let full = BenchmarkResultsCard.runTimestampFull(Self.reference)
        let short = BenchmarkResultsCard.runTimestamp(
            Self.reference, now: Self.reference, includingTime: false)
        XCTAssertNotEqual(full, short)
        XCTAssertTrue(full.count > short.count, full)
    }

    // MARK: - The throttle marker speaks for its own table

    /// RED: return one string for both → a single throttled run claims every run behind the
    /// figure was throttled, on a tab where a row IS one run.
    func testThrottledTooltip_namesWhoseFiguresTheseAre() {
        let aggregate = BenchmarkResultsCard.throttledTooltip(everyContributingRun: true)
        let single = BenchmarkResultsCard.throttledTooltip(everyContributingRun: false)
        XCTAssertNotEqual(aggregate, single)
        XCTAssertTrue(aggregate.contains("Every run"), aggregate)
        XCTAssertTrue(single.hasPrefix("This run"), single)
    }

    /// RED: append the ranking clause unconditionally → the Runs tab promises "ranked last" for a
    /// table that is ordered by date and ranks nothing.
    func testThrottledTooltip_promisesARankingOnlyWhereThereIsOne() {
        XCTAssertTrue(
            BenchmarkResultsCard.throttledTooltip(everyContributingRun: true).contains("ranked"))
        XCTAssertFalse(
            BenchmarkResultsCard.throttledTooltip(everyContributingRun: false).contains("ranked"))
    }

    // MARK: - The endpoint tooltip carries what the abbreviated cell dropped

    /// RED: emit the timestamp unconditionally → the Runs tooltip repeats the Date cell an inch
    /// from the pointer.
    func testEndpointTooltip_disclosesTheLastRunOnlyWhereNoColumnDoes() {
        let bare = BenchmarkResultsCard.endpointTooltip(
            provider: .ollama, endpoint: "http://127.0.0.1:11434/")
        let dated = BenchmarkResultsCard.endpointTooltip(
            provider: .ollama, endpoint: "http://127.0.0.1:11434/", lastMeasured: Self.reference)
        XCTAssertFalse(bare.contains("Most recent run"), bare)
        XCTAssertTrue(dated.contains("Most recent run"), dated)
        XCTAssertTrue(dated.hasPrefix(bare), "the two tooltips disagree on their shared half")
    }

    // MARK: - The Runs tab's headings are a list, and therefore pinnable

    /// The tab's headings used to be string literals inside the Grid, so every pin about naming
    /// and units read `columns` and covered exactly half the screen.
    /// RED: remove `prefillColumn` from `historyColumns` → fails.
    func testHistoryColumns_drawThePrefillTheTabWasMissing() {
        let titles = BenchmarkResultsCard.historyColumns.map(\.title)
        XCTAssertEqual(
            titles,
            ["Date", "Model", "Format", "Quantization", "Generation", "TTFT", "Prefill", "Samples"])
    }

    /// RED: give the Runs prefill heading its own help literal → the two tabs can drift on what
    /// the `~` means, which is the drift `endpointTooltip` was made shared to avoid.
    func testHistoryColumns_reuseTheLeaderboardsSpecsRatherThanCopyingThem() {
        func help(_ title: String) -> String? {
            BenchmarkResultsCard.historyColumns.first { $0.title == title }?.help
        }
        XCTAssertEqual(help("Prefill"), BenchmarkResultsCard.promptHelp)
        XCTAssertEqual(help("TTFT"), BenchmarkResultsCard.firstTokenHelp)
        XCTAssertEqual(help("Format"), BenchmarkResultsCard.formatHelp)
        XCTAssertEqual(help("Quantization"), BenchmarkResultsCard.quantizationHelp)
    }

    /// The one heading the two tabs must NOT share. Same name, same unit, different population:
    /// a median across a model's RUNS versus across ONE run's samples.
    /// RED: point `historyGenerationColumn` at `generationHelp` → the Runs tab claims a median
    /// "across this model's runs" on a row that is one run.
    func testHistoryGeneration_saysWhatItIsAMedianOf() {
        XCTAssertNotEqual(
            BenchmarkResultsCard.historyGenerationColumn.help,
            BenchmarkResultsCard.generationHelp)
        XCTAssertTrue(
            BenchmarkResultsCard.historyGenerationColumn.help.contains("THIS RUN"),
            BenchmarkResultsCard.historyGenerationColumn.help)
        XCTAssertTrue(
            BenchmarkResultsCard.generationHelp.contains("across this model's runs"),
            "the leaderboard's wording moved; this pin no longer contrasts anything")
    }

    /// RED: ship a Runs heading with an empty or one-word help → the tab goes back to headings
    /// that explain nothing.
    func testHistoryColumns_everyHeadingExplainsItself() {
        for column in BenchmarkResultsCard.historyColumns {
            XCTAssertGreaterThan(
                column.help.count, 40, "\(column.title) has no real explanation")
        }
    }

    /// RED: return `"\(title) ▼"` for a nil sort → `Date` grows an arrow that clicking cannot
    /// change, which is a control lying about being one.
    func testUnsortableHeadingsNeverGrowASortArrow() {
        XCTAssertNil(BenchmarkResultsCard.dateColumn.column)
        XCTAssertNil(BenchmarkResultsCard.samplesColumn.column)
        XCTAssertEqual(
            BenchmarkResultsCard.headerLabel(
                "Date", column: nil, sortColumn: .generation, descending: true),
            "Date")
    }

    /// The `Last run` column exists so `SortColumn.lastMeasured` is reachable at all.
    /// RED: remove it from `columns` → `testColumns_areOneEachAndUniquelyTitled` goes red, which
    /// is the pin this one exists to keep honest.
    func testLastRunColumn_isTheHeadingThatMakesRecencySortable() {
        XCTAssertEqual(BenchmarkResultsCard.lastRunColumn.column, .lastMeasured)
        XCTAssertTrue(BenchmarkResultsCard.columns.contains { $0.column == .lastMeasured })
        XCTAssertTrue(
            BenchmarkResultsCard.defaultDescending(for: .lastMeasured),
            "the most recent run should be the first answer to \"how stale is this\"")
    }

    // MARK: - The sweep row states its provenance too

    private static func summary(
        rate: Double?, source: GenerationRateSource?
    ) -> BenchmarkMetricsPolicy.RunSummary {
        BenchmarkMetricsPolicy.RunSummary(
            generationTokensPerSecond: rate,
            generationRateSource: source,
            usableCount: 5,
            voidedCount: 0)
    }

    /// The sweep card passed a literal `approximate: false`, on the one screen that measures a
    /// dozen unfamiliar models back to back — so a rate the app timed itself shipped looking
    /// exactly like one the server measured.
    /// RED: restore `approximate: false` in `BenchmarkSweepCard.detail(for:targetPhase:)` → fails.
    func testSweepDetail_marksAClientTimedRate() {
        let text = BenchmarkSweepCard.detail(
            for: .measured(Self.summary(rate: 32, source: .clientWindow)), targetPhase: .idle)
        XCTAssertEqual(text, "~32 tok/s")
    }

    /// The mirror, with its own mutation (CLAUDE.md #59): a server-measured rate must NOT be
    /// marked, or the marker stops distinguishing anything.
    func testSweepDetail_leavesAServerMeasuredRateUnmarked() {
        let text = BenchmarkSweepCard.detail(
            for: .measured(Self.summary(rate: 32, source: .serverDecodeWindow)),
            targetPhase: .idle)
        XCTAssertEqual(text, "32 tok/s")
    }

    /// An unknown source reads as approximate — the same rule `RunSummary` already applies, and
    /// the case that arises when a run's samples disagreed about where their figure came from.
    /// RED: `source?.isApproximate ?? false` → an unlabelled mixture is taken at face value.
    func testSweepDetail_treatsAnUnknownSourceAsApproximate() {
        let text = BenchmarkSweepCard.detail(
            for: .measured(Self.summary(rate: 32, source: nil)), targetPhase: .idle)
        XCTAssertEqual(text, "~32 tok/s")
    }

    /// A run that recorded samples but produced no rate is still a recorded run, not a failure —
    /// and a dash must not be decorated with a unit or a marker.
    func testSweepDetail_printsARecordedRunThatProducedNoRateAsADash() {
        let text = BenchmarkSweepCard.detail(
            for: .measured(Self.summary(rate: nil, source: nil)), targetPhase: .idle)
        XCTAssertEqual(text, BenchmarkMetricsPolicy.noValue)
    }
}
