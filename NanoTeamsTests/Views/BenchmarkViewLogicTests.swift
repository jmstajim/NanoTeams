import SwiftUI
import XCTest

@testable import NanoTeams

/// Pure presentation helpers of the two benchmark cards.
///
/// `@MainActor` because the statics live on `@MainActor` view types, and every test is `async` —
/// a sync test method in a main-actor class is the shape that aborts on CI.
@MainActor
final class BenchmarkViewLogicTests: XCTestCase, @unchecked Sendable {

    // MARK: - Target label

    func testTargetLabel_showsProviderHostAndModel() async {
        let label = BenchmarkRunCard.targetLabel(
            provider: .lmStudio, endpoint: "http://127.0.0.1:1234", modelName: "qwen3.6")
        XCTAssertEqual(label, "LM Studio · 127.0.0.1:1234 · qwen3.6")
    }

    /// RED: rendering an empty model name as an empty segment → produces a trailing "· " that reads
    /// as a truncation rather than as "nothing is selected".
    func testTargetLabel_emptyModel_showsADash() async {
        let label = BenchmarkRunCard.targetLabel(
            provider: .ollama, endpoint: "http://127.0.0.1:11434", modelName: "   ")
        XCTAssertTrue(label.hasSuffix("· —"), label)
    }

    func testTargetLabel_unparseableEndpoint_fallsBackToTheRawString() async {
        let label = BenchmarkRunCard.targetLabel(
            provider: .ollama, endpoint: "not a url", modelName: "m")
        XCTAssertTrue(label.contains("not a url"), label)
    }

    // MARK: - Status

    func testStatusText_namesTheWarmUpExplicitly() async {
        XCTAssertEqual(BenchmarkRunCard.statusText(for: .warmingUp), "Warming up the model…")
    }

    func testStatusText_countsMeasuredSamples() async {
        XCTAssertEqual(
            BenchmarkRunCard.statusText(for: .measuring(sample: 3, of: 5)), "Sample 3 of 5…")
    }

    /// RED: rendering a generic "Failed" → throws away the reason the runner worked out, leaving the
    /// user with a question the record can already answer.
    func testStatusText_failure_surfacesTheReason() async {
        let message = "No usable samples — the server returned an error."
        XCTAssertEqual(BenchmarkRunCard.statusText(for: .failed(message)), message)
    }

    func testIsRunning_isTrueOnlyForTheInFlightPhases() async {
        XCTAssertFalse(BenchmarkRunCard.isRunning(.idle))
        XCTAssertFalse(BenchmarkRunCard.isRunning(.finished))
        XCTAssertFalse(BenchmarkRunCard.isRunning(.failed("x")))
        XCTAssertTrue(BenchmarkRunCard.isRunning(.preparing))
        XCTAssertTrue(BenchmarkRunCard.isRunning(.warmingUp))
        XCTAssertTrue(BenchmarkRunCard.isRunning(.measuring(sample: 1, of: 2)))
    }

    // MARK: - Approximate marker

    /// RED: marking the whole column → would label Ollama's server-measured prefill a guess; marking
    /// none would present LM Studio's fallback as exact.
    func testDecorate_marksOnlyApproximateValues() async {
        XCTAssertEqual(
            BenchmarkRunCard.decorate(value: "1480", unit: "tok/s", approximate: true),
            "~1480 tok/s")
        XCTAssertEqual(
            BenchmarkRunCard.decorate(value: "1480", unit: "tok/s", approximate: false),
            "1480 tok/s")
    }

    /// RED: decorating the "no measurement" dash → produces "~—", which claims an approximate value
    /// where there is none.
    func testDecorate_neverMarksTheEmptyDash() async {
        XCTAssertEqual(BenchmarkRunCard.decorate(value: "—", unit: "tok/s", approximate: true), "—")
    }

    func testPrefillTip_differsPerSource() async {
        let exact = BenchmarkRunCard.prefillTip(for: .serverPromptEval)
        let frames = BenchmarkRunCard.prefillTip(for: .promptProcessingFrames)
        let fallback = BenchmarkRunCard.prefillTip(for: .timeToFirstToken)
        XCTAssertNotEqual(exact, frames)
        XCTAssertNotEqual(frames, fallback)
        XCTAssertTrue(fallback.lowercased().contains("approximate"), fallback)
        XCTAssertFalse(exact.lowercased().contains("approximate"), exact)
    }

    /// An unknown source must read like the fallback, not like an exact measurement.
    func testPrefillTip_nilSource_isTheApproximateWording() async {
        XCTAssertEqual(
            BenchmarkRunCard.prefillTip(for: nil),
            BenchmarkRunCard.prefillTip(for: .timeToFirstToken))
    }

    // MARK: - Notes and footers

    func testVoidedNote_singularAndPlural() async {
        XCTAssertTrue(BenchmarkRunCard.voidedNote(1).hasPrefix("1 sample "))
        XCTAssertTrue(BenchmarkRunCard.voidedNote(3).hasPrefix("3 samples "))
    }

    /// RED: a disabled Run button with no explanation reads as a bug → The footer is where the
    /// hygiene rule becomes visible instead of silent.
    func testFooter_explainsWhyRunIsBlocked() async {
        let blocked = BenchmarkRunCard.footer(blockedBy: .taskRunning)
        XCTAssertTrue(blocked.contains("task is running"), blocked)
        XCTAssertNotEqual(blocked, BenchmarkRunCard.footer(blockedBy: nil))
    }

    /// The two reasons are different situations with different remedies, and the flag they replaced
    /// was passed `hasRunningTasks || isMeasuring` while narrating only the first.
    ///
    /// RED: return one sentence for both → the card says "a task is running" while the thing
    /// actually blocking Run is this screen's own sweep, three lines below, with a Cancel button.
    func testFooter_distinguishesATaskFromTheBenchmarksOwnMeasuring() async {
        let task = BenchmarkRunCard.footer(blockedBy: .taskRunning)
        let measuring = BenchmarkRunCard.footer(blockedBy: .measuring)

        XCTAssertNotEqual(task, measuring)
        XCTAssertTrue(measuring.contains("measurement is already running"), measuring)
        XCTAssertFalse(measuring.contains("task is running"), measuring)
    }

    func testFooter_idle_explainsTheWarmUp() async {
        let idle = BenchmarkRunCard.footer(blockedBy: nil)
        XCTAssertTrue(idle.contains("warm-up"), idle)
    }

