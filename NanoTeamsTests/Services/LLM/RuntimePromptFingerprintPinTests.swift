import XCTest

@testable import NanoTeams

/// The composed texts' version, pinned the way `BundledContentFingerprintPinTests` pins
/// the bundled one. A wording change to a nudge, the Harmony preamble, an error-note
/// direction or a one-shot prompt moves `RuntimePromptFingerprint.current`; this test
/// fails until the new value is recorded here — which is the moment to re-measure the
/// live effect (REC.10) and to note the change, instead of shipping it under provenance
/// that says nothing moved.
@MainActor
final class RuntimePromptFingerprintPinTests: XCTestCase {

    // 2026-09-07 — first recording, on the tree that introduced the registry (bundle 1.9.10).
    // 1.9.11 — bumped without moving it: the release changed no composed text (the one
    // production diff since `746b904e` is an indent in `HarmonySentinelNormalizer.swift`).
    // 2026-09-08 — 65 → 98 entries. `handleNoToolCalls`'s eleven nudges and five cap
    // escalations were inline literals, so the seven of them this wave rewrote (the tool-id
    // examples now come from the role's schema, and `{"param":"value"}` is gone from every
    // text a model reads) shipped under an UNCHANGED fingerprint — measured that day, and the
    // reason `Ratchet/RuntimePromptCensusPinTests` now enforces the census rather than a count.
    // 2026-09-08 (second wave, same day) — 98 → 100 entries and one nudge rewritten: the
    // malformed-JSON nudge stopped prescribing "the two closing braces" for every parse
    // failure (a false diagnosis for the transposed-quote shape it met that morning), and the
    // two repair NOTES joined the census, as did the parse-failure diagnostic's own two
    // literals (its rewording that same day would otherwise have shipped unversioned — the
    // wave's adversarial review caught it). Live re-measurement (REC.10) deferred by the
    // Supervisor to the next natural run — recorded in `DEBTS.md`.
    // 1.9.12 — 102 → 104 entries, and the release this value first SHIPS under.
    // The note above said "98 → 100" while the anti-vacuum below said 102; the count was
    // measured on this tree at 102 before the two rows landed, so the PROSE was the wrong
    // half. Both now come from the same measurement — a hand-written count beside a
    // machine-read one is a drift waiting to happen (#100).
    // `CompactionPolicy.summaryRequestTurn` and `.seedTurn` joined the census: both go on the
    // wire (the request is the trailing turn of the summary call, the seed is the one `.user`
    // turn the compacted wire keeps), and both rode the whole compaction wave outside the
    // registry — `RuntimePromptCensusPinTests` could not see them, because its population was
    // three NAMED files rather than the tree's markers. That pin now derives the population,
    // so the next such text cannot hide the same way. Nothing else moved: the wave's only
    // other diff here is `swiftformat` re-indenting `transposedQuoteRepairNote`'s `+`
    // continuations, which is whitespace OUTSIDE the quotes (`--indent-strings false`).
    // REC.10 for the compaction texts is deferred with D-36 — and cheaply, because
    // `f5710ba2f21c8ce6` never shipped either: the "before" for any live comparison is
    // `d0835b762dbebb64`, the value 1.9.11 went out with.
    // 1.9.15 — `SupervisorInquiryReply.questionnaire` joined the census. It is the
    // questionnaire an AUTOMATED answerer sees, reply contract included, and it reaches three
    // seams (a `task_status` result, a delegated question turn, the `.autonomous` answerer's
    // user turn) as ONE string precisely so a change to how a form is asked moves this value
    // once. REC.10 rides the wave's own headless run — a form is only answerable without a
    // human through these three paths, so any drift shows up there first.
    // 2026-09-11 — `noToolCallNudge` and `repetitiveNonToolNudge` rewritten to defect + one
    // action: the `ask_supervisor` arms dropped "If the reply is complete, … ; otherwise …"
    // (a predicate about the model's own output, which a chat role resolved by asking — a
    // questionnaire per turn where it held the form; `Ratchet/NudgeTextPinTests` Rule 6) and
    // the "plain text does not reach the Supervisor" claim; the manager arms dropped
    // "If nothing is left to do this pass". Five rows joined the census — the arms
    // `sampleTools` never rendered (`…/waitForEvents`, `…/none`, `…/askSupervisor`), so a
    // rewrite of a sibling arm can no longer ship under an unchanged value. Measured live
    // (REC.10, N=2 before / N=2 after, `ornith-1.5:35b` Q4_K_M on Ollama 0.34.0) — numbers in
    // `train-first-prompt/RUN_HISTORY.md`, 2026-09-11.
    // 2026-09-11 (second wave, same day) — `ToolErrorCode.questionnaireRequired` joined
    // `allCases`, so its `(none)` direction row is new: `ask_supervisor` now refuses a
    // question with the questionnaire's shape while the batch holds `ask_supervisor_form`
    // (KNOWN_ISSUES A28), and the policy deliberately appends nothing after that code. No
    // existing text moved. Measured live on the A27 instrument (N=2) — RUN_HISTORY 2026-09-11g.
    // 2026-09-11 (third wave, same day) — `ToolErrorNotePolicy.direction/INVALID_ARGS` moved:
    // `requiredArgumentsHint` is withheld when every required key arrived (the sample carries
    // `path`), because "requires: form, headline. Your call carried: form, headline." beside a
    // form whose JSON was broken diagnosed a missing argument the call did not have — three
    // times in one field run (MeditationApp task 52 run 9; KNOWN_ISSUES A28). The direction
    // "Fix the arguments and retry." is unchanged; the envelope's own message names the
    // defect (`SupervisorFormDecoding`, not in this census — it is composed per failure).
    // Not re-measured: the row changes only what is REMOVED after a value error.
    // 2026-09-11 (fourth wave, same day) — the form is READ where it used to be refused:
    // `SupervisorFormTextRepair` (« » or “ ” as string quotes, a surplus closer) and
    // `SupervisorInquiryLabelRepair` (`(recommended)` / a leading number in a label) each
    // report what they read through `meta.warnings` — five new rows, all runtime notes on a
    // SUCCESS envelope. `loopWarningMessage/persistentToolError` split into `held` / `moving`:
    // for `INVALID_ARGS` whose message MOVED between the failures the directive is "fix
    // exactly what the latest one names" — "changing the arguments is not working" had made
    // the model abandon a form one character from valid (MeditationApp task 52 run 11;
    // KNOWN_ISSUES A29/A30). `escalationClause` gained `tool:` and answers "" when the failing
    // tool is a supervisor ask (the ring: the plain ask refuses the form's shape). Measured
    // live (REC.10, N=2 before / N=2 after, same instrument) — RUN_HISTORY 2026-09-11h.
    // 2026-09-11 (fifth wave, same day) — the no-tool nudges read the gate's predicate: two new
    // rows, `noToolCallNudge/askSupervisorForm` and `repetitiveNonToolNudge/askSupervisorForm`,
    // render the form arm (`questionnaire: true` and the form in the set) — "Send those
    // questions as ask_supervisor_form: one `questions` entry per question, a choice as
    // single_choice with its options, the one you recommend first." The seven existing nudge
    // rows pass `questionnaire: false` and their text is byte-identical. Measured live (REC.10,
    // N=2 after the A1 point, same instrument) — RUN_HISTORY 2026-09-11i.
    // 2026-09-11 (sixth wave, same day; bundle 1.9.20) — the recency slot names the form: the
    // one row `SystemTemplates.stepEnding/producing=false,ask=true` renders
    // `advisoryStepEnding`, now "Reply by calling `ask_supervisor` with your full response
    // in its `question` field. Several questions, or a choice with its options, go as
    // `ask_supervisor_form`." — one imperative, the "plain text outside tool calls is invisible"
    // rationale dropped (R1.2.3, R4.3.2). No row added or removed; the bundled fingerprint moves
    // in the same commit (the constant is bundled text too, and `choiceFragment` left three role
    // prompts). Measured live (REC.10, N=2 after the A2 point, same instrument) — RUN_HISTORY
    // 2026-09-11j.
    // 2026-09-11 (seventh wave, same day) — the form's REFUSAL was retyped. Three rows join:
    // `SupervisorFormTextRepair.insertedCloserNote` (one dropped `}` or `]` put back — the
    // third rung of the decode ladder, adopted only because the decode then succeeded),
    // `…handledNotTheFaultNote` (the repairs on a FAILING call, after the fault and marked as
    // not the cause) and `SupervisorInquiryCompleteness.tooFewOptionsNote` (a choice with one
    // answer, which is what a truncated emission decodes into once its closer is back). No
    // existing text moved. Measured N=1 in the field (MeditationApp task 65 run 0), which is
    // single-sample by §7.1 item 3: the claim these rows carry is about the ENVELOPE, pinned
    // by `AskSupervisorFormToolTests` over both live payloads, not about model behaviour —
    // a before/after on that needs N=2 and is not claimed here.
    // 2026-09-11 (eighth wave, same day) — the form's own final `}`, and the sentences around
    // it. `SupervisorFormTextRepair.closedTheFormNote` is new (the ladder's fourth rung) and
    // `insertedCloserNote` gained the word "inside", because the two rungs recover different
    // things and a model told only "a bracket was missing" learns nothing about where it
    // slips. `SupervisorFormDecoding.unfinishedNote` joins under three rows — the three ways a
    // form ends unfinished, none of which is answered with brackets to append: the one tail
    // where appending is safe never reaches the message any more. The syntax arm also stopped
    // prefixing Foundation's constant "The given data was not valid JSON.", which pushed the
    // sentence naming the fault behind an excerpt of Cyrillic that the model then diagnosed
    // instead (R1.8.1). Three previously unregistered handler texts join the census in the
    // same pass — `AskSupervisorTool.questionnaireRequiredMessage` / `…Reason` and
    // `AskSupervisorFormTool.repairTheFormReason` — so an edit to any of them moves this
    // number instead of shipping under one that says nothing changed (REC.9); the gate's
    // reason gained the sentence saying where the analysis around the questions goes.
    // `ToolErrorNotePolicy.direction/INVALID_ARGS` is unchanged in text but now silent when
    // the envelope carries a `next` and every required argument arrived.
    // Measured N=1 in the field (MeditationApp task 67 run 1), single-sample by §7.1 item 3:
    // what these rows carry is the ENVELOPE, pinned by `AskSupervisorFormToolTests` over the
    // live payload; the two prompt sentences (the gate's reason, the silenced direction) are
    // NOT claimed to have been measured.
    // 2026-09-12 — one new row, one new sender: `SupervisorQuestionnaireRequest.directive`, the
    // text the Supervisor's `[ Ask as form ]` button sends to a role parked on a PLAIN ask.
    // It asks for the decision broken into its sides (scope, approach, edges, failure), one
    // `single_choice` per side plus one `free_text`, recommendation first. Nothing existing
    // moved, and `BundledContentFingerprint` does NOT move with it: no tool schema, template or
    // role prompt is touched — the directive is runtime text, delivered as the tool RESULT of
    // that role's own `ask_supervisor`.
    // NOT measured live. The button is new, so there is no before to compare against, and no
    // claim about model behaviour is made here (REC.10, §7.1): what IS pinned is the delivery —
    // `QuestionnaireRequestDeliveryTests` over the fields the wire reads — and the sentence
    // itself, by `SupervisorQuestionnaireRequestTests`.
    // 2026-09-12 — one new row, `ToolCallParsingHelpers.unterminatedStringDefect`, and one
    // reworded sender, `NoToolTurnNudges.malformedJSON`. An unterminated string is the one
    // defect Foundation reports at the position the string OPENED, so the malformed-JSON
    // nudge quoted a column number pointing away from the fault: `ornith-1.5:35b` read
    // "column 125", answered "I accidentally used non-ASCII curly quotes" and rewrote the
    // quotes while the missing closer stayed missing (MeditationApp task 71 run 5 and task 74
    // run 1, both 2026-09-12). The new row names the fault in our own words and names the
    // argument it belongs to, which on both live payloads is `form`; every other defect keeps
    // Foundation's message, which for those does point at the offending character. The nudge
    // also names the failing tool when its name survived the defect — a read-only batch is
    // several calls in one turn, and "the tool call" then picks out none of them.
    // Verified on the two live payloads, not on a model: no claim is made here about what the
    // model does with the new sentence (REC.10, §7.1).
    // 2026-09-12, same day, second row: `ToolCallParsingHelpers.reorderedClosersRepairNote`.
    // Once `form` stopped being hand-escaped the model stopped losing COUNT of its brackets
    // and started losing their ORDER — `}}]` where the nesting owes `}]}`. The tally balances,
    // so no existing repair sees anything wrong, and Foundation refuses several levels deep
    // with "Expecting ',' delimiter". `JSONStructuralCloserRepair.reorderingTrailingClosers`
    // puts the same closers back in the order the open containers owe; the note says what was
    // wrong, because the position the model would otherwise read points at the wrong end of
    // the document.
    // Measured: 8 of 11 undispatched emissions over 20 runs were exactly this shape
    // (`ornith-1.5:35b`, MeditationApp task 75), and on the 20-run after-measurement the
    // repair fired live in 3 runs, each of which then parked instead of losing its
    // questionnaire (clean folder, 2026-09-12).
    // 2026-09-12, same day, third row: `SupervisorInquiryHeadlineFallback.note`. The second
    // 20-run trainer pass (MeditationApp task 76, `ornith-1.5:35b`) found the cost had moved
    // off the form's SYNTAX and onto one missing argument: 4 of 20 runs emitted
    // `{"form": {…}}` with no `headline` at all — the model writes the questionnaire first
    // and treats the call as finished when it closes — and every one of them recovered on the
    // retry, so the requirement was charging a round trip to teach what the model already
    // knew. The headline is now derived from the first question's own prompt at the tool seam
    // and the omission reported, which is the `form (string)` lesson one argument over.
    // Measured: 4 of 20 before (20% of runs paying an extra emission); the after-measurement
    // is the same instrument's next pass — RUN_HISTORY 2026-09-12b. Measured there
    // (task 77, N=20): the model omits it at the SAME rate, 3 of 20, and every one now parks
    // on the first emission with the default reported — `INVALID_ARGS` 4 → 0, calls-per-park
    // 1.30 → 1.05. The rate not moving is what says the fix is ours and not the model's.
    // Two rows, not one: `…nestedNote` covers the OTHER spelling the same pass found in the
    // archive — the headline written INSIDE the form (2 of 68 field calls, and in one of them
    // the only copy, MeditationApp task 75 run 9). Deriving one from the questions there would
    // have discarded a headline the model HAD written, so the nested spelling is read and
    // reported rather than refused; the sibling argument still wins over both.
    // 2026-09-12, fourth row: the assumed answer. Five entries moved at once because one
    // behaviour did. `SupervisorInquiryRenderer.defaultedSuffix` is gone — nothing is filled
    // in for a question the Supervisor left alone — and `unansweredDirection` takes its place,
    // saying once, below the pairs, what the asking role does about the absences.
    // `SupervisorInquiryReply.questionnaire` re-renders with a reply contract that no longer
    // promises an omission is answered from the recommendation, and the auto-answerer's two
    // user-turn tails are marked and registered for the first time (until now the sentence
    // shaping every automated reply moved no fingerprint and appeared in no provenance line).
    // Reported by the Supervisor from the feed: an untouched CHOICE drew "Continue M19
    // [assumed]" with a green tick while an untouched free text drew "(not answered)" — one
    // silence, two reports, and the tick was on the one question nobody had answered.
    // Measured (REC.10, the emission half, `run_ask_supervisor_form_trainer.sh` N=20 against
    // task 78's 17/20 clean-on-first and 1.05 calls-per-park): 18/20 and 1.05, task 83 —
    // RUN_HISTORY 2026-09-12e. It took two passes, and the first is the finding: shortening
    // the schema's options sentence alongside the deletion cost 4 refusals in 20 runs where
    // 72 earlier runs on that model had none (task 82, 14/20, 1.42). The model split one
    // question across two array entries — `prompt` in the first, `kind`/`options` in the
    // second — so the relative clause that binds `options` to ITS question turned out to be
    // load-bearing prose, not decoration. It is back verbatim.
    // 2026-09-12, fifth row, same day and the other half of the same defect: the
    // recommendation stopped being a POSITION. `options[0]` made every choice question carry
    // one whether the model had one or not — in the archived design form, four badges for
    // three stated recommendations, one of them on an option the model had argued against and
    // one invented outright. Five registered texts moved: the questionnaire an automated
    // answerer reads (it tags the RESOLVED option now, and tags nothing when none was named),
    // the auto-answerer's questionnaire tail (its fallback rung no longer points at a
    // recommendation that is usually absent — R3.8.6), both no-tool nudge arms and the
    // re-ask directive (all four stated "the one you recommend first", which is now false),
    // and `recommendedMovedNote` is gone with the reordering it described, replaced by
    // nothing: reading a recommendation rewrites no part of the document the human answers, so
    // under REC.5 there is nothing to report. Measured (REC.10, emission half,
    // `run_ask_supervisor_form_trainer.sh` N=20 against task 83's 18/20 and 1.05):
    // RUN_HISTORY 2026-09-12f.
    //
    // 2026-09-13 — `9430b832b46d0c1b`. No text was EDITED: the registry's own
    // `sampleInquiry` gained `recommendedOptionID: "debug"`, so the rendered questionnaire it
    // hashes carries the `(recommended)` tag again. That tag is model-facing wire text, and
    // between the two dates it was covered by no row at all — the sample recommended nothing
    // once the tag stopped following `options[0]`, so an edit to `recommendedTag` would have
    // shipped without moving this fingerprint or the provenance line. The move restores the
    // coverage; the wire the model sees is unchanged from what a real recommending form
    // already produced, so there is nothing to re-measure (REC.10 does not apply to a sample).
    //
    // 2026-09-13 — `86d17be27ba8b294`, release 1.9.25's first move. The delegated Supervisor
    // exchange's QUESTION TURN became a named, marked builder and took a registry row
    // (`DelegatedSupervisorAnswerService.questionTurn`). Two things were wrong with it as a
    // literal. It was covered by no row — only the boundary phrase it interpolates had one —
    // so its last two sentences, which ARE the exchange's contract, could be edited under an
    // unchanged `runtimePromptVersion`. And one of them was FALSE: "Only the ask_supervisor
    // tool is available in this exchange" stood from the exchange's first day and went false
    // on 1.9.20, when `SystemTemplates.advisoryStepEnding` began naming `ask_supervisor_form`
    // beside the plain ask. The wire now carries the pair
    // (`ToolHandlerRegistry.supervisorAskSchemas`) and the turn names the pair, as ONE
    // escalation channel rather than two choices. REC.10 is OWED and deferred by the wave's
    // decision — recorded in DEBTS D-36 with the other unreleased movements.
    //
    // 2026-09-13 — `5bd6732fd5c69a9`, release 1.9.25's second move, and it is FOUR changes to
    // the executor's own refusal family (DEBTS D-B10). Two messages were rewritten:
    // `.workFolderClosed` named the only action it offered to a party the model cannot reach
    // ("until the user opens a project folder"), and `.visionNotConfigured` was still shipping
    // the retired permission as "proceed without image analysis" — sharper there than
    // anywhere, since vision's whole job is establishing a fact about an image. The
    // `precondition_failed` DIRECTION stopped diagnosing on six reasons' behalf: its blocker
    // claim was false for `.computerUseDisabled` and `.bashDisabled` (a session policy, not
    // the work folder), and its "proceed without this step" arrived one turn after
    // `.xcodeSchemeNotSelected`'s own "rather than assuming one" — task 48 run 1's exact
    // input, one code to the left. And `approverUnavailable+shell` gained a row: that arm
    // branches on `ToolHandlerRegistry.shellTools` while every row rendered with
    // `run_xcodebuild`, so it rode no fingerprint at all. REC.10 is OWED and deferred by the
    // wave's decision — recorded in DEBTS D-36.
    private static let expectedFingerprint = "5bd6732fd5c69a9"

