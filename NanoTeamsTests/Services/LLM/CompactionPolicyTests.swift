import XCTest

@testable import NanoTeams

/// The pure half of a context-compaction epoch: what survives, what is folded, and what the
/// seed says.
///
/// Every assertion here stands for a way the epoch can silently destroy work. A head that is
/// not byte-exact costs a full re-prefill on the next request (and, if it drops the system
/// prompt, the role's identity). A record that does not round-trip means a Supervisor's
/// standing instruction decays into a model's paraphrase after two epochs. A seed marker
/// matched with `contains` instead of `hasPrefix` lets a model QUOTE a heading and have the
/// quote read as structure.
final class CompactionPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func system(_ text: String = "You are a Software Engineer.") -> ChatMessage {
        ChatMessage(role: .system, content: text)
    }

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    private func assistant(_ text: String, calls: [ChatToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: calls)
    }

    private func toolResult(_ json: String, id: String? = nil) -> ChatMessage {
        ChatMessage(role: .tool, content: json, toolCallID: id)
    }

    private func askSupervisorCall(id: String = "c1") -> ChatToolCall {
        ChatToolCall(
            id: id, name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"Which API?"}"#)
    }

    private func askSupervisorFormCall(id: String = "c1") -> ChatToolCall {
        ChatToolCall(
            id: id, name: ToolNames.askSupervisorForm,
            argumentsJSON: #"{"headline":"Three questions","form":"{}"}"#)
    }

    /// `[system, task, assistant, tool, assistant]` — the ordinary mid-step shape.
    private func standardWire() -> [ChatMessage] {
        [
            system(),
            user("## Supervisor Task\nBuild a calculator."),
            assistant("Reading files.", calls: [
                ChatToolCall(id: "r1", name: ToolNames.readFile, argumentsJSON: #"{"path":"a"}"#)
            ]),
            toolResult(#"{"ok":true,"content":"…"}"#, id: "r1"),
            assistant("Done reading."),
        ]
    }

    // MARK: - headEnd

    func testHeadEnd_emptyWire_isZero() {
        XCTAssertEqual(CompactionPolicy.headEnd(in: []), 0)
    }

    /// A wire with no assistant turn is ALL head — there is nothing the model produced, so
    /// nothing to summarise.
    func testHeadEnd_noAssistantTurn_isTheWholeWire() {
        let wire = [system(), user("task"), user("more context")]
        XCTAssertEqual(CompactionPolicy.headEnd(in: wire), wire.count)
    }

    func testHeadEnd_stopsAtTheFirstAssistantTurn() {
        XCTAssertEqual(CompactionPolicy.headEnd(in: standardWire()), 2)
    }

    /// The load-bearing case. After epoch 1 the seed EXTENDS the leading run of non-assistant
    /// messages, so a `headEnd` that only looked for the first assistant would keep seed 1 and
    /// append seed 2 after it — a stack of summaries of summaries, growing with every epoch.
    ///
    /// RED: drop `|| isCompactionSeed($0)` from `headEnd` → this fails, and the wire grows one
    /// seed per epoch forever.
    func testHeadEnd_stopsAtAPreviousSeed_soSeedsCannotStack() {
        let wire = [
            system(),
            user("## Supervisor Task\nBuild it."),
            user(CompactionPolicy.seedTurn(summary: "Earlier work.", notes: nil, record: [])),
            assistant("Continuing."),
        ]
        XCTAssertEqual(CompactionPolicy.headEnd(in: wire), 2)
    }

    /// The planning phase's own turns live in the leading run and must survive: the brief is
    /// what the boundary slices at, and the implementation seed is the only record of the
    /// role's notes.
    func testHeadEnd_keepsPlanningTurnsInTheHead() {
        let wire = [
            system(),
            user("## Supervisor Task\nBuild it."),
            user(PlanningPhasePolicy.implementationSeedTurn(
                notes: "Findings: X", expectedArtifacts: [])),
            assistant("Working."),
        ]
        XCTAssertEqual(CompactionPolicy.headEnd(in: wire), 3)
    }

    // MARK: - isCompactionSeed

    /// `hasPrefix`, not `contains`: a summary that QUOTES the header is prose, not structure.
    ///
    /// RED: switch the matcher to `contains` → this fails, and every later epoch truncates the
    /// wire at the quotation instead of at the real seed.
    func testIsCompactionSeed_aQuotedHeaderIsNotASeed() {
        let quoting = user("I looked at the previous ## Context summary and continued.")
        XCTAssertFalse(CompactionPolicy.isCompactionSeed(quoting))
    }

    func testIsCompactionSeed_onlyUserTurnsQualify() {
        let asAssistant = ChatMessage(
            role: .assistant, content: CompactionPolicy.seedMarker + "\nbody")
        XCTAssertFalse(CompactionPolicy.isCompactionSeed(asAssistant))
        XCTAssertTrue(CompactionPolicy.isCompactionSeed(
            user(CompactionPolicy.seedMarker + "\nbody")))
    }

    /// The compat surface exists from day one — see the doc comment on `seedMarkers` for the
    /// lesson the planning phase learned late.
    func testSeedMarkers_containTheLiveMarker() {
        XCTAssertTrue(CompactionPolicy.seedMarkers.contains(CompactionPolicy.seedMarker))
    }

    // MARK: - plan

    func testPlan_emptyWire_isNil() {
        XCTAssertNil(CompactionPolicy.plan(for: [], retainTail: false))
    }

    /// Nothing beyond the head means the conversation IS its pinned prefix. Folding it would
    /// replace the system prompt with a summary of itself.
    func testPlan_headOnlyWire_isNil() {
        let wire = [system(), user("task")]
        XCTAssertNil(CompactionPolicy.plan(for: wire, retainTail: false))
        XCTAssertNil(CompactionPolicy.plan(for: wire, retainTail: true))
    }

    func testPlan_inLoop_foldsEverythingAfterTheHead() {
        let plan = CompactionPolicy.plan(for: standardWire(), retainTail: false)
        XCTAssertEqual(plan, CompactionPolicy.Plan(headEnd: 2, tailStart: nil))
        XCTAssertEqual(plan?.discardedRange(in: standardWire()), 2..<5)
    }

    /// A parked step's last assistant turn holds the `ask_supervisor` call whose pending
    /// result re-entry replaces IN PLACE. Fold it away and the answer has nothing to attach
    /// to — the model wakes to an answer for a question it never asked.
    func testPlan_suspended_retainsTheOpenPark() {
        let wire = standardWire() + [
            assistant("", calls: [askSupervisorCall()]),
            toolResult(#"{"status":"pending"}"#, id: "c1"),
        ]
        let plan = CompactionPolicy.plan(for: wire, retainTail: true)
        XCTAssertEqual(plan, CompactionPolicy.Plan(headEnd: 2, tailStart: 5))
        XCTAssertEqual(plan?.discardedRange(in: wire), 2..<5)
    }

    /// `wait_for_events` parks the same way — the Autovisor's idle park.
    func testPlan_suspended_retainsAWaitForEventsPark() {
        let wire = standardWire() + [
            assistant("", calls: [ChatToolCall(
                id: "w1", name: ToolNames.waitForEvents, argumentsJSON: "{}")]),
            toolResult(#"{"status":"pending"}"#, id: "w1"),
        ]
        XCTAssertEqual(
            CompactionPolicy.plan(for: wire, retainTail: true)?.tailStart, 5)
    }

    /// A paused or failed step has no open call: it resumes by APPENDING, so there is nothing
    /// structural to preserve and the whole body folds.
    func testPlan_suspendedWithNoOpenPark_foldsEverything() {
        XCTAssertEqual(
            CompactionPolicy.plan(for: standardWire(), retainTail: true)?.tailStart, nil)
    }

    /// A tail that already fills half the budget cannot be compacted INTO anything, and the
    /// epoch would spend an LLM call to produce a conversation that is still too big.
    func testPlan_giantRetainedTail_refusesTheEpoch() {
        let huge = String(repeating: "x", count: 40_000)
        let wire = standardWire() + [
            assistant(huge, calls: [askSupervisorCall()]),
            toolResult(#"{"status":"pending"}"#, id: "c1"),
        ]
        XCTAssertNil(CompactionPolicy.plan(for: wire, retainTail: true, maxTailTokens: 500))
        XCTAssertNotNil(
            CompactionPolicy.plan(for: wire, retainTail: true, maxTailTokens: 1_000_000))
    }

    /// No limit given means no refusal — the in-loop path passes none, because there the tail
    /// is never retained in the first place.
    func testPlan_noTailBudget_neverRefuses() {
        let wire = standardWire() + [
            assistant(String(repeating: "y", count: 100_000), calls: [askSupervisorCall()]),
            toolResult(#"{"status":"pending"}"#, id: "c1"),
        ]
        XCTAssertNotNil(CompactionPolicy.plan(for: wire, retainTail: true))
    }

    // MARK: - compactedWire

    /// Byte-exactness of the head is the whole reason this is a SLICE and not a rebuild: the
    /// server's KV cache keys on the exact bytes, and a re-render reads task state that has
    /// moved since t0.
    ///
    /// Compares the ELEMENTS, not a flattened string — `imageContent` and `toolCalls` are
    /// part of what a message is, and a comparison over `content` alone would pass while
    /// dropping both.
    func testCompactedWire_headIsElementWiseIdentical() {
        var wire = standardWire()
        wire[0].imageContent = [ImageContent(base64Data: "AAAA", mimeType: "image/png")]
        wire[1].toolCalls = [askSupervisorCall(id: "kept")]
        let plan = CompactionPolicy.plan(for: wire, retainTail: false)!
        let compacted = CompactionPolicy.compactedWire(
            from: wire, plan: plan, seedTurn: "## Context summary\nx")
        XCTAssertEqual(Array(compacted[..<2]), Array(wire[..<2]))
    }

    func testCompactedWire_seedIsAUserTurnAndTheLastOne_whenNoTailIsRetained() {
        let wire = standardWire()
        let plan = CompactionPolicy.plan(for: wire, retainTail: false)!
        let compacted = CompactionPolicy.compactedWire(
            from: wire, plan: plan, seedTurn: "## Context summary\nx")
        XCTAssertEqual(compacted.count, 3)
        XCTAssertEqual(compacted.last?.role, .user)
        XCTAssertEqual(compacted.last?.content, "## Context summary\nx")
    }

    func testCompactedWire_retainedTailFollowsTheSeed() {
        let wire = standardWire() + [
            assistant("", calls: [askSupervisorCall()]),
            toolResult(#"{"status":"pending"}"#, id: "c1"),
        ]
        let plan = CompactionPolicy.plan(for: wire, retainTail: true)!
        let compacted = CompactionPolicy.compactedWire(
            from: wire, plan: plan, seedTurn: "## Context summary\nx")
        XCTAssertEqual(compacted.count, 5)
        XCTAssertEqual(compacted[2].role, .user)
        XCTAssertEqual(Array(compacted[3...]), Array(wire[5...]))
    }

    /// Two epochs in a row must leave ONE seed, not two.
    func testCompactedWire_secondEpochReplacesTheFirstSeed() {
        let wire = standardWire()
        let first = CompactionPolicy.compactedWire(
            from: wire,
            plan: CompactionPolicy.plan(for: wire, retainTail: false)!,
            seedTurn: CompactionPolicy.seedTurn(summary: "First.", notes: nil, record: []))
        let grown = first + [assistant("More work."), toolResult("{}")]
        let second = CompactionPolicy.compactedWire(
            from: grown,
            plan: CompactionPolicy.plan(for: grown, retainTail: false)!,
            seedTurn: CompactionPolicy.seedTurn(summary: "Second.", notes: nil, record: []))
        XCTAssertEqual(second.filter { CompactionPolicy.isCompactionSeed($0) }.count, 1)
        XCTAssertEqual(second.last?.content?.contains("Second."), true)
        XCTAssertEqual(second.last?.content?.contains("First."), false)
    }

    // MARK: - Supervisor record

    private func recordedFrom(_ wire: [ChatMessage]) -> [String] {
        let plan = CompactionPolicy.plan(for: wire, retainTail: false)!
        return CompactionPolicy.supervisorRecord(
            in: wire, discarded: plan.discardedRange(in: wire))
    }

    func testSupervisorRecord_readsTheQueuedTurn_prefixStripped() {
        let wire = standardWire() + [
            user(MessageSourceContext.supervisorMessagePrefix + "Do not touch Storage/."),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Do not touch Storage/."])
    }

    /// The legacy spellings are still on disk in every conversation persisted before
    /// 2026-09-06, and a record that skipped them would drop the instruction silently.
    func testSupervisorRecord_readsLegacyQueuedSpellings() {
        let wire = standardWire() + [
            user("Supervisor:\nKeep the API stable."),
            user("Supervisor: And ship on Friday."),
        ]
        XCTAssertEqual(
            recordedFrom(wire), ["Keep the API stable.", "And ship on Friday."])
    }

    func testSupervisorRecord_readsRevisionFeedback() {
        let wire = standardWire() + [
            user(MessageSourceContext.supervisorFeedbackPrefix + "Rename the type."),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Rename the type."])
    }

    /// The composed form is real: `correctRole` routes a correction through
    /// `answerSupervisorQuestion` with the feedback marker already attached. Stripping only
    /// the outer prefix would leave the inner marker inside the "verbatim" record.
    func testSupervisorRecord_stripsTheComposedAnswerFeedbackPrefix() {
        let wire = standardWire() + [
            user(MessageSourceContext.supervisorAnswerPrefix
                + MessageSourceContext.supervisorFeedbackPrefix + "Use the other parser."),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Use the other parser."])
    }

    /// An answered `ask_supervisor` lands as a TOOL envelope, not as prose — the loop replaces
    /// the pending result in place. A record that only read `.user` turns would lose every
    /// answer the Supervisor ever gave.
    func testSupervisorRecord_readsAnAnsweredAskSupervisorEnvelope() {
        let wire = standardWire() + [
            assistant("", calls: [askSupervisorCall()]),
            toolResult(
                #"{"ok":true,"response":"Use SwiftData.","tool":"ask_supervisor"}"#, id: "c1"),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Use SwiftData."])
    }

    /// The form's answer rides the SAME collaboration envelope, stamped with its own tool
    /// name. Nothing about the failure is loud: the predicate simply declines the envelope,
    /// `supervisorRecord` returns one fewer entry, and the human's answers to a questionnaire
    /// are absent from the compacted wire with a clean log and an identical return type.
    ///
    /// RED: narrow `supervisorAnswerResponse` back to `== ToolNames.askSupervisor` → this
    /// returns `[]` while every other compaction test stays green.
    func testSupervisorRecord_readsAnAnsweredFormEnvelope() {
        let wire = standardWire() + [
            assistant("", calls: [askSupervisorFormCall()]),
            toolResult(
                #"{"ok":true,"response":"Q1. Scheme?\nA1. Debug","tool":"ask_supervisor_form"}"#,
                id: "c1"),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Q1. Scheme?\nA1. Debug"])
    }

    /// A step suspended on a form is suspended exactly as one suspended on a plain question,
    /// so `retainTail` must keep that turn: re-entry resolves the park by finding the pending
    /// result by `toolCallID`, and a folded-away park leaves the answer nothing to attach to.
    ///
    /// The two assertions are one controlled comparison — the plain park is the control, and
    /// it is what makes the form's `tailStart` mean "recognised as a park" rather than
    /// "happens to be the last assistant".
    ///
    /// RED: narrow `carriesOpenPark` back to `== ToolNames.askSupervisor` → the form case
    /// falls into the "nothing structural to preserve" branch and returns `tailStart: nil`,
    /// while the plain case stays green.
    func testPlan_retainsAnOpenFormPark_asItDoesAPlainOne() {
        func planTail(parkCall: ChatToolCall) -> Int? {
            let wire = standardWire() + [
                assistant("", calls: [parkCall]),
                toolResult(#"{"ok":true,"data":{"status":"pending"}}"#, id: "c1"),
            ]
            return CompactionPolicy.plan(for: wire, retainTail: true)?.tailStart
        }
        let plainTail = planTail(parkCall: askSupervisorCall())
        XCTAssertNotNil(plainTail, "control: a plain park is retained")
        XCTAssertEqual(
            planTail(parkCall: askSupervisorFormCall()), plainTail,
            "a form park must be retained exactly as a plain one")
    }

    func testSupervisorRecord_ignoresOtherToolResults() {
        let wire = standardWire() + [
            toolResult(#"{"ok":true,"response":"not the supervisor","tool":"ask_teammate"}"#),
            toolResult("not json at all"),
        ]
        XCTAssertEqual(recordedFrom(wire), [])
    }

    /// The head is PINNED — it is still on the wire — so copying its turns into the record
    /// would state the task brief twice on every request for the rest of the step.
    func testSupervisorRecord_takesNothingFromTheHeadOrTheRetainedTail() {
        let wire = [
            system(),
            user(MessageSourceContext.supervisorMessagePrefix + "HEAD instruction"),
            assistant("Working."),
            user(MessageSourceContext.supervisorMessagePrefix + "FOLDED instruction"),
            assistant("", calls: [askSupervisorCall()]),
            toolResult(#"{"ok":true,"response":"TAIL answer","tool":"ask_supervisor"}"#, id: "c1"),
        ]
        let plan = CompactionPolicy.plan(for: wire, retainTail: true)!
        let record = CompactionPolicy.supervisorRecord(
            in: wire, discarded: plan.discardedRange(in: wire))
        XCTAssertEqual(record, ["FOLDED instruction"])
    }

    /// A previous epoch's record lives inside its seed, and that seed is the FIRST thing the
    /// next epoch folds. Carrying it forward is what makes instructions accumulate instead of
    /// decaying one epoch at a time.
    func testSupervisorRecord_carriesForwardAPreviousEpochsRecord() {
        let earlier = CompactionPolicy.seedTurn(
            summary: "Earlier.", notes: nil, record: ["Never touch main."])
        let wire = [
            system(), user("task"), user(earlier),
            assistant("Working."),
            user(MessageSourceContext.supervisorMessagePrefix + "Also: no force pushes."),
        ]
        XCTAssertEqual(recordedFrom(wire), ["Never touch main.", "Also: no force pushes."])
    }

    // MARK: - Record round-trip

    /// The integrity check R3.9.5 asks for: what goes into a seed comes back out byte-exact.
    ///
    /// The adversarial entries are the point. A Supervisor may type anything — the entry
    /// header, a delimiter, a blank line, Cyrillic, an empty string — and a framing that
    /// scanned for a separator would corrupt or merge those. The line COUNT makes the parser
    /// blind to the entry's own bytes.
    func testRecordRoundTrip_survivesEveryShapeAHumanCanType() {
        let record = [
            "Do not touch Storage/.",
            "Multi\nline\ninstruction",
            "#### 1 · 2 lines",
            "---\n***\n===",
            "Не трогай Storage/ — там ничего нет.",
            "",
            "trailing newline\n",
            "  leading and trailing spaces  ",
        ]
        let seed = CompactionPolicy.seedTurn(summary: "A summary.", notes: nil, record: record)
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: seed), record)
    }

    func testRecordRoundTrip_emptyRecordEmitsNoSection() {
        let seed = CompactionPolicy.seedTurn(summary: "A summary.", notes: nil, record: [])
        XCTAssertFalse(seed.contains(CompactionPolicy.recordSectionHeader))
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: seed), [])
    }

    /// A turn that is not a seed at all yields nothing rather than throwing or guessing.
    func testRecordedSupervisorMessages_onArbitraryText_isEmpty() {
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: "just prose"), [])
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: ""), [])
    }

    /// A malformed entry header stops the read rather than mis-framing what follows. The
    /// parser is hand-written (a literal regex cannot fail to compile, so its `try?` branch is
    /// a line no test can reach), which puts the burden of these shapes here.
    func testRecordedSupervisorMessages_stopsAtAMalformedHeader() {
        let head = CompactionPolicy.recordSectionHeader + "\n"
        for header in [
            "#### · 1 lines",          // no index
            "#### 1 ·  lines",         // no count
            "#### 1 · 1",              // no unit
            "#### 1 · 1 turns",        // wrong unit
            "#### 1 - 1 lines",        // wrong separator
            "### 1 · 1 lines",         // wrong depth
            "#### x · 1 lines",        // non-numeric index
        ] {
            XCTAssertEqual(
                CompactionPolicy.recordedSupervisorMessages(in: head + header + "\nbody"), [],
                "`\(header)` must not be read as an entry header")
        }
    }

    /// A count that runs past the end of the seed is refused rather than read as a short
    /// entry — a truncated seed must not yield a silently truncated instruction.
    func testRecordedSupervisorMessages_refusesACountPastTheEnd() {
        let seed = CompactionPolicy.recordSectionHeader + "\n#### 1 · 9 lines\nonly one"
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: seed), [])
    }

    /// The singular unit is read too — nothing writes it today, and a reader that refused it
    /// would be a trap for the first person who makes the header read naturally.
    func testRecordedSupervisorMessages_acceptsTheSingularUnit() {
        let seed = CompactionPolicy.recordSectionHeader + "\n#### 1 · 1 line\nkeep this"
        XCTAssertEqual(CompactionPolicy.recordedSupervisorMessages(in: seed), ["keep this"])
    }

    // MARK: - Marker neutralization

    /// `PlanningPhasePolicy.briefIndex` matches with `contains`. A model that quotes the
    /// heading it just read would make the boundary slice the wire at the SEED, on every
    /// iteration, for the rest of the step.
    ///
    /// RED: drop `neutralizeWireMarkers` from `seedTurn` → this fails, and a summary that
    /// mentions the planning phase silently truncates the conversation every turn.
    func testSeedTurn_neutralizesPlanningMarkersInsideTheModelsSummary() {
        let summary = """
        I finished the ## Planning phase and then the ## Planning phase closed marker
        appeared. Later I saw ## Plan from your notes and ## Research phase.
        """
        let seed = CompactionPolicy.seedTurn(summary: summary, notes: nil, record: [])
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief([ChatMessage(role: .user, content: seed)]))
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesClosedMarker(
            [ChatMessage(role: .user, content: seed)]))
        XCTAssertFalse(seed.contains(PlanningPhasePolicy.briefMarker))
        XCTAssertFalse(seed.contains(PlanningPhasePolicy.seedMarker))
    }

    func testNeutralizeWireMarkers_collapsesAnyRunOfHashes_andIsIdempotent() {
        let once = CompactionPolicy.neutralizeWireMarkers("## a\n### b\n#### c\n# d")
        XCTAssertEqual(once, "# a\n# b\n# c\n# d")
        XCTAssertEqual(CompactionPolicy.neutralizeWireMarkers(once), once)
    }

    /// The RECORD is verbatim by contract (R3.9.5), so it is NOT neutralized — a Supervisor
    /// who wrote a heading gets their heading back.
    func testSeedTurn_doesNotNeutralizeTheSupervisorRecord() {
        let seed = CompactionPolicy.seedTurn(
            summary: nil, notes: nil, record: ["## Keep this heading"])
        XCTAssertTrue(seed.contains("## Keep this heading"))
    }

    /// The seed's OWN marker must survive its own neutralizer, or the next epoch cannot find
    /// it and seeds start stacking.
    func testSeedTurn_startsWithTheSeedMarker() {
        let seed = CompactionPolicy.seedTurn(
            summary: "## quoted", notes: "## also quoted", record: [])
        XCTAssertTrue(seed.hasPrefix(CompactionPolicy.seedMarker))
        XCTAssertTrue(CompactionPolicy.isCompactionSeed(
            ChatMessage(role: .user, content: seed)))
    }

    // MARK: - Seed material

    func testSeedTurn_carriesSummaryNotesAndRecordIndependently() {
        let all = CompactionPolicy.seedTurn(
            summary: "SUMMARY BODY", notes: "NOTES BODY", record: ["RECORD BODY"])
        XCTAssertTrue(all.contains("SUMMARY BODY"))
        XCTAssertTrue(all.contains("NOTES BODY"))
        XCTAssertTrue(all.contains("RECORD BODY"))

        let notesOnly = CompactionPolicy.seedTurn(
            summary: nil, notes: "NOTES BODY", record: [])
        XCTAssertTrue(notesOnly.contains("NOTES BODY"))
        XCTAssertFalse(notesOnly.contains(CompactionPolicy.recordSectionHeader))
    }

    func testHasSeedMaterial_isFalseOnlyWhenNothingWouldBeSaid() {
        XCTAssertFalse(CompactionPolicy.hasSeedMaterial(summary: nil, notes: nil, record: []))
        XCTAssertFalse(CompactionPolicy.hasSeedMaterial(
            summary: "   \n ", notes: "  ", record: []))
        XCTAssertTrue(CompactionPolicy.hasSeedMaterial(summary: "x", notes: nil, record: []))
        XCTAssertTrue(CompactionPolicy.hasSeedMaterial(summary: nil, notes: "x", record: []))
        XCTAssertTrue(CompactionPolicy.hasSeedMaterial(summary: nil, notes: nil, record: ["x"]))
    }

    func testIsUsableSummary_rejectsNilAndWhitespace() {
        XCTAssertFalse(CompactionPolicy.isUsableSummary(nil))
        XCTAssertFalse(CompactionPolicy.isUsableSummary(""))
        XCTAssertFalse(CompactionPolicy.isUsableSummary(" \n\t "))
        XCTAssertTrue(CompactionPolicy.isUsableSummary("Done."))
    }

    // MARK: - summaryText

    func testSummaryText_prefersTheContentChannel() {
        let resolution = FinishedReplyToolCallResolver.Resolution(
            content: "  The summary.  ", toolCalls: [])
        XCTAssertEqual(CompactionPolicy.summaryText(from: resolution), "The summary.")
    }

    /// A model told "do not call a tool" sometimes calls one anyway — the catalog is still in
    /// its system prompt. Discarding the reply would throw away a summary that exists.
    func testSummaryText_recoversAWrappedSummaryFromToolArguments() {
        for key in ["summary", "content", "answer", "text", "question", "message"] {
            let call = StepToolCall(
                id: UUID(), createdAt: Date(), providerID: nil,
                name: ToolNames.askSupervisor,
                argumentsJSON: "{\"\(key)\":\"Wrapped summary.\"}",
                resultJSON: nil, isError: nil)
            let resolution = FinishedReplyToolCallResolver.Resolution(
                content: "", toolCalls: [call])
            XCTAssertEqual(
                CompactionPolicy.summaryText(from: resolution), "Wrapped summary.",
                "the `\(key)` argument must be recovered")
        }
    }

    func testSummaryText_emptyEverything_isNil() {
        XCTAssertNil(CompactionPolicy.summaryText(
            from: FinishedReplyToolCallResolver.Resolution(content: "   ", toolCalls: [])))
        let empty = StepToolCall(
            id: UUID(), createdAt: Date(), providerID: nil, name: "x",
            argumentsJSON: #"{"summary":"   "}"#, resultJSON: nil, isError: nil)
        XCTAssertNil(CompactionPolicy.summaryText(
            from: FinishedReplyToolCallResolver.Resolution(content: "", toolCalls: [empty])))
    }

    func testSummaryText_malformedArgumentsJSON_isNilRatherThanACrash() {
        let broken = StepToolCall(
            id: UUID(), createdAt: Date(), providerID: nil, name: "x",
            argumentsJSON: "{not json", resultJSON: nil, isError: nil)
        XCTAssertNil(CompactionPolicy.summaryText(
            from: FinishedReplyToolCallResolver.Resolution(content: "", toolCalls: [broken])))
    }

    // MARK: - Request rubric

    /// The rubric is a turn the model reads. It is under the same three rules every nudge is
    /// (`Ratchet/NudgeTextPinTests`); this asserts the two that are about MEANING rather than
    /// wording, so a rewrite cannot quietly drop them.
    func testSummaryRequestTurn_asksForStandaloneProseAndNamesNoTool() {
        let turn = CompactionPolicy.summaryRequestTurn()
        XCTAssertTrue(turn.lowercased().contains("stand alone"))
        XCTAssertTrue(turn.lowercased().contains("prose"))
        XCTAssertFalse(turn.contains(ToolNames.askSupervisor))
        XCTAssertFalse(turn.contains(ToolNames.createArtifact))
    }

    // MARK: - Notice

    func testNoticeText_headlineNamesTheNumbersAndTheReason() {
        let notice = CompactionPolicy.noticeText(
            reason: .budgetExceeded, beforeTokens: 24_100, afterTokens: 3_200,
            foldedTurns: 37, seedTurn: "## Context summary\nbody")
        let headline = notice.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(headline.contains("37"))
        XCTAssertTrue(headline.contains("24.1k"))
        XCTAssertTrue(
            headline.contains("~3.2k"),
            "nothing has been sent since the fold, so the AFTER number is the estimator's and "
                + "must not be printed as if it were measured: \(headline)")
        XCTAssertTrue(headline.contains("budget exceeded"))
        XCTAssertTrue(notice.contains("## Context summary\nbody"))
    }

    /// Unknown counts are omitted rather than printed as zero — a "0 → 0 tokens" row would be
    /// a measurement claim nobody made.
    func testNoticeText_withoutCounts_omitsTheArrow() {
        let notice = CompactionPolicy.noticeText(
            reason: .manual, beforeTokens: nil, afterTokens: 900,
            foldedTurns: 4, seedTurn: "seed")
        XCTAssertFalse(notice.contains("→"))
        XCTAssertTrue(notice.contains("4 turns"))
    }

    func testEveryReasonHasADistinctNoticeLabel() {
        let labels = CompactionPolicy.CompactionReason.allCases.map(\.noticeLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains { $0.isEmpty })
    }
}