    /// The residency pass clears EVERY server the app has an address for, not just the target's,
    /// and the footer is where the user would find that out.
    ///
    /// RED: keep the old wording "every other model on the server" → the prose under-states what a
    /// measurement tool does to the machine, which is worse than saying nothing (CLAUDE.md #55).
    /// Asserted against the claim's own hinge rather than the presence of a word (#61): the point
    /// is that "unloaded" is scoped to every server, not that the string contains "server".
    func testFooter_namesEveryServerItClears_notJustTheTargets() async {
        let idle = BenchmarkRunCard.footer(blockedBy: nil)

        XCTAssertTrue(idle.contains("every server"), idle)
        XCTAssertFalse(idle.contains("on the server"),
                       "the singular scope is the claim this replaced — \(idle)")
    }

    // MARK: - Sorting chrome

    /// RED: showing the indicator on every header, or on none, → leaves the user unable to tell
    /// which column is actually sorting.
    func testHeaderLabel_indicatorOnlyOnTheActiveColumn() async {
        XCTAssertEqual(
            BenchmarkResultsCard.headerLabel(
                "Generation", column: .generation, sortColumn: .generation, descending: true),
            "Generation ▼")
        XCTAssertEqual(
            BenchmarkResultsCard.headerLabel(
                "Generation", column: .generation, sortColumn: .generation, descending: false),
            "Generation ▲")
        XCTAssertEqual(
            BenchmarkResultsCard.headerLabel(
                "TTFT", column: .timeToFirstToken, sortColumn: .generation,
                descending: true),
            "TTFT")
    }

    // MARK: - The columns have to say what they are

    /// Two adjacent columns of bare numbers, both tokens per second, is what "Gen" and "Best" were.
    /// RED: let either explanation drop the word that distinguishes it → the pair becomes
    /// indistinguishable again, which is the defect this replaced.
    func testColumnHelp_separatesTheMedianFromTheBestRun() async {
        let generation = BenchmarkResultsCard.generationHelp
        let best = BenchmarkResultsCard.bestHelp
        XCTAssertTrue(generation.contains("MEDIAN"), generation)
        XCTAssertTrue(best.contains("FASTEST"), best)
        // Each has to name the unit on its own: a reader hovering one column is not shown the
        // other.
        XCTAssertTrue(generation.contains("tokens per second"), generation)
        XCTAssertTrue(best.contains("tokens per second"), best)
        XCTAssertNotEqual(generation, best)
    }

    /// Generation and Prompt are both rates in tok/s and sit two columns apart, so each has to say
    /// which HALF of the request it measures. RED: describe either as just "speed" → the two
    /// numbers read as competing measurements of one thing.
    func testColumnHelp_separatesWritingFromReading() async {
        XCTAssertTrue(BenchmarkResultsCard.generationHelp.contains("WRITES"),
                      BenchmarkResultsCard.generationHelp)
        XCTAssertTrue(BenchmarkResultsCard.promptHelp.contains("READS"),
                      BenchmarkResultsCard.promptHelp)
    }

    /// `Runs` on the leaderboard and `Samples` in the history are different counts, and the help
    /// has to say so — a median over one run must not read as a median over seven.
    func testColumnHelp_runsCountsRunsNotSamples() async {
        let help = BenchmarkResultsCard.runsHelp
        XCTAssertTrue(help.contains("RUNS"), help)
        XCTAssertTrue(help.contains("not how many samples"), help)
    }

    /// Every heading carries one, so a column added later cannot ship with an empty tooltip.
    func testColumnHelp_isNeverEmpty() async {
        for help in [
            BenchmarkResultsCard.modelHelp, BenchmarkResultsCard.providerHelp,
            BenchmarkResultsCard.versionHelp, BenchmarkResultsCard.generationHelp,
            BenchmarkResultsCard.bestHelp, BenchmarkResultsCard.firstTokenHelp,
            BenchmarkResultsCard.promptHelp, BenchmarkResultsCard.runsHelp,
        ] {
            XCTAssertGreaterThan(help.count, 40, help)
        }
    }

    /// RED: one blanket direction → makes the first click on TTFT rank the SLOWEST model first,
    /// which is the opposite of the question that column asks.
    func testDefaultDescending_matchesEachColumnsQuestion() async {
        XCTAssertTrue(BenchmarkResultsCard.defaultDescending(for: .generation))
        XCTAssertTrue(BenchmarkResultsCard.defaultDescending(for: .best))
        XCTAssertFalse(BenchmarkResultsCard.defaultDescending(for: .timeToFirstToken))
        XCTAssertFalse(BenchmarkResultsCard.defaultDescending(for: .model))
    }

    /// Every column must have a documented default; a `default:` arm would silently give a new
    /// column the wrong one.
    func testDefaultDescending_isDefinedForEveryColumn() async {
        for column in BenchmarkLeaderboard.SortColumn.allCases {
            _ = BenchmarkResultsCard.defaultDescending(for: column)
        }
    }

    /// RED: drop the note → runs measured with an older prompt read as lost rather than as
    /// deliberately excluded.
    func testResultsFooter_accountsForRunsExcludedByPromptVersion() async {
        let none = BenchmarkResultsCard.footer(
            mode: .leaderboard, hiddenRunCount: 0, hasRows: true) ?? ""
        let one = BenchmarkResultsCard.footer(
            mode: .leaderboard, hiddenRunCount: 1, hasRows: true) ?? ""
        let many = BenchmarkResultsCard.footer(
            mode: .leaderboard, hiddenRunCount: 4, hasRows: true) ?? ""
        XCTAssertFalse(none.contains("older prompt"), none)
        XCTAssertTrue(one.contains("1 run uses"), one)
        XCTAssertTrue(many.contains("4 runs use"), many)
        XCTAssertTrue(one.contains("Runs only"), one)
    }

    func testResultsFooter_historyMode_saysItShowsEverything() async {
        let text = BenchmarkResultsCard.footer(
            mode: .history, hiddenRunCount: 3, hasRows: true) ?? ""
        XCTAssertTrue(text.contains("Every run"), text)
    }

    /// The footer answers what no single column can: what a row IS, and which of the two rate
    /// columns the ranking uses. RED: cut it to "one row per model and server" → the two adjacent
    /// tok/s columns are again indistinguishable without hovering either.
    func testResultsFooter_leaderboard_namesBothRateColumnsAndWhichOneRanks() async {
        let text = BenchmarkResultsCard.footer(
            mode: .leaderboard, hiddenRunCount: 0, hasRows: true) ?? ""
        XCTAssertTrue(text.contains("Generation"), text)
        XCTAssertTrue(text.contains("Best run"), text)
        XCTAssertTrue(text.contains("median"), text)
        XCTAssertTrue(text.contains("per model and server"), text)
    }

    /// The columns explain themselves on hover; the footer is not a second copy of those
    /// explanations. RED: restore the four-sentence version → this fires, and the paragraph that
    /// gets skipped is back on screen.
    func testResultsFooter_staysShortEnoughToBeRead() async {
        let text = BenchmarkResultsCard.footer(
            mode: .leaderboard, hiddenRunCount: 0, hasRows: true) ?? ""
        XCTAssertLessThan(text.count, 160, "\(text.count) characters: \(text)")
    }