    func testRuntimePromptText_hasNotChangedWithoutRecordingIt() {
        let actual = RuntimePromptFingerprint.current
        XCTAssertEqual(
            actual, Self.expectedFingerprint,
            """
            A runtime-composed prompt text changed (a nudge, the Harmony preamble, an \
            error-note direction, a one-shot prompt — see RuntimePromptRegistry).
            
            1. Re-measure what it changes live (REC.10) and note it in the commit.
            2. Set `expectedFingerprint` in this test to: \(actual)
            """
        )
    }

    func testFingerprint_isStableWithinAProcess() {
        XCTAssertEqual(RuntimePromptFingerprint.current, RuntimePromptFingerprint.current)
        XCTAssertEqual(RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries), RuntimePromptFingerprint.current)
    }

    func testFingerprint_ignoresRegistryOrder() {
        XCTAssertEqual(
            RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries.reversed()),
            RuntimePromptFingerprint.current)
    }

    /// RED by construction: one entry's rendering gains one byte → a different value.
    func testFingerprint_movesWhenOneEntryMoves() throws {
        var entries = RuntimePromptRegistry.entries
        let first = try XCTUnwrap(entries.first)
        entries[0] = RuntimePromptRegistry.Entry(name: first.name) { first.render() + "x" }
        XCTAssertNotEqual(RuntimePromptFingerprint.compute(entries), RuntimePromptFingerprint.current)
    }

    func testEntryNames_areUnique_andEveryEntryRendersSomething() {
        let names = RuntimePromptRegistry.entries.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate entry names: \(names)")
        XCTAssertGreaterThanOrEqual(names.count, 101, "anti-vacuum: 104 entries on 2026-09-08")
        // Two entries are empty BY DESIGN and stay registered so a future non-empty value is
        // versioned: the fresh-install `## Global guidance` (the one-tool rule moved into the
        // tool body, 2026-09-07) and the escalation clause for a refusal nobody can answer.
        let emptyByDesign: Set<String> = ["AppDefaults.globalContext", "LLMExecutionService.escalationClause/approvalUnavailable"]
        for entry in RuntimePromptRegistry.entries where !emptyByDesign.contains(entry.name) {
            XCTAssertFalse(entry.render().isEmpty, "\(entry.name) renders nothing — a sample that misses its text is not versioned")
        }
        for name in emptyByDesign {
            XCTAssertTrue(RuntimePromptRegistry.entries.contains { $0.name == name }, "\(name) left the registry — drop it from `emptyByDesign`")
        }
    }

    /// `forRun` is where the app hands a logger to a run, and it primes the value the
    /// logger seam reads from a stream task.
    func testForRun_primesTheValueTheSeamReads() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).jsonl")
        _ = NetworkLogger.forRun(logURL: url)
        XCTAssertEqual(RuntimePromptFingerprint.primed, RuntimePromptFingerprint.current)
    }

    /// The app builds run loggers only through `forRun`. A direct `NetworkLogger(logURL:)`
    /// in the app target would write `unprimed` into its provenance.
    func testTheAppBuildsRunLoggersOnlyThroughForRun() throws {
        let root = Self.repoRoot.appendingPathComponent("NanoTeams")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "NetworkLogger.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("NetworkLogger(logURL:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "build run loggers through `NetworkLogger.forRun`: \(offenders)")
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LLM
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // NanoTeamsTests
        .deletingLastPathComponent()  // repo root
}
