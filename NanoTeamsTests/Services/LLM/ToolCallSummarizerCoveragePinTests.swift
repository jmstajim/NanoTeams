import XCTest
@testable import NanoTeams

/// Every tool either summarizes its arguments on the activity-feed card, or is on a
/// justified allowlist — and the allowlist cannot be used to silence this pin.
///
/// The gap this closes: `ToolCallSummarizer.argumentSummarizers` is an OCP dictionary, so a
/// tool absent from it is a silent no-op rather than a compile error. `summarizeArguments`
/// returns `""` for an unknown tool and `ToolCallItemView` renders no `Text` at all, so the
/// card degrades to a bare `$ tool_name`. Nothing forced a new tool to acquire an entry, and
/// over months **23 of 50** accumulated without one — all ten Autovisor tools (so the
/// manager's entire review pass was a column of indistinguishable `$ task_status` rows),
/// seven git tools, the three delegation follow-ups, `ask_supervisor`, `conclude_meeting`
/// and `bash_output`. The same summary feeds the exported `conversation_log.md`
/// (`ConversationTranscriptRenderer`), so every bare card was also a bare transcript line.
///
/// Two tools additionally carried entries that could never fire — the Xcode runners read a
/// `scheme` key their zero-property schemas cannot deliver — which is worse than no entry,
/// because it reads as covered.
nonisolated final class ToolCallSummarizerCoveragePinTests: XCTestCase {

    private typealias TN = ToolNames

    /// The ONLY tool allowed onto `toolsWithoutArgumentSummary` for a reason other than
    /// "its schema takes no arguments". Mirrored here on purpose: widening the allowlist on
    /// a judgment call now costs a two-language diff, the same shape
    /// `CoverageExclusionPolicyPinTests` uses to make widening visible in review.
    ///
    /// `create_artifact`'s name reaches the feed as its own `.artifact` card one row later,
    /// so repeating it on the tool row states the same fact twice.
    private static let sanctionedNonEmptySchemaExemptions: Set<String> = [TN.createArtifact]

    // MARK: - The partition

    /// RED: add a tool to `ToolNames.allNames` without either an `argumentSummarizers`
    /// entry or an allowlist row → this fires and names it.
    func testEveryToolEitherSummarizesItsArgumentsOrIsJustifiedInTheAllowlist() {
        var unexplained: [String] = []
        for name in ToolNames.allNames
        where !ToolCallSummarizer.hasArgumentSummarizer(for: name)
            && !ToolCallSummarizer.toolsWithoutArgumentSummary.contains(name) {
            unexplained.append(name)
        }
        XCTAssertEqual(
            unexplained.sorted(), [],
            """
            These tools render as a bare `$ name` on the activity-feed card and as a bare \
            line in conversation_log.md. Give each an entry in \
            ToolCallSummarizer.argumentSummarizers, or — if it genuinely has nothing to say \
            — add it to toolsWithoutArgumentSummary with the reason.
            """)
    }

    /// The two sets must not overlap: a tool with an entry is not "without a summary", and
    /// an allowlist row next to a live entry means one of the two is a leftover.
    func testTheEntryTableAndTheAllowlistAreDisjoint() {
        let overlap = ToolCallSummarizer.toolsWithoutArgumentSummary
            .filter { ToolCallSummarizer.hasArgumentSummarizer(for: $0) }
        XCTAssertEqual(
            overlap.sorted(), [],
            "allowlisted but also has a summarizer entry — delete one side")
    }

    /// Neither side may name a tool that does not exist. Catches a rename that updated the
    /// roster and left the summarizer keyed on the old string (the entry would then be dead
    /// in exactly the way the Xcode `scheme` extractor was).
    func testNeitherSideNamesAToolThatIsNotOnTheRoster() {
        let roster = Set(ToolNames.allNames)
        XCTAssertEqual(
            ToolCallSummarizer.toolsWithoutArgumentSummary.subtracting(roster).sorted(), [],
            "allowlist names a tool that is not in ToolNames.allNames")
    }

    // MARK: - The allowlist cannot be abused

    /// RED: move any argument-carrying tool (say `task_status`) into
    /// `toolsWithoutArgumentSummary` to silence the partition pin → this fires.
    ///
    /// This is what stops the allowlist from becoming the cheap way out. Membership has to
    /// be EARNED: either the tool's schema really declares no properties — proved here
    /// against `ToolHandlerRegistry.allSchemas`, not asserted in prose — or it is the one
    /// sanctioned exception mirrored above.
    func testAllowlistedToolsEitherTakeNoArgumentsOrAreTheSanctionedException() {
        let schemasByName = Dictionary(
            ToolHandlerRegistry.allSchemas.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })

        for name in ToolCallSummarizer.toolsWithoutArgumentSummary.sorted() {
            if Self.sanctionedNonEmptySchemaExemptions.contains(name) { continue }

            guard let schema = schemasByName[name] else {
                XCTFail("\(name) is allowlisted but has no registered schema to justify it")
                continue
            }
            let propertyCount = schema.parameters.properties?.count ?? 0
            XCTAssertEqual(
                propertyCount, 0,
                """
                \(name) declares \(propertyCount) parameter(s), so it has something to \
                summarize and cannot sit on the zero-argument allowlist. Either give it an \
                argumentSummarizers entry, or — if the fact is already on screen elsewhere \
                — add it to sanctionedNonEmptySchemaExemptions here AND document the reason \
                on toolsWithoutArgumentSummary.
                """)
        }
    }

    /// The sanctioned-exception list is itself bounded: it may only name tools that are
    /// actually allowlisted, so it cannot pre-authorize a future silencing.
    func testSanctionedExceptionsAreAllActuallyAllowlisted() {
        XCTAssertEqual(
            Self.sanctionedNonEmptySchemaExemptions
                .subtracting(ToolCallSummarizer.toolsWithoutArgumentSummary).sorted(),
            [],
            "names a tool that is not on the allowlist — stale exemption")
    }

    // MARK: - Anti-vacuum

    /// Guards against the whole suite passing because one of the inputs went empty — the
    /// failure mode where `allNames` or the entry table is refactored to nothing and every
    /// assertion above becomes trivially true.
    func testTheScanActuallyCoveredTheRoster() {
        XCTAssertEqual(
            ToolNames.allNames.count, 50,
            "roster size changed — update this pin deliberately, and check the new tool has a summary")
        let summarized = ToolNames.allNames.filter { ToolCallSummarizer.hasArgumentSummarizer(for: $0) }
        XCTAssertGreaterThan(
            summarized.count, 40,
            "far fewer tools summarize than expected — the entry table probably lost rows")
        XCTAssertFalse(
            ToolCallSummarizer.toolsWithoutArgumentSummary.isEmpty,
            "an empty allowlist would make the abuse pin vacuous")
    }

    // MARK: - The screenshotted regressions, pinned by behaviour

    /// The three cards the user reported as bare, plus the two that were bare for the
    /// second reason (a dead entry). Behavioural, so it fails if an entry is deleted even
    /// while the structural pins above still pass.
    func testTheReportedToolsNowSayWhichCallTheyWere() {
        let cases: [(String, String, String)] = [
            (TN.taskStatus, #"{"task_id":7}"#, "#7"),
            (TN.controlTask, #"{"task_id":7,"action":"pause"}"#, "#7 pause"),
            (TN.createManagedTask, #"{"title":"Fix the parser","brief":"…"}"#, "Fix the parser"),
            (TN.gitLog, #"{"max":20,"oneline":true,"paths":["core/"]}"#, "-20 oneline core/"),
        ]
        for (tool, json, expected) in cases {
            XCTAssertEqual(
                ToolCallSummarizer.summarizeArguments(toolName: tool, json: json), expected,
                "\(tool) must name its call on the card")
        }
    }
}