    /// A disabled trash icon with no explanation reads as a bug. RED: drop the measuring help →
    /// the user is left guessing why the control does nothing.
    func testMeasuringHelp_explainsWhyDeletingIsHeldBack() async {
        let text = BenchmarkResultsCard.measuringHelp
        XCTAssertTrue(text.contains("running"), text)
        XCTAssertTrue(text.contains("come back"), text)
    }

    /// The card carries two clear-shaped affordances — the filter's own clear button and the
    /// history's. RED: label the destructive one "Clear" again → one word means both "empty the
    /// search box" and "destroy every measurement".
    func testTheHistoryButtonAndItsConfirmationUseTheSameVerb() async {
        let request = BenchmarkDeletion.everything(
            in: [], currentPromptVersion: BenchmarkPrompt.version)
        XCTAssertTrue(
            BenchmarkDeletion.confirmLabel(for: request).hasPrefix("Delete all"),
            BenchmarkDeletion.confirmLabel(for: request))
        XCTAssertFalse(
            BenchmarkResultsCard.deleteAllHelp.contains("Clear"),
            BenchmarkResultsCard.deleteAllHelp)
    }

    // MARK: - Prompt sheet

    /// RED: type the ceiling into `factsLine` as a literal, then move
    /// `BenchmarkPrompt.maxOutputTokens` → the sheet advertises a cap the runs no longer use.
    func testPromptSheetFacts_carryTheShippedCeilingRatherThanACopyOfIt() async {
        XCTAssertTrue(
            BenchmarkPromptSheet.factsLine.contains("\(BenchmarkPrompt.maxOutputTokens)"),
            BenchmarkPromptSheet.factsLine)
    }

    /// RED: source the length from `canonicalText.count` → the line reports the placeholder
    /// rendering's size instead of a sample's, six characters too many.
    func testPromptSheetFacts_reportTheLengthOfASampleNotOfTheRendering() async {
        XCTAssertTrue(
            BenchmarkPromptSheet.factsLine.contains("\(BenchmarkPrompt.charactersPerSample)"),
            BenchmarkPromptSheet.factsLine)
        XCTAssertFalse(
            BenchmarkPromptSheet.factsLine.contains("\(BenchmarkPrompt.canonicalText.count)"),
            BenchmarkPromptSheet.factsLine)
    }

    /// The strongest facts about this request are the negative ones, and they existed only as a
    /// doc comment until the sheet stated them. RED: delete them → the reader cannot tell whether
    /// the figures include a system prompt or tool schemas.
    func testPromptSheetFacts_nameWhatTheRequestDoesNotCarry() async {
        let facts = BenchmarkPromptSheet.factsLine
        XCTAssertTrue(facts.contains("no system prompt"), facts)
        XCTAssertTrue(facts.contains("no tools"), facts)
        XCTAssertTrue(facts.contains("one user turn"), facts)
    }

    /// One home per fact. RED: paste the marker explanation back into the run card's tip → two
    /// descriptions of one mechanism, and the one that is not beside the text drifts first.
    func testTheMarkerIsExplainedInExactlyOnePlace() async {
        XCTAssertTrue(
            BenchmarkPromptSheet.explanation(for: .prompt)
                .contains(BenchmarkPrompt.noncePlaceholder),
            BenchmarkPromptSheet.explanation(for: .prompt))
        XCTAssertFalse(
            BenchmarkWorkloadSection.promptTip.contains(BenchmarkPrompt.noncePlaceholder),
            BenchmarkWorkloadSection.promptTip)
    }

    /// The tip's remaining job is the version's consequence for the table below it.
    /// RED: drop the comparability sentence → nothing explains why old runs leave the leaderboard.
    func testPromptTip_keepsTheVersionConsequenceItIsTheOnlyHomeFor() async {
        XCTAssertTrue(BenchmarkWorkloadSection.promptTip.contains("comparable"), BenchmarkWorkloadSection.promptTip)
        XCTAssertTrue(BenchmarkWorkloadSection.promptTip.contains("View prompt"), BenchmarkWorkloadSection.promptTip)
    }

    /// RED: return the paragraph regardless of `hasRows` → the card explains a Generation column
    /// that is not on screen, directly under "Nothing to rank".
    func testResultsFooter_isAbsentWhenThereIsNoTable() async {
        XCTAssertNil(
            BenchmarkResultsCard.footer(mode: .leaderboard, hiddenRunCount: 9, hasRows: false))
        XCTAssertNil(BenchmarkResultsCard.footer(mode: .history, hiddenRunCount: 0, hasRows: false))
    }

    /// Deleting the last comparable run leaves runs on record and no rankable row. RED: keep the
    /// single "No results yet. Run the benchmark above" line for that state → the card tells the
    /// user to record a run while holding nine of them, and contradicts its own Runs tab.
    func testEmptyLeaderboardText_distinguishesAnEmptyHistoryFromAnUnrankableOne() async {
        let untouched = BenchmarkResultsCard.emptyLeaderboardText(runCount: 0, hiddenRunCount: 0)
        let allOlder = BenchmarkResultsCard.emptyLeaderboardText(runCount: 9, hiddenRunCount: 9)
        let noSamples = BenchmarkResultsCard.emptyLeaderboardText(runCount: 9, hiddenRunCount: 0)

        XCTAssertEqual(untouched, BenchmarkResultsCard.noResultsYet)
        XCTAssertNotEqual(allOlder, BenchmarkResultsCard.noResultsYet)
        XCTAssertTrue(allOlder.contains("older prompt"), allOlder)
        XCTAssertTrue(allOlder.contains("9"), allOlder)
        XCTAssertTrue(noSamples.contains("usable sample"), noSamples)
        // Both non-empty states must point at the tab that does hold the runs.
        XCTAssertTrue(allOlder.contains("Runs"), allOlder)
        XCTAssertTrue(noSamples.contains("Runs"), noSamples)
    }

    func testEmptyLeaderboardText_singularWhenOneRunIsOnRecord() async {
        let text = BenchmarkResultsCard.emptyLeaderboardText(runCount: 1, hiddenRunCount: 1)
        XCTAssertTrue(text.contains("the one run"), text)
    }

    // MARK: - Copy feedback

    /// RED: set the copied state unconditionally (ignore `setString`'s `Bool`) → the button claims
    /// a success the pasteboard refused, which is the exact defect the feedback exists to prevent.
    func testCopyLabel_hasADistinctWordForEachOutcome() async {
        XCTAssertEqual(BenchmarkPromptSheet.copyLabel(nil), "Copy")
        XCTAssertEqual(BenchmarkPromptSheet.copyLabel(.copied), "Copied")
        XCTAssertEqual(BenchmarkPromptSheet.copyLabel(.failed), "Copy failed")
        XCTAssertEqual(
            Set([
                BenchmarkPromptSheet.copyIcon(nil), BenchmarkPromptSheet.copyIcon(.copied),
                BenchmarkPromptSheet.copyIcon(.failed),
            ]).count, 3)
    }

    /// The non-obvious claim of the request facet, and the only one the facts line cannot make:
    /// these bytes are produced by the code that sends them, not by a description of it.
    /// RED: drop `the runner calls` from the request explanation → the pane reads as a
    /// reconstruction, which is exactly what it is not.
    func testRequestExplanation_saysTheBytesComeFromTheSendingCode() async {
        let text = BenchmarkPromptSheet.explanation(for: .request)
        XCTAssertTrue(text.contains("the runner calls"), text)
    }

    /// The facts line states the negatives once; the explanation must not restate them.
    /// RED: paste them back → two copies of one fact on one screen, and the derived one drifts.
    func testExplanations_doNotRepeatTheFactsLine() async {
        for facet in BenchmarkPromptSheet.Facet.allCases {
            let text = BenchmarkPromptSheet.explanation(for: facet)
            XCTAssertFalse(text.contains("no system prompt"), "\(facet): \(text)")
            XCTAssertFalse(text.contains("no tools"), "\(facet): \(text)")
            XCTAssertLessThan(text.count, 220, "\(facet) explanation is \(text.count) characters")
        }
    }

    /// RED: render the two facets from one explanation → the prompt tab starts describing a JSON
    /// body it does not show, or the request tab explains a marker rule with no bytes to see.
    func testTheTwoFacetsExplainThemselvesDifferently() async {
        XCTAssertNotEqual(
            BenchmarkPromptSheet.explanation(for: .prompt),
            BenchmarkPromptSheet.explanation(for: .request))
    }

    // MARK: - Column naming

    /// The rule the renamed headings exist to satisfy: every column says what quantity it holds,
    /// and an abbreviation is never left to stand alone.
    ///
    /// RED: drop `unit` from `ttftColumn` → "TTFT" ships as a bare four-letter heading, which is
    /// the state this table was reported for.
    func testEveryColumnIsNamedAndAnAbbreviationCarriesItsExpansion() async {
        for column in BenchmarkResultsCard.columns {
            XCTAssertFalse(column.title.isEmpty, "\(column.id) has no title")
            XCTAssertGreaterThan(
                column.help.count, 40, "\(column.id) help is too short to explain anything")
            let isAbbreviation = column.title == column.title.uppercased() && column.title.count <= 5
            guard isAbbreviation else { continue }
            let unit = column.unit ?? ""
            XCTAssertGreaterThan(
                unit.count, column.title.count,
                "\(column.title) is an abbreviation with no expansion under it")
        }
    }

    /// RED: title the column "First token" again → the assertion that the heading is the term the
    /// field actually uses fails. The pair is the point: the acronym is what you can search for,
    /// the line under it is what it means.
    func testTTFTColumn_isNamedAsTheFieldNamesItAndSpellsItOut() async {
        XCTAssertEqual(BenchmarkResultsCard.ttftColumn.title, "TTFT")
        XCTAssertEqual(BenchmarkResultsCard.ttftColumn.unit, "time to first token")
    }

    /// RED: revert the title to "Prompt" → nothing on screen names the phase, and the figure
    /// cannot be matched against llama.cpp's or Ollama's own logs.
    func testPrefillColumn_usesTheFieldsTermAndNamesTheSynonymInItsHelp() async {
        XCTAssertEqual(BenchmarkResultsCard.prefillColumn.title, "Prefill")
        XCTAssertTrue(
            BenchmarkResultsCard.promptHelp.contains("prompt eval"),
            BenchmarkResultsCard.promptHelp)
    }

    /// RED: revert `versionHelp` to "The server's own version string" → the column no longer says
    /// whose version it is, and a reader takes 0.4.21 for the engine's or the model's.
    func testVersionColumn_saysWhoseVersionItIsAndWhoseItIsNot() async {
        XCTAssertEqual(BenchmarkResultsCard.versionColumn.title, "Version")
        let help = BenchmarkResultsCard.versionHelp
        XCTAssertTrue(help.contains("SERVER"), help)
        XCTAssertTrue(help.contains("engine"), help)
        XCTAssertTrue(help.contains("not this app"), help)
    }

    /// RED: point two specs at the same `SortColumn` → the table would draw one heading twice and
    /// silently lose a column, and `id` would collide in any ForEach over these.
    func testColumns_areOneEachAndUniquelyTitled() async {
        let sortColumns = BenchmarkResultsCard.columns.map(\.column)
        XCTAssertEqual(Set(sortColumns).count, sortColumns.count, "a sort column is listed twice")
        let titles = BenchmarkResultsCard.columns.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two columns share a title")
        // Unconditional now. The exemption that stood here read "it is the tie-break the table
        // never draws" — and that was simply untrue: `BenchmarkLeaderboard.sorted` breaks ties on
        // `modelName` then `provider.rawValue` and never consults `lastMeasuredAt`. So a sort case
        // no heading could reach was kept alive by a comment inside the very pin that would
        // otherwise have caught it (CLAUDE.md #79). Every sort column must be reachable.
        // RED: add a case to `SortColumn` without adding a `Column` → red.
        let drawn = Set(sortColumns.compactMap { $0 })
        for sortColumn in BenchmarkLeaderboard.SortColumn.allCases {
            XCTAssertTrue(drawn.contains(sortColumn), "\(sortColumn.rawValue) has no heading")
        }
    }

    // MARK: - How the two values are spelled, whatever draws them

    /// The rule the capsules and both table columns share. RED: uppercase the quantization →
    /// "4BIT" is a spelling no server uses and no reader can search for; stop uppercasing the
    /// format → the sweep list and the table disagree about the same value.
    func testModelDescriptorText_uppercasesFormatAndLeavesQuantizationAlone() async {
        XCTAssertEqual(ModelDescriptorText.format("gguf"), "GGUF")
        XCTAssertEqual(ModelDescriptorText.format("safetensors"), "SAFETENSORS")
        XCTAssertEqual(ModelDescriptorText.quantization("Q4_K_M"), "Q4_K_M")
        XCTAssertEqual(ModelDescriptorText.quantization("nvfp4"), "nvfp4")
    }

    /// Nothing reported is `nil`, and each renderer decides what that looks like — a capsule draws
    /// nothing, a table cell draws a dash. RED: return "" instead → the cell prints an empty
    /// string under a heading, which reads as a rendering fault rather than as "not reported".
    func testModelDescriptorText_absentValueIsNilForBothHalves() async {
        XCTAssertNil(ModelDescriptorText.format(nil))
        XCTAssertNil(ModelDescriptorText.format(""))
        XCTAssertNil(ModelDescriptorText.quantization(nil))
        XCTAssertNil(ModelDescriptorText.quantization(""))
    }

    /// A server answering with blanks reported nothing. RED: drop the trim → an empty capsule
    /// beside the model name, and a cell that is blank while its neighbours print a dash.
    func testModelDescriptorText_whitespaceOnlyIsNothingReported() async {
        XCTAssertNil(ModelDescriptorText.format("   "))
        XCTAssertNil(ModelDescriptorText.quantization(" \n\t "))
        XCTAssertEqual(ModelDescriptorText.format("  gguf  "), "GGUF")
        XCTAssertEqual(ModelDescriptorText.quantization("  4bit "), "4bit")
    }

    /// Format is an initialism (GGUF, MLX) and renders uppercased; quantization is an exact
    /// identifier (`Q4_K_M`, `4bit`) and renders as the server spells it. RED: uppercase both →
    /// "4BIT" is a spelling no server uses and no reader can search for.
    func testModelChips_uppercaseFormatButKeepQuantizationVerbatim() async {
        XCTAssertEqual(
            ModelChips.chips(format: "gguf", quantization: "Q4_K_M").map(\.text),
            ["GGUF", "Q4_K_M"])
        XCTAssertEqual(
            ModelChips.chips(format: "mlx", quantization: "4bit").map(\.text),
            ["MLX", "4bit"])
    }

    /// A missing half is dropped, never dashed: a chip is a claim, and "—" in a capsule reads as
    /// a value the server reported.
    func testModelChips_dropMissingHalvesInsteadOfDashingThem() async {
        XCTAssertEqual(
            ModelChips.chips(format: nil, quantization: "4bit").map(\.text),
            ["4bit"])
        XCTAssertEqual(
            ModelChips.chips(format: "gguf", quantization: nil).map(\.text),
            ["GGUF"])
        XCTAssertTrue(ModelChips.chips(format: nil, quantization: nil).isEmpty)
        XCTAssertTrue(ModelChips.chips(format: "", quantization: "").isEmpty)
    }

    /// The `ForEach` identity is which HALF of the pair a chip is, never its content — two chips
    /// can spell the same text (an `MXFP4` quantization beside a hypothetical `mxfp4` format),
    /// and colliding ids would silently drop one (CLAUDE.md #22).
    func testModelChips_identityIsTheKindNotTheText() async {
        let chips = ModelChips.chips(format: "mxfp4", quantization: "MXFP4")
        XCTAssertEqual(chips.map(\.text), ["MXFP4", "MXFP4"])
        XCTAssertEqual(Set(chips.map(\.id)).count, chips.count, "chip ids collided")
    }

    // MARK: - Where the sweep list's chips come from

    private func benchmarkRun(
        provider: LLMProvider = .lmStudio,
        baseURL: String = "http://127.0.0.1:1234",
        model: String,
        format: String?,
        quantization: String?,
        startedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            startedAt: startedAt,
            provider: provider,
            baseURLString: baseURL,
            modelName: model,
            modelFormat: format,
            quantization: quantization,
            requestTimeoutSeconds: 600,
            promptID: "prose-ru-en",
            promptVersion: BenchmarkPrompt.version,
            repeats: 5,
            thermalState: BenchmarkThermalState.nominal,
            lowPowerMode: false,
            modelWasResident: true,
            appVersion: "1.8.8")
    }

    private func sweepServer(
        _ provider: LLMProvider = .lmStudio,
        baseURL: String = "http://127.0.0.1:1234",
        isIncluded: Bool = true
    ) -> BenchmarkSweepServer {
        BenchmarkSweepServer(
            provider: provider, baseURLString: baseURL, isIncluded: isIncluded)
    }

    /// The point of the whole change: a model nobody has measured is still labelled, because the
    /// scan that listed it already carried its format and quantization.
    /// RED: drop the catalog layer from `badges` → an unmeasured model has no entry at all.
    func testBadges_labelAModelWithNoRunsAtAll() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [],
            servers: [sweepServer()],
            infos: { _ in [.init(name: "qwen3.8-4b", format: "gguf", quantization: "Q4_K_M")] })

        let key = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "qwen3.8-4b")
        XCTAssertEqual(badges[key]?.format, "gguf")
        XCTAssertEqual(badges[key]?.quantization, "Q4_K_M")
    }

    /// On conflict the LIVE answer wins. Observed for real: history says `openai/gpt-oss-20b` is
    /// GGUF, the server now answers `mlx` — the model was re-downloaded in another format. This
    /// list is a list of models about to be LOADED, so it must describe the file that will be
    /// loaded; the leaderboard keeps saying what was measured.
    /// RED: apply the catalog layer BEFORE the history layer → the list reports the stale format.
    func testBadges_liveCatalogWinsOverAConflictingRun() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [benchmarkRun(model: "openai/gpt-oss-20b", format: "gguf", quantization: "MXFP4")],
            servers: [sweepServer()],
            infos: { _ in [.init(name: "openai/gpt-oss-20b", format: "mlx", quantization: "MXFP4")] })

        let key = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234",
            modelName: "openai/gpt-oss-20b")
        XCTAssertEqual(badges[key]?.format, "mlx", "the server's current answer, not the run's")
    }

    /// …and history is the fallback, not dead weight: a server that has stopped answering lists
    /// nothing, and its rows would otherwise look less known than they are.
    /// RED: drop the history layer → a measured model on an unreachable server loses its chips.
    func testBadges_fallBackToHistoryWhenTheCatalogHasNothing() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [benchmarkRun(model: "retired-model", format: "gguf", quantization: "Q8_0")],
            servers: [sweepServer()],
            infos: { _ in [] })

        let key = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234",
            modelName: "retired-model")
        XCTAssertEqual(badges[key]?.format, "gguf")
        XCTAssertEqual(badges[key]?.quantization, "Q8_0")
    }

    /// Within the history layer alone, the NEWEST run wins — a model re-measured after a
    /// re-download must not be described by the older row.
    func testBadges_newestRunWinsWithinTheHistoryLayer() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [
                benchmarkRun(
                    model: "m", format: "gguf", quantization: "Q4_K_M",
                    startedAt: Date(timeIntervalSince1970: 2000)),
                benchmarkRun(
                    model: "m", format: "mlx", quantization: "4bit",
                    startedAt: Date(timeIntervalSince1970: 1000)),
            ],
            servers: [],
            infos: { _ in [] })

        let key = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        XCTAssertEqual(badges[key]?.format, "gguf", "the later run describes the model now")
    }

    /// A server the user switched off is not measured and its models leave the list, so nothing is
    /// labelled from it — and its history entry, which belongs to a row that is not on screen, is
    /// not overwritten by a listing nobody asked for.
    /// RED: drop `where server.isIncluded` → an excluded server's catalog answer overwrites.
    func testBadges_excludedServerContributesNothing() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [benchmarkRun(model: "m", format: "gguf", quantization: "Q4_K_M")],
            servers: [sweepServer(isIncluded: false)],
            infos: { _ in [.init(name: "m", format: "mlx", quantization: "4bit")] })

        let key = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        XCTAssertEqual(badges[key]?.format, "gguf")
    }

    /// Two providers at one address are two rows, because the group key leads with the provider —
    /// the same rule the leaderboard keeps. RED: key on URL+model only → one entry, one lost chip.
    func testBadges_sameModelOnTwoProvidersStaysTwoEntries() async {
        let badges = BenchmarkSweepCard.badges(
            runs: [],
            servers: [
                sweepServer(.lmStudio, baseURL: "http://127.0.0.1:1234"),
                sweepServer(.ollama, baseURL: "http://127.0.0.1:11434"),
            ],
            infos: { server in
                server.provider == .lmStudio
                    ? [.init(name: "qwen3.8-27b", format: "mlx", quantization: "4bit")]
                    : [.init(name: "qwen3.8-27b", format: "safetensors", quantization: "nvfp4")]
            })

        XCTAssertEqual(badges.count, 2)
        XCTAssertEqual(
            badges[BenchmarkLeaderboard.groupKey(
                provider: .ollama, baseURLString: "http://127.0.0.1:11434",
                modelName: "qwen3.8-27b")]?.format,
            "safetensors")
    }

    /// Format and quantization are columns now, so the explanation moved with the value: a
    /// reader who wants to know what SAFETENSORS means hovers the column that holds it.
    /// RED: leave the paragraph in `modelHelp` → two headed columns nothing explains, and the
    /// Model column explaining values it does not contain.
    func testFormatAndQuantizationColumns_carryTheirOwnExplanation() async {
        let format = BenchmarkResultsCard.formatHelp
        XCTAssertTrue(format.contains("VERBATIM"), format)
        XCTAssertTrue(format.contains("LM Studio"), format)
        XCTAssertTrue(format.contains("Ollama"), format)
        XCTAssertTrue(format.contains("safetensors"), format)

        let quantization = BenchmarkResultsCard.quantizationHelp
        XCTAssertTrue(quantization.contains("Q4_K_M"), quantization)
        XCTAssertTrue(quantization.contains("Never normalized"), quantization)

        // Both columns print a dash for a value the server did not report, and both say so — a
        // dash under an unexplained heading is indistinguishable from a rendering fault.
        XCTAssertTrue(format.contains("dash"), format)
        XCTAssertTrue(quantization.contains("dash"), quantization)

        XCTAssertFalse(
            BenchmarkResultsCard.modelHelp.contains("quantization"),
            BenchmarkResultsCard.modelHelp)
    }

    /// The endpoint lost its line under the model name. RED: leave the old sentence in place → the
    /// help promises "the line under the name" on a table that no longer draws one, and a reader
    /// looking for the server looks for a line instead of hovering.
    func testModelHelp_saysWhereTheServerWentInsteadOfPromisingALine() async {
        let help = BenchmarkResultsCard.modelHelp
        XCTAssertTrue(help.contains("model AND server"), help)
        XCTAssertTrue(help.contains("hover"), help)
        XCTAssertFalse(help.contains("line under the name"), help)
    }

    /// A column cell says "not reported" the way every other column in this table says it. RED:
    /// return "" for the absent value → a blank cell under a heading, which reads as a rendering
    /// fault rather than as an answer, while the neighbouring Version column prints a dash for the
    /// very same situation.
    func testDescriptorCell_spellsTheAbsentValueAsADashLikeEveryOtherColumn() async {
        XCTAssertEqual(
            BenchmarkResultsCard.descriptorCell(ModelDescriptorText.format("gguf")), "GGUF")
        XCTAssertEqual(
            BenchmarkResultsCard.descriptorCell(ModelDescriptorText.quantization("nvfp4")), "nvfp4")
        XCTAssertEqual(
            BenchmarkResultsCard.descriptorCell(ModelDescriptorText.format(nil)),
            BenchmarkMetricsPolicy.noValue)
        XCTAssertEqual(
            BenchmarkResultsCard.descriptorCell(ModelDescriptorText.quantization("  ")),
            BenchmarkMetricsPolicy.noValue)
    }

    /// The tooltip that replaced the endpoint line. RED: return the bare host → the Runs tab,
    /// which has no Provider column, is left with nothing at all naming which server ran a row.
    func testEndpointTooltip_namesBothTheProviderAndTheEndpoint() async {
        let tip = BenchmarkResultsCard.endpointTooltip(
            provider: .ollama, endpoint: "http://127.0.0.1:11434/")
        XCTAssertTrue(tip.contains(LLMProvider.ollama.displayName), tip)
        XCTAssertTrue(tip.contains("127.0.0.1:11434"), tip)
        // Shortened the same way every other endpoint on this screen is: the scheme is noise, the
        // port is what tells one local server from the other.
        XCTAssertFalse(tip.contains("http://"), tip)
    }

    /// RED: leave a column out of `columns` while the header row draws it (or the reverse) → the
    /// list every column pin reads stops describing the table, and the generic naming/uniqueness
    /// pins silently stop covering it (CLAUDE.md #57).
    func testColumns_placeFormatAndQuantizationRightAfterModel() async {
        XCTAssertEqual(
            BenchmarkResultsCard.columns.map(\.column),
            [
                .model, .format, .quantization, .provider, .providerVersion,
                .generation, .best, .timeToFirstToken, .prefill, .runCount, .lastMeasured,
            ])
    }

    /// The two rate columns must each name the vocabulary a reader would meet elsewhere, or the
    /// figures cannot be compared with anything outside this app.
    /// RED: strip "eval rate" from `generationHelp` → fails.
    func testRateHelp_mapsOntoTheTermsOtherToolsPrint() async {
        XCTAssertTrue(
            BenchmarkResultsCard.generationHelp.contains("eval rate"),
            BenchmarkResultsCard.generationHelp)
        XCTAssertTrue(
            BenchmarkResultsCard.firstTokenHelp.contains("time to first token"),
            BenchmarkResultsCard.firstTokenHelp)
    }

    // MARK: - Filter

    /// RED: reuse the "No results yet. Run the benchmark above" line for a query that matched
    /// nothing → the reader is told to run a benchmark they have already run, because the two
    /// empty tables look identical and have opposite fixes.
    func testNoMatches_repeatsTheQueryAndDiffersFromTheEmptyHistoryLine() async {
        let text = BenchmarkResultsCard.noMatches(for: "qwen", mode: .leaderboard)
        XCTAssertTrue(text.contains("\"qwen\""), text)
        XCTAssertNotEqual(text, BenchmarkResultsCard.noResultsYet)
    }

    /// One row is a model; one row on the Runs tab is a run. RED: one wording for both → the Runs
    /// tab claims no MODEL matches while the leaderboard above it lists that very model.
    func testNoMatches_namesWhatTheTabIsListing() async {
        XCTAssertTrue(
            BenchmarkResultsCard.noMatches(for: "qwen", mode: .leaderboard).contains("model"))
        XCTAssertTrue(
            BenchmarkResultsCard.noMatches(for: "qwen", mode: .history).contains("run"))
    }

    func testNoMatches_trimsTheQueryItEchoes() async {
        let text = BenchmarkResultsCard.noMatches(for: "  qwen  ", mode: .leaderboard)
        XCTAssertTrue(text.contains("\"qwen\""), text)
    }

    /// RED: showing the count unconditionally → "9 of 9" sits beside an untouched field and states
    /// nothing; showing it never → a filtered table is indistinguishable from a short one.
    func testMatchCountLabel_onlyOnceSomethingIsTyped() async {
        XCTAssertNil(BenchmarkResultsCard.matchCountLabel(visible: 9, total: 9, query: ""))
        XCTAssertNil(BenchmarkResultsCard.matchCountLabel(visible: 9, total: 9, query: "   "))
        XCTAssertEqual(
            BenchmarkResultsCard.matchCountLabel(visible: 2, total: 9, query: "qwen"), "2 of 9")
    }

    /// The count has to survive its own zero: that is exactly the state the no-match line explains,
    /// and "0 of 9" is what says the nine are still there.
    func testMatchCountLabel_survivesZeroMatches() async {
        XCTAssertEqual(
            BenchmarkResultsCard.matchCountLabel(visible: 0, total: 9, query: "zzz"), "0 of 9")
    }

    /// RED: a placeholder naming only the model → the reader never learns the provider and server
    /// columns are searched, which is how two rows for one model are told apart.
    func testFilterPlaceholder_namesBothHalvesOfARowsIdentity() async {
        let placeholder = BenchmarkResultsCard.filterPlaceholder.lowercased()
        XCTAssertTrue(placeholder.contains("model"), placeholder)
        XCTAssertTrue(placeholder.contains("server"), placeholder)
    }

    // MARK: - Generation rate: the tip has to name the source

    /// Three sources, three wordings — and the two exact ones must NOT claim the same provenance,
    /// because one is a window we divided and the other a rate the server divided.
    func testGenerationTip_differsPerSource() async {
        let window = BenchmarkRunCard.generationTip(for: .serverDecodeWindow)
        let reported = BenchmarkRunCard.generationTip(for: .serverReportedRate)
        let client = BenchmarkRunCard.generationTip(for: .clientWindow)

        XCTAssertTrue(window.hasPrefix("Exact"), window)
        XCTAssertTrue(reported.hasPrefix("Exact"), reported)
        XCTAssertTrue(client.hasPrefix("Approximate"), client)
        XCTAssertNotEqual(window, reported, "the two exact sources are not the same claim")
        XCTAssertTrue(window.contains("how long it spent decoding"), window)
        XCTAssertTrue(reported.contains("reported this rate itself"), reported)
    }

    /// An unknown source is a MIXTURE, and a mixture must read as the approximate case rather
    /// than borrow the wording of whichever source happened to be first.
    func testGenerationTip_nilSource_isTheApproximateWording() async {
        XCTAssertEqual(
            BenchmarkRunCard.generationTip(for: nil),
            BenchmarkRunCard.generationTip(for: .clientWindow))
    }

    // MARK: - Reasoning share

    func testFormatShare_isWholePercent() async {
        XCTAssertEqual(BenchmarkRunCard.formatShare(214.0 / 232.0), "92%")
        XCTAssertEqual(BenchmarkRunCard.formatShare(0), "0%")
        XCTAssertEqual(BenchmarkRunCard.formatShare(1), "100%")
    }

    /// A share above 1 is clamped rather than printed: "119%" of the output being reasoning is
    /// not a fact about the model, it is a fact about a disagreeing counter.
    func testFormatShare_clampsAndRefusesDegenerateValues() async {
        XCTAssertEqual(BenchmarkRunCard.formatShare(1.19), "100%")
        XCTAssertEqual(BenchmarkRunCard.formatShare(-0.1), BenchmarkMetricsPolicy.noValue)
        XCTAssertEqual(BenchmarkRunCard.formatShare(.nan), BenchmarkMetricsPolicy.noValue)
        XCTAssertEqual(BenchmarkRunCard.formatShare(.infinity), BenchmarkMetricsPolicy.noValue)
    }

    // MARK: - Sweep card

    private func sweepServer(
        _ provider: LLMProvider = .ollama,
        included: Bool = true,
        proposed: Bool = false,
        outcome: BenchmarkDiscoveryOutcome? = nil
    ) -> BenchmarkSweepServer {
        BenchmarkSweepServer(
            provider: provider,
            baseURLString: provider.defaultBaseURL,
            isIncluded: included,
            isProposedAddress: proposed,
            outcome: outcome)
    }

    /// "answered with nothing" and "did not answer" are different facts about a machine, and only
    /// one of them means the sweep may still clear it.
    ///
    /// RED: render both as "no models" → the row that earns a clearing pass is indistinguishable
    /// from the row that must never receive a command.
    func testSweepServerStatus_distinguishesAnEmptyAnswerFromNoAnswer() async {
        let empty = BenchmarkSweepCard.statusText(for: sweepServer(outcome: .answered([])))
        let silent = BenchmarkSweepCard.statusText(
            for: sweepServer(outcome: .noAnswer(detail: nil)))

        XCTAssertNotEqual(empty, silent)
        XCTAssertTrue(empty.contains("answered"), empty)
        XCTAssertFalse(silent.contains("answered"), silent)
    }

    /// RED: word an unauthorized server as "offline" → a server that is running perfectly well and
    /// simply wants a token is reported as absent, and the user goes looking for the wrong problem.
    func testSweepServerStatus_neverSaysOffline() async {
        let text = BenchmarkSweepCard.statusText(
            for: sweepServer(outcome: .noAnswer(detail: "401 unauthorized")))

        XCTAssertFalse(text.lowercased().contains("offline"), text)
        XCTAssertTrue(text.contains("401 unauthorized"), text)
    }

    /// RED: fold `.undetermined` into "no answer" → the row states a fact about a server nobody
    /// heard from, and never suggests the rescan that would settle it.
    func testSweepServerStatus_undeterminedAsksForARescan() async {
        let text = BenchmarkSweepCard.statusText(for: sweepServer(outcome: .undetermined))
        XCTAssertTrue(text.contains("rescan"), text)
    }

    func testSweepServerStatus_neverScannedIsNotAnAnswer() async {
        XCTAssertEqual(BenchmarkSweepCard.statusText(for: sweepServer()), "not scanned")
    }

    /// RED: drop the disclosure → an address the app guessed reads exactly like one the user
    /// configured, on the screen where a guess can turn into an unload command.
    func testSweepAddressNote_marksAProposedAddressOnly() async {
        XCTAssertNotNil(BenchmarkSweepCard.addressNote(for: sweepServer(proposed: true)))
        XCTAssertNil(BenchmarkSweepCard.addressNote(for: sweepServer(proposed: false)))
    }

    private func sweepEntries(_ names: [String], selected: Bool = true) -> [BenchmarkSweepEntry] {
        names.map {
            BenchmarkSweepEntry(
                target: BenchmarkTarget(
                    provider: .ollama, baseURLString: "http://x:11434", modelName: $0),
                isSelected: selected)
        }
    }

    /// RED: label the button "Run all" → an hour of work and twenty model loads start from a
    /// control that never said how much it was about to do.
    func testSweepRunTitle_carriesTheCount() async {
        XCTAssertEqual(BenchmarkSweepCard.runTitle(entries: sweepEntries(["a", "b", "c"])), "Run 3 models")
    }

    /// RED: count the LISTED entries rather than the selected ones → after ticking two of three
    /// off, the button offers "Run 3 models" for a run that will measure one.
    func testSweepRunTitle_countsOnlyTheSelected() async {
        var entries = sweepEntries(["a", "b", "c"])
        entries[1].isSelected = false
        entries[2].isSelected = false

        XCTAssertEqual(BenchmarkSweepCard.runTitle(entries: entries), "Run 1 model")
    }

    /// The state the user hit: twelve models listed, every circle empty, and a button still
    /// promising "Run all".
    ///
    /// RED: keep "Run all" for an empty selection and gate only on `entries.isEmpty` → the button
    /// stays enabled and its label promises the exact opposite of what pressing it does, which is
    /// nothing.
    func testSweepRunButton_withNothingSelected_saysRunAndIsRefused() async {
        let none = sweepEntries(["a", "b"], selected: false)

        XCTAssertEqual(BenchmarkSweepCard.runTitle(entries: none), "Run")
        XCTAssertFalse(BenchmarkSweepCard.canRun(entries: none))
        XCTAssertFalse(BenchmarkSweepCard.canRun(entries: []), "nothing found is also nothing to run")
        XCTAssertTrue(BenchmarkSweepCard.canRun(entries: sweepEntries(["a"])))
    }

    /// RED: report only the selected count ("0 selected") → the row stops saying how many models
    /// were found, and an empty selection is indistinguishable from an empty scan.
    func testSweepSelectionLabel_showsBothNumbers() async {
        var entries = sweepEntries(["a", "b", "c"])
        entries[0].isSelected = false

        XCTAssertEqual(BenchmarkSweepCard.selectionLabel(entries: entries), "2 of 3 selected")
    }

    /// RED: keep the title fixed → the one control that can undo a full deselection reads
    /// "Select none" while nothing is selected.
    func testSweepSelectAllTitle_flipsWithTheSelection() async {
        XCTAssertEqual(BenchmarkSweepCard.selectAllTitle(entries: sweepEntries(["a"])), "Select none")
        XCTAssertEqual(
            BenchmarkSweepCard.selectAllTitle(entries: sweepEntries(["a"], selected: false)),
            "Select all")
        XCTAssertEqual(BenchmarkSweepCard.selectAllTitle(entries: []), "Select all",
                       "an empty list is not 'all selected'")
    }

    /// A model nobody tried is not a model that failed.
    ///
    /// RED: render `.skipped` with the failure wording → a stopped sweep libels every model in its
    /// tail, and the leaderboard reader believes twelve models are broken.
    func testSweepEntryDetail_distinguishesSkippedFromFailed() async {
        let skipped = BenchmarkSweepCard.detail(for: .skipped, targetPhase: .idle)
        let failed = BenchmarkSweepCard.detail(for: .failed("no usable samples"), targetPhase: .idle)

        XCTAssertEqual(skipped, "not measured")
        XCTAssertNotEqual(skipped, failed)
    }

    /// The measuring row borrows the runner's own sentence instead of keeping a second copy of it.
    ///
    /// RED: hard-code "measuring…" → the per-sample progress the runner already publishes stops
    /// reaching the screen, and a five-minute model looks identical to a stuck one.
    func testSweepEntryDetail_measuringShowsThePerSamplePhase() async {
        let detail = BenchmarkSweepCard.detail(
            for: .measuring, targetPhase: .measuring(sample: 2, of: 5))

        XCTAssertEqual(detail, BenchmarkRunCard.statusText(for: .measuring(sample: 2, of: 5)))
    }

    /// RED: let a scan overwrite the phase line → a rescan after a finished sweep erases what that
    /// sweep reported, and the results are only visible in the table below.
    func testSweepStatus_scanningDoesNotEraseAFinishedResult() async {
        let finished = BenchmarkSweepRunner.Phase.finished(measured: 3, failed: 1, skipped: 0)
        let text = BenchmarkSweepCard.statusText(
            phase: finished, entries: [], isScanning: true)

        XCTAssertTrue(text.contains("3 models measured"), text)
        XCTAssertTrue(text.contains("1 failed"), text)
    }

    /// RED: report a stop as a completion → "stopped after 2 models" becomes "2 models measured",
    /// and the eighteen nobody ran are silently dropped from the sentence.
    func testSweepStatus_namesWhyItStopped() async {
        let cancelled = BenchmarkSweepCard.statusText(
            phase: .stopped(.cancelled, measured: 2), entries: [])
        let busy = BenchmarkSweepCard.statusText(
            phase: .stopped(.taskStartedRunning, measured: 2), entries: [])

        XCTAssertTrue(cancelled.contains("Stopped after 2 models"), cancelled)
        XCTAssertNotEqual(cancelled, busy)
        XCTAssertTrue(busy.contains("task started running"), busy)
    }

    /// RED: print a duration estimate → it would have to come from somewhere, and neither provider
    /// reports anything a first-run estimate could be built from.
    func testSweepFooter_saysWhatItCostsWithoutInventingANumber() async {
        let footer = BenchmarkSweepCard.footer(blockedBy: nil)

        XCTAssertTrue(footer.contains("minutes per model"), footer)
        XCTAssertTrue(footer.contains("every server listed here"), footer)
        XCTAssertTrue(footer.contains("Switch a server off"), footer)
    }
}
