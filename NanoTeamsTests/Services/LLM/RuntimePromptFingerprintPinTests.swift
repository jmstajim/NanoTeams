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
    // failure (a false diagnosis for the transposed-quote shape it met earlier that day), and the
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
    //
    // 2026-09-13 — `b5544fec2e2a8e54`, the native tool-calling wave (task 90 → provider-native
    // `tools`/`tool_calls`). NINE new rows and no rewritten prompt-taught byte: the native
    // chip body (`buildToolSchemaBody/native` — the one-tool rule and the boundary, no
    // lesson, no catalog), the native arms of `planningSalvage`, `reasoningChannel` and
    // `callShapeClause` (a tool to NAME, no envelope to illustrate — an illustration in any
    // text syntax teaches a format the provider's parser never reads, which was task 90's
    // whole defect), `nativeCallRejected` (the server's own sentence quoted, the model's bytes
    // never), `outputTruncated` in both modes (`done_reason: length` with no call — gemma-4's
    // 599-token reasoning loop about a tool the schema did not carry), and the two escalation
    // questions behind their 3- and 2-strike caps. REC.10: the wave's own headless N=2 on
    // both providers, Auto vs Prompt-taught, recorded in the engineering-lessons entry.
    //
    // 2026-09-13, evening — `2c8dbdfd84afa18b`: ONE new row, `leadingEmptyObjectsNote` — the line
    // the model reads on the result of a call it opened with a run of empty `{}` objects
    // (MeditationApp task 94, sixteen times in one step, each answered until then by a
    // missing-name nudge about a name that stood one object later). No prompt-taught byte
    // rewritten. REC.10: the shape appeared in 1 of the 12 A/B runs of that evening; the note's
    // own effect is unmeasured until the shape recurs in a run log (KNOWN_ISSUES, Resolved).
    //
    // 2026-09-13, night — `7d26d97335ae62ff`: the producing `## Final reminder` sentence
    // (`SystemTemplates.producingStepEnding`, two registry rows) names the tool and the field —
    // "Write each deliverable as the `content` of one `create_artifact` call — that is how the
    // step ends." — where it read "Submit each deliverable exactly once — that is how the step
    // ends." REC.10: gemma-4-26b-a4b-qat / LM Studio, Ultra Team, MeditationApp, N=2 per
    // tool-calling mode: before, 15 of 30 producing steps wrote the deliverable as a plain reply
    // first (tasks 95–98; the same habit on a second brief, tasks 103–106); after — the entry
    // in train-first-prompt/RUN_HISTORY.md (Audit 2026-09-13, the reminder entry).
    //
    // 1.9.32, 2026-09-20 — bumped WITHOUT moving this value, and the note spans back to
    // `5b79b329`: 1.9.31 recorded nothing in either ledger, so the gap is stated rather than
    // left to read as continuity. The last entry above is 1.9.11's, which is how long it has
    // been since a runtime prompt text moved.
    //   Проверка — the registry's own input set over the whole span:
    //     git diff --stat 5b79b329..HEAD -- \
    //       NanoTeams/Services/LLM/RuntimePromptRegistry.swift \
    //       NanoTeams/Domain/SystemTemplates.swift → EMPTY.
    //   The range is the benchmark-accuracy wave; it changed no nudge, no Harmony preamble, no
    //   error-note direction and no one-shot prompt. The half that cannot be vacuous is this
    //   test: `RuntimePromptFingerprint.current` folds `RuntimePromptRegistry.entries`, and the
    //   value below still matches on the release tree.
    // 2026-09-20 — MCP, batch C item 12. Seven new rows and nothing existing moved:
    // `ToolErrorCode.allCases` grew by four (`MCP_TOOL_ERROR`, `MCP_TIMED_OUT`,
    // `MCP_SERVER_UNAVAILABLE`, `MCP_DENIED`), two of which the policy answers with a bespoke
    // arm, and the MCP result mapper's own three sentences joined the census — the failure
    // report a server's `isError` becomes, its silent form, and the line that says a content
    // block was returned but not read. Every other sentence in an MCP tool result is the
    // SERVER's, which no fingerprint of this app's code could cover.
    //   Проверка — nothing existing moved:
    //     git diff 4cf97f65..HEAD -- NanoTeams/Services/LLM/ToolErrorNotePolicy.swift
    //   shows two added `case` arms and a threaded parameter; no existing arm's text changes,
    //   and the `INVALID_ARGS` sample renders identically (`requiredArgumentsHint`'s new
    //   `dynamicSchemas` is empty for every registry row).
    // NOT measured live, and the reason is structural rather than a deferral: no role can
    // hold an MCP tool yet. The catalogue reaches a schema (item 11) and a handler (this
    // one), but nothing in the UI can add a server or approve a tool until batch D, so there
    // is no run in which a model could read any of these seven texts. The measurement belongs
    // to the first run that has one — the plan's verification steps 4 and 5, against real
    // servers (REC.10, §7.1: no claim about model behaviour is made here).
    // 2026-09-20 — MCP, batch C item 14. Two more rows and nothing existing moved:
    // `ToolUnavailabilityReason.mcpToolChanged`, the refusal a step gives when the server
    // changed a tool between the step's entry and this call, and the `(none)` direction its
    // code draws — the envelope carries both halves, and the default arm would invite a
    // retry against the one withholding a retry cannot clear (the schema goes on listing
    // the tool for the rest of the step, by design).
    // NOT measured live, for the same structural reason as item 12: no role can hold an MCP
    // tool until batch D, so no run can read this text yet.
    // 2026-09-20 — MCP, batch C item 15. Two new rows and two new TEXTS, and the existing
    // rows are unchanged: `(MCP server <slug>) ` in front of an external tool's description,
    // and a second injection-boundary sentence. Both render only when the call carries an
    // MCP tool, so a sample without one leaves both covered by nothing at all — which is
    // why the rows render `sampleSchema` and `sampleMCPSchema` together, in both modes.
    //   The first boundary's bytes do not move, and that is the point: three tests and the
    // playbook's R3.6.1 Check grep for them. The second sentence exists because the first
    // is scoped to file, command and image content — an upstream artifact and a Supervisor
    // answer also arrive as tool results and ARE sanctioned direction, so a blanket claim
    // would break the pipeline's own semantics. An external server's result is the case
    // that scope leaves out, and the one with an author who chose what to write.
    // NOT measured live, same structural reason as items 12 and 14: no role can hold an MCP
    // tool until batch D, so no run renders either text yet. The measurement is the plan's
    // verification step 7 — `train_first_prompt.sh` with a grant, against the byte-identical
    // render without one.
    // 2026-09-20 — MCP, batch C item 16. Two more rows, nothing existing moved: the gate's own
    // two refusals. Neither rides the `MCP_DENIED` row above — that one renders the POLICY's
    // reason, while these are the sentences a person's decline and a run with nobody to ask
    // produce, and both are third person because the reader is the model ("You declined"
    // would tell it that it refused the call it had just asked to make).
    // NOT measured live, same structural reason as items 12, 14 and 15: the gate is reachable
    // only through a granted MCP tool, and no role can hold one until batch D. The
    // measurement is the plan's verification steps 4 and 5 against the real servers.
    // 2026-09-21 — the sample MCP tool's slug renamed to a generic `design` in three registry rows
    // (`sampleMCPSchema` and the two gate refusals): the app no longer names a third-party
    // service anywhere. No text of this app changed — only the sample server's NAME, which
    // the rows render inside `**mcp__<slug>__…**` and the envelopes' `tool` field.
    //   Проверка: git log -1 -p -S'mcp__design__get_metadata' -- NanoTeams/Services/LLM/RuntimePromptRegistry.swift
    //   shows three one-token edits, all inside a sample name.
    // 2026-09-23 — MCP review wave, group 0. 181 → 194 entries, and all thirteen new rows
    // version text that was ALREADY on the wire: `ComputerUseJudgeService.userPrompt` (twice —
    // the bare fence, and the screen-context lines whose stale note only a context renders),
    // the six `JudgeFailClosedReason` constants, `callFailed` under both subjects,
    // `JudgeReplyChannelPolicy.reasoningOnlyAllowReason`, and each judge's no-reason deny
    // default. Every one of them rides a gate's denial envelope into the conversation, and an
    // edit to any of them moved nothing (#220's failure mode — found by the MCP judge
    // blueprint's §8). They carry `/// runtime-prompt` markers now, so
    // `Ratchet/RuntimePromptCensusPinTests` keeps them registered.
    //   No byte changed: the same commit extracts the two judges' shared call and output
    // contract (`JudgeCall`, `JudgePromptSkeleton`) and this value did not move across the
    // extraction; `JudgePromptGoldenBytesTests` pins both judges' prompts byte for byte.
    // NOT measured live, and nothing to measure: no model-facing text changed, only which of
    // it the version covers.
    // 2026-09-23 — MCP review wave, group A2. 194 → 198 entries, and one existing text moved.
    //   The two new rows are a new executor reason,
    // `ToolUnavailabilityReason.mcpServerNotConnected` (code `mcp_server_not_connected`): its
    // envelope, and the `(none)` direction its code draws — the envelope carries both halves,
    // and `mcp_server_unavailable`'s "Do not retry" would forbid the one retry that can work.
    // It answers an MCP call whose server has no live session — reconnecting after a dropped
    // session, failing, switched off — which until now got `mcp_tool_changed`: "withheld for
    // the remainder of this step: its server changed what this tool does". False on both
    // counts, since nothing changed and the tool works again once the server reconnects
    // (F32, R1.8.5). The iteration's drift check now tells the two apart by the server's
    // status, and the invoker gives the same two refusals at dispatch.
    //   Two more rows from the A2 verification, a third executor reason:
    // `ToolUnavailabilityReason.mcpServerNeedsAttention` (code `mcp_server_needs_attention`) —
    // its envelope, and the direction its code draws ("Do not retry", plus the escalation
    // channel when the role holds one). It answers a server whose credential or address was
    // refused, which the connection never retries: `mcp_server_not_connected`'s "call it again
    // later in this step" invited a call that cannot succeed until a person changes the
    // server's settings.
    //   The moved text is `mcp_tool_changed`'s envelope: it now names a withdrawn approval
    // beside a rewritten or withdrawn tool, and its "The change has not been reviewed" is gone.
    // The dispatch check refuses a call to a tool a person revoked mid-step with this text,
    // and the old one blamed the server for a decision the server never made.
    // NOT measured live: reaching any of these texts needs a granted MCP tool whose server drops
    // its session, has its credential refused, or is edited, while a step runs — deferred in
    // `DEBTS.md` D-M6 (`mcp_servers/telegram_mcp.py`: stopped and restarted for
    // `mcp_server_not_connected`, its token changed on the server side for
    // `mcp_server_needs_attention`, a tool revoked in Settings for `mcp_tool_changed`). REC.10,
    // §7.1: no claim about model behaviour is made here.
    // 2026-09-24 — MCP review wave, group C: the unverified-catalogue refusal. 198 → 200 entries,
    // nothing existing moved. The two new rows are a fourth MCP executor reason,
    // `ToolUnavailabilityReason.mcpToolsBeingReread` (code `mcp_tools_being_reread`): its
    // envelope, and the `(none)` direction its code draws — the envelope carries both halves,
    // like `mcp_server_not_connected`'s. It answers a call whose server's tool list is being
    // read again — a listing that should have read a change failed and is being retried
    // (`MCPServerConnection.catalogueUnverified`); the as-recorded note said "announced a change
    // to its tools", which C-5 corrected below. Group C's third pass had answered that state
    // with `mcp_tool_changed` — "withheld for the remainder of this step … its server changed
    // what this tool does" — and the tool came back in the same step the moment the retry
    // committed (C3 verification, issue 2; R1.8.5). The new text says the list is being read
    // again, leaves a later call open, and names the outcome the re-read itself can produce
    // instead: a re-read that changed the tool, which then answers `mcp_tool_changed` (a person
    // revoking the tool meanwhile answers it too — the text claims no exclusivity).
    // NOT measured live: reaching it needs a granted MCP tool whose server's listing fails while
    // a step runs, after a `list_changed` or once its stated catalogue lifetime runs out —
    // deferred in `DEBTS.md` D-M6 (`mcp_servers/telegram_mcp.py` made to answer one `tools/list`
    // with an error after a `list_changed`; the lifetime path reaches the same envelope,
    // `MCPServerManagerTests.testAStaleSweepWhoseListingFailsWithdrawsTheToolsToo`). REC.10,
    // §7.1: no claim about model behaviour is made here.
    // 2026-09-24 (C-5, same day) — `c4d28bd6b2092be` → this value; 200 entries, one text moved:
    // `mcp_tools_being_reread`'s envelope. The same state is also reached with no announcement —
    // the server's stated catalogue lifetime runs out and the stale sweep's listing fails
    // (`MCPServerManagerTests.testAStaleSweepWhoseListingFailsWithdrawsTheToolsToo`) — so "its
    // server announced a change to the tools it offers" was false there (C4 verification, issue
    // 1; R1.8.5). The envelope now names no cause: "the list of tools its server offers is
    // being read again, and none of that server's tools runs until the read succeeds" — a
    // fact, since the route refuses every call of that server while its catalogue is
    // unverified. The rest of the text is unchanged. NOT measured live, for the reason and
    // under the deferral in `DEBTS.md` D-M6 the note above gives — REC.10, §7.1.
    // 2026-10-28 — `3c799f6e5031d337` → `1fa845ef5cf657ec` (`5ee26dbf`). 200 → 300 entries:
    //   1. `MCPPermissionService.manualModeReason` and the five arms of `reasonForAsking` joined
    //      the census (`LLMExecutionService.mcpNoApproverMessage` composes them into "This call
    //      needs a person's approval (<reason>), and this run has none."). The reasons now
    //      attribute to the server only what it STATED (`statedHints`): a new arm,
    //      `writesAssumed`, reads "the server does not mark this tool read-only, so it is treated
    //      as making changes"; "making destructive changes" needs a stated `destructiveHint: true`,
    //      "making changes" a stated `readOnlyHint: false`.
    //   2. `MCPArgumentCoercion.message` joined the census for header-parameter refusals:
    //      `headerValueOutsideSafeIntegerRange` ("`<property>` is sent to this server as a request
    //      header, and a whole number there must lie between -9007199254740991 and
    //      9007199254740991. Send a number in that range.") and `headerValueIsNaNOrInfinite`.
    //      Header values holding control characters, line/paragraph separators (U+2028/U+2029) or
    //      non-ASCII text are no longer refused — they are sent using the 2026-07-28 revision's
    //      `=?base64?…?=` value encoding and spelled out on the approval card.
    //   3. `mcp_tool_changed`'s envelope now reads "its server changed what this tool does or how
    //      it is called, or stopped offering it, or its approval was withdrawn", covering a server
    //      whose session switches protocol revision mid-step for a tool declaring header
    //      parameters (`MCPToolCall.era`).
    //   4. `DeferredCallReplies.notRun` and `.folderChanged` joined the census (the latter
    //      replacing the unregistered Autovisor `create_task` refusal and answering any Autovisor
    //      action or delegation handler superseded by a folder transition), along with all
    //      Autovisor action replies through the single marked builder `AutovisorReply` (existing
    //      texts, registered for the first time), `AutovisorTeamPolicy.failureMessage`, the
    //      acceptance refusals (`AcceptanceService.validateAcceptance`,
    //      `AutovisorStatus.acceptRejectionAdvice`), and `MCPClientError.inputRequiredMessage` /
    //      `.unknownResultTypeMessage`.
    //   5. Routing changes that move no registered text: an HTTP 4xx carrying a JSON-RPC error
    //      that answers the request reaches the model as the server's own refusal (`MCP_TOOL_ERROR`,
    //      `-32602` as `INVALID_ARGS`) instead of `MCP_SERVER_UNAVAILABLE`; an incomplete modern
    //      `resultType` becomes an error envelope; and a call broken by its own arguments in a run
    //      with no human present goes to `INVALID_ARGS` (`MCPDynamicTool.preflight`) before the
    //      gate asks about human presence (`APPROVAL_UNAVAILABLE`).
    // NOT measured live: deferred in `DEBTS.md` D-M6 and D-36 (REC.10, §7.1: no claim about model
    // behaviour is made here; envelope and policy texts are pinned by `MCPPermissionServiceTests`,
    // `MCPArgumentCoercionTests`, `MCPDynamicToolTests` and `MCPGateTests`).
    //
    // 2026-10-31 (`DEBTS.md` D-M13 pt. 6) — 300 → 306 entries (`64d80073af2ec506`). The
    // Autovisor read-tool envelope builders and fallback messages in `LLMExecutionService+Autovisor`
    // (`autovisorUnavailableMessage`, `taskStatusNotFoundMessage`, `reviewReadyCloseReason`,
    // `renderListTasksEnvelope`, and `renderTaskStatusEnvelope` under `running` and
    // `reviewReadyToClose`) joined the census (`/// runtime-prompt`). No existing text changed;
    // the fingerprint moves only because six previously unversioned builders are now folded in.
    //
    // 2026-10-31 (`DEBTS.md` D-M4, D-M5) — 306 → 310 entries (`9202fbbcc475a5df`). Four new
    // MCP runtime-prompt texts joined the registry:
    //   1. `MCPPermissionService.crossServerTransferReason` (`D-M4` pt. 1) — the policy's ask
    //      reason when a step calls a second MCP server under `.semiAutomatic` after already
    //      using another MCP server in the same step.
    //   2. `MCPToolResultMapper.injectionWarning` (`D-M4` pt. 2) — the deterministic `meta.warnings`
    //      sentence when an MCP tool result matches prompt-injection patterns (`prompt_delimiter`,
    //      `instruction_override`, `directive_injection`).
    //   3. `MCPArgumentCoercion.message/valueOutsideEnum` and `valueOutOfRange` (`D-M5`) — the
    //      `INVALID_ARGS` messages when an MCP argument violates a schema's `enum`/`const` list or
    //      numeric `minimum`/`maximum` bounds.
    // NOT measured live: deferred in `DEBTS.md` D-M6 and D-36 (REC.10).
    //
    // 2026-11-01 (`DEBTS.md` D-M14) — 310 → 321 entries (`c5d82c3b273fe9f8`). Eleven new
    // MCP Auto-judge runtime-prompt texts joined the registry:
    //   1. `MCPJudgeService.systemPrompt` (`.standard` via `oneShotSystemPrompts` plus
    //      `.permissive` and `.strict`), `MCPJudgeService.userPrompt`,
    //      `MCPJudgeService.deniedEnvelopeMessage`, and `MCPJudgeService.parse/denyWithoutReason`.
    //   2. `JudgeFailClosedReason.mcpNoVerdict`, `.mcpUnparseable`, `.mcpPromptTooLarge`, and
    //      `JudgeFailClosedReason.callFailed/MCP tool call` (`Subject.mcp`).
    //   3. `ToolErrorNotePolicy.direction/MCP_JUDGE_UNAVAILABLE` (`ToolErrorCode.mcpJudgeUnavailable`).
    // NOT measured live: deferred in `DEBTS.md` D-M6 and D-36 (REC.10).
    //
    // 2.0.0, 2026-11-01 — released with `c5d82c3b273fe9f8` (321 entries). Compared to 1.9.32
    // (`7d26d97335ae62ff`, `8ba2c389`, 181 entries), the span is the nine MCP-wave movements from
    // `2026-09-20` through `2026-10-28` (`1fa845ef5cf657ec`, 300 entries) plus the three shifts
    // above (`D-M13` pt. 6 → `64d80073af2ec506`, 306 entries; `D-M4`/`D-M5` → `9202fbbcc475a5df`,
    // 310 entries; `D-M14` → `c5d82c3b273fe9f8`, 321 entries — `DEBTS.md` D-36). The remaining
    // 2.0.0 closures (`D-M8`, `D-M9`, `D-M10`, `D-M11`, `D-M12`, `D-M7`, `D-M3`, `D-B16`,
    // `D-B32`, `D-B33`) changed no registered runtime-prompt text.
    //
    // 2026-11-04 (External Autovisor Ш3, `DEBTS.md` D-11) — `AutovisorReply.couldNotPause` added
    // with four durable-state reason samples (`alreadyClosed`, `noActiveRun`, `alreadyPaused`,
    // `notRunning`, 325 `.localModel` entries). Measured live in Ш1/Ш7 via
    // `AutovisorContinuationTrainerTests` for `alreadyPaused` only (`pause_no_engine`) — on a
    // hand-written envelope with production wording but without `meta`; `alreadyClosed`,
    // `noActiveRun` and `notRunning` were not measured (D-36).
    //
    // 2026-11-04 (External Autovisor Ш4, `DEBTS.md` D-42) — `renderListTasksEnvelope` adds
    // `pending_question_count` and `renderTaskStatusEnvelope` adds `pending_questions` alongside
    // `pending_question` from `NTMSTask.answerableSupervisorSteps`. Measured live in Ш1/Ш7 via
    // `AutovisorContinuationTrainerTests` (`roster_two_questions`) — on hand-written `list_tasks` /
    // `task_status` envelopes without `meta`, not compared byte for byte with production (D-36).
    //
    // 2026-11-04 (External Autovisor Ш5) — `AutovisorReply.messageDiscardedTaskFinished` and
    // `AutovisorReply.messageQueuedAndResumed` joined `.localModel` for state-aware `message_task`
    // (`SupervisorMessageQueueService`). Ш1/Ш7 (Run 24/25) fed the model strings Ш1 had written
    // before these texts existed; they were measured live on production bytes in Run 26 on
    // 2026-11-07 (`message_task_on_paused`, `message_task_in_review`, `DEBTS.md` D-36).
    //
    // 2026-11-04 (External Autovisor Ш6, `DEBTS.md` D-15) — `LLMExecutionService.renderChildPausedEnvelope`
    // (`runTimedOut`, `iterationLimitReached`) joined `.localModel` for child self-pause (`status: "child_paused"`).
    // Measured live in Ш1/Ш7 via `AutovisorContinuationTrainerTests` (`delegation_child_paused_timeout`).
    //
    // 2026-11-07 (External Autovisor review, after Ш27) — `7f92a0a917a05e39` → `99107ed2801713a3`,
    // one new `.localModel` row: `AutovisorReply.text/drivenByExternalAgent`, the refusal the
    // built-in manager reads when it acts while an external agent drives its folder. It was an
    // inline literal in `performAutovisorAction` that no row covered ("This work folder's Autovisor
    // driver is set to an external MCP agent."), and before Ш27 it borrowed
    // `ExternalAutovisorReadiness.reason(for: .builtInDriver)`, the external agent's sentence for the
    // opposite state. It now says what happened and what to do next — "Refused: this work folder's
    // Autovisor is now driven by an external agent, so the manager can no longer act here and
    // nothing was changed. End the pass with wait_for_events." — and the gate runs before the
    // self-guard and before the target is loaded. No other text moved.
    // NOT measured live: the refusal is reachable only in a race, since `setAutovisorDriver` is the
    // one writer of the driver and pauses the manager before it switches — unmeasured in
    // `DEBTS.md` D-36 (REC.10, §7.1: no claim about model behaviour is made here).
    // 2026-11-08 (wave 2 of 3) — `99107ed2801713a3` → `fae45ace38da0d0e`: one new SHARED reply,
    // `AutovisorReply.restartWouldOrphanChild`. A role parked on `delegate_to_team` emits nothing
    // while the child runs and `AutovisorStuckEvaluator` calls it `.notStuck` on purpose, so it
    // looks stalled; `restartRole` cascades to downstream roles, never to child tasks, so the
    // restart left the child running with nobody to take its result. Both drivers could do it,
    // hence `.localModel` audience and this fingerprint rather than the external one. No nudge,
    // preamble, error-note direction or one-shot prompt moved.
    // 2026-11-09 (one reading of a call's arguments, wave Ш0) — `fae45ace38da0d0e` →
    // `ca234ed73b014976`. One row joined: `ToolRuntimeError.duplicateArgumentKey`, the refusal
    // for two keys that are one name once trimmed (`{"command":"ls","\ncommand":…}`) — until
    // now the trim kept whichever the dictionary visited last, and the bash gate judged the
    // other one. No existing text moved. NOT measured live (REC.10 deferred by the Supervisor,
    // DEBTS) — the shape is adversarial, not a drift a model produces on its own.
    // 2026-11-09 (the argument vocabulary, the same wave's Ш1) — `ca234ed73b014976` →
    // `db39f884e4358c62`. New rows: `ToolArgumentVocabulary` — the refusal of an argument the tool
    // does not take (`unknownArgumentsMessage`, three shapes), of two spellings of one argument
    // (`twoSpellingsMessage`), the rename and ignore notes (`renameNote`, `ignoredNote`, every
    // alias detail and ignore reason DERIVED from the handlers' tables, so a reworded reason moves
    // this value), the text reading (`notTextMessage`, `readAsTextNote`); the parser's
    // `strandedArgumentsNote`; `SupervisorFormPayload.strayQuestionsNote` (a top-level `questions`
    // beside `form` is said to be ignored — it was dropped in silence); and the type gate's own
    // sentences (`argumentTypeViolations/each`),
    // model-facing since 2026-09-07 and unregistered until now. `AutovisorReply.roleNotWaiting`
    // moved here from the external fingerprint: the built-in manager's `answer_task_question`
    // declares `role_id` now, so it can receive that reply too. No existing text moved. NOT
    // measured live — REC.10 deferred by the Supervisor (DEBTS D-B35); the field emission itself
    // is replayed by `ArgumentTypeGuardTests.testFieldReplay_*`.
    // 2026-11-09 (who paused, wave W1 of the MCP contract) — `db39f884e4358c62` →
    // `c8e3c38f1637a6b1`. Two SHARED replies joined, `AutovisorReply.messageQueuedWhilePausedInTheApp`
    // and `answeredWhilePausedInTheApp`: a message or an answer from an automated Supervisor no
    // longer lifts a Pause pressed in the app — it waits, or lands in the parked step, and the
    // task stays paused until the person resumes it. Until now `message_task`, an answer into
    // the paused step and the queue's backstop each resumed it as a side effect. Both drivers
    // can meet the state, hence `.localModel`. No existing text moved. NOT measured live
    // (REC.10, §7.1): the state is new — before it, the same calls resumed the task.
    // 2026-11-09 (error codes, wave W2 of the MCP contract) — `c8e3c38f1637a6b1` →
    // `22bf206ac1d317f9`. Nine `ToolErrorCode` cases joined — `AUTOVISOR_OFF`, `TASK_NOT_FOUND`,
    // `NOT_OWNER`, `LIMIT_REACHED`, `ARTIFACT_NOT_FOUND`, `ROLE_NOT_FOUND`, `NOT_WAITING`,
    // `TEAM_REFUSED`, `RATE_LIMITED` — and the registry lists one error-note direction per code.
    // Only the hosted MCP server raises them, and its envelopes carry no direction; no in-app
    // tool produces one, so no model in the app can read the new rows. No existing text moved.
    // NOT measured live (REC.10): nothing a local model is sent changed.
    // 2026-11-09 (the review of W1) — `22bf206ac1d317f9` → `a1973020a47d87c1`. One SHARED reply
    // joined, `AutovisorReply.decisionWaitsForThePersonsResume`, said after an accept, a request
    // for changes, a restart or a finish that landed in a task the person paused in the app:
    // those verbs woke the engine, and waking a paused one resumed it, so each lifted the
    // person's Pause as a side effect — the run now stays asleep and the reply says so. Both
    // drivers can meet it, hence `.localModel`. And `ToolErrorCode` gained
    // `REQUEST_IN_PROGRESS` (one more direction row; only the hosted server raises it). No
    // existing text moved. NOT measured live (REC.10, §7.1): the state is new.
    // 2026-11-09 (wave W3 of the MCP contract) — `a1973020a47d87c1` → `87ec3c1afdd03a86`.
    // No prompt wording changed. The registry sample
    // `LLMExecutionService.renderTaskStatusEnvelope/reviewReadyToClose` now renders `elapsed_seconds`
    // 150 instead of 180 because `AutovisorStatus.taskElapsedSeconds` stops on the final step's
    // completion date when all steps are done. The helper is shared with the built-in Autovisor
    // manager, shifting the shared status envelope text. NOT measured live (REC.10, §7.1).
    // 2026-11-10 (F1 + F2 of the MCP contract fixes) — `87ec3c1afdd03a86` → `b7091d4f5b4e6568`
    // → `98445e416f8e76b8`. Corrected 2026-11-12 (F6 C9/T5, `DEBTS.md` D-36): this note used to say
    // F4 moved the value by adding `staleRemedyText` and the bash availability texts — rows of
    // `.externalAgent`, which `current` does not hash. A registry dump at each commit shows the
    // two real rows: F1 (`82c12063`) added `ToolErrorCode.snapshotsUnavailable`, so the per-code
    // loop added `ToolErrorNotePolicy.direction/SNAPSHOTS_UNAVAILABLE` (`b7091d4f5b4e6568`), and
    // F2 (`44c3a309`) added `.folderChanged` → `direction/FOLDER_CHANGED` (`98445e416f8e76b8`).
    // Neither commit moved this constant, so the pin was red from F1 until F4 set it. Both rows
    // are the generic direction; only the hosted MCP server raises these codes, so no model in
    // the app reads them. F3, F4 and F5 moved no `.localModel` text. NOT measured live (REC.10).
    // 2026-11-12 (F6 wave D2, review R1) — `98445e416f8e76b8` → `dc410138b6388be1`. One reply
    // joined, `DeferredCallReplies.voteInterrupted`: what the requester of a `request_changes` reads
    // after a resume when its step was paused, stopped or timed out while the team voted. Until now
    // it read "Change request could not be voted on — the voting meeting did not run: Meeting
    // cancelled." beside a record written `.rejected` (a spent slot), or — when the cancel outlived
    // its wait — `DeferredCallReplies.folderChanged`, about a folder that had not changed. No
    // existing text moved. NOT measured live (REC.10, §7.1): the reply is new.
    // 2026-11-12 (the person's Pause, held in the code; `DEBTS.md` D-M18) — `dc410138b6388be1` →
    // `199fc3ad269c2006`. Two rows join, nothing existing moved: `AutovisorReply.pausedByThePerson`
    // — the refusal of `control_task resume` / `start` and `manage_role correct` on a task the
    // person paused in the app, shared, because the built-in manager is held to the same rule for
    // the person's Pause (not for its own) — and the per-code
    // `ToolErrorNotePolicy.direction/PAUSED_BY_PERSON` row of the new `ToolErrorCode`, the generic
    // direction, which no model in the app reads: the in-app envelope says `COMMAND_FAILED`
    // (D-M18 C9's reasoning: no `(none)` for a code only the hosted server returns). NOT measured
    // live (REC.10, §7.1): the reply is new.
    // 2026-11-13 (an external agent may replace the Work Folder Context; decision A3 revised) —
    // `199fc3ad269c2006` → `d436578fac725f69`. Two rows join and no text moved, as a registry dump
    // before and after shows: `AutovisorToolDecoding.emptyContextDetail`, the refusal of an empty
    // `set_work_folder_context` in the words it had inline, registered now that both surfaces
    // decode the tool; and the per-code `ToolErrorNotePolicy.direction/NOT_ALLOWED` row of the new
    // `ToolErrorCode` — the generic direction, which no model in the app reads, since only the
    // hosted server refuses with it. The Work Folder Context a role reads is no longer cut at 2000
    // characters, and the data sanitizer cleans it (`PromptBuilder.buildWorkFolderContextMessage`):
    // that text is the person's, not a registered one, so neither moves this value. NOT measured
    // live (REC.10, §7.1).
    // 2026-11-13, the same wave's review — `d436578fac725f69` → `a62009905ccdd016`. One row moved, as
    // a registry dump before and after shows: `AutovisorToolDecoding.emptyContextDetail` drops "for
    // every role" ("it replaces the whole work-folder context"): the bundled Personal Assistant and
    // Quest Party read no context, so the clause was not true. The reason the refusal gives — the
    // whole text is replaced — stands. The context's directional marks are now dropped at the seam
    // (`MCPTextSanitizer.sanitizeDisplayedData`) and its headings demoted after any line break: the
    // person's text, not a registered one. NOT measured live (REC.10, §7.1): an empty-text refusal
    // the manager meets only by sending nothing.
    private static let expectedFingerprint = "a62009905ccdd016"

    // 2026-11-04 (External Autovisor Ш2) — `Entry.audience` introduced; no `.externalAgent`
    // entries registered yet, so the external fingerprint starts at the FNV-1a offset basis.
    //
    // 2026-11-04 (External Autovisor Ш4) — `AutovisorReply.roleNotWaiting` (`roleNotWaiting` and
    // `roleNotWaiting/none`) registered under `.externalAgent` (reachable only when `role_id` is
    // supplied on `answer_task_question`).
    //
    // 2026-11-04 (External Autovisor Ш10) — `AutovisorTeamPolicy.failureMessage/externalMCP/*`
    // (10 entries) registered under `.externalAgent`: external-surface team-policy refusals point
    // to `list_teams` and the user instead of the in-app `create_managed_task` description catalog
    // and Supervisor.
    //
    // 2026-11-04 (External Autovisor Ш11) — `ExternalAutovisorReadiness.reason` and
    // `ExternalAutovisorReadiness.whatThePersonMustDo` registered under `.externalAgent`.
    // 2026-11-05 (External Autovisor Ш13) — `NTMSOrchestrator.foreignTaskRefusalMessage`,
    // `alreadyCreatedIdempotentMessage`, and `changedFilesBashNote` registered under `.externalAgent`.
    // 2026-11-05 (External Autovisor Ш17) — `HostedMCPInstructions.text` and
    // `HostedMCPCatalog.toolDescription(for:)` (14 tools) registered under `.externalAgent`.
    // 2026-11-07 (live run of Claude Code, after Ш27) — `cd3594c055e4d634` → `8e387c2301edd91e`:
    // `NTMSOrchestrator.changedFilesBashNote` told the agent to run `git status` / `git diff` in
    // every folder, and the live run's folder was not a git repository. It now says that only files
    // written with the team's file tools are listed and that bash changes need a look at the
    // folder itself (git where there is one). No other external text moved.
    // 2026-11-07 (review after the live run) — `8e387c2301edd91e` → `1eeb1cf1add5c5d6`: the 14
    // tools' input schemas are registered (`HostedMCPCatalog.inputSchemaText(for:)`); until now a
    // property's wording could change without moving `agentTextVersion`. And the `wait_for_events`
    // cursor carries its `task_ids` (`AutovisorEventFeed.formatCursor`): `after` no longer spells
    // the three-part format, and `task_ids` says that a cursor resumes its ids or fewer and starts
    // over with a snapshot for any other task. No tool description or instruction text moved.
    // 2026-11-08 (the goal an external agent never read) — `1eeb1cf1add5c5d6` →
    // `34ab771550febd85`: `HostedMCPInstructions.text` gained "The user's standing direction".
    // `folder_status` has carried `goal` and `memory` since Ш11, and the instructions named
    // neither — so the goal the person types on the Autovisor's start page arrived as an
    // anonymous JSON key with no direction attached, while `limits` and `approvals` were
    // claimed by name from the start. The block says whose words they are, that no tool here
    // changes them, that the goal decides what the agent takes on, and what an absent goal
    // means. No tool description and no schema moved.
    // 2026-11-08 (what the agent receives and no text claimed, wave 1 of 3) —
    // `34ab771550febd85` → `364f056c90e81fda`. An audit of the whole external surface found the
    // #386 shape in bulk: `pause_reason`, `stop_reason`, `cursor_reset_reason`, `chat_mode`,
    // `supervisor_mode`, `acceptance_mode` and `llm.reachable` were all delivered and named in no
    // text the agent reads. Worse than silence in two places: the one `paused` remedy looped
    // forever on `iteration_limit`, and the closing sentence promised an event for the person's
    // every action when the feed has no `answered` and no `accepted` kind. `HostedMCPInstructions`
    // took the four facts that change the main loop and now stands at 4060 of its 4096 ceiling;
    // the rest went into `list_teams`, `list_tasks`, `task_status`, `wait_for_events`, `task_log`
    // and `folder_status` descriptions, which is also where the no-sibling-tool rule applies.
    // 2026-11-08 (wave 2 of 3) — `364f056c90e81fda` → `f7ec69798ffd2a09`: three refusals that
    // were written for the built-in manager now have external wordings.
    // `openTaskLimitReached` / `creationWindowLimitReached` split what was one
    // `creationLimitReached` — the manager's per-REVIEW cap, whose remedy ("review or finish
    // existing tasks") frees an OPEN slot and cannot refill a sliding window, so an agent that
    // obeyed it retried into the identical refusal; the ledger's `windowMinutes` had been
    // discarded with a `_` and is now named. `notWaitingForInputExternal` says that a question
    // may have been answered by the person — the feed has no `answered` kind, so nothing else
    // reports it — and points at `task_log`'s `from`. Also, a write refused by readiness now
    // carries `whatThePersonMustDo` beside `reason`: the fix, not only the fact.
    // 2026-11-08 (wave 3 of 3) — `f7ec69798ffd2a09` → `b2809eef3528a9d`: the fields the folder
    // held and never forwarded now exist, and each is claimed by its own tool's description.
    // `folder_status` gained `work_folder_context` (the prose that rides EVERY role's system
    // prompt, with the instruction files injected into it versus merely listed), `auto_off` (the
    // sleep deadline, counted from the AGENT's last request) and `xcode_scheme` (absent strips
    // both build tools from every role). `task_status` gained `run_id` / `run_count`,
    // `pause_reason`, `recurrence` and a step's `delegated_task_id`; `list_tasks` gained
    // `next_run_at`; `task_log`'s `change_request` rows carry the vote's status. No instruction
    // text moved — it is full at 4060 of 4096.
    // 2026-11-08 (folder_id and the server's own next hints, a live External Autovisor session) —
    // `b2809eef3528a9d` → `ef5e914e79822842`. A refused `folder_id` is typed
    // (`ExternalFolderRefusal`, now registered per case): a missing one says where the id comes
    // from and points at `folder_status`; an id that is not the open folder says exactly that, with
    // the same next call, where it borrowed the race reply "The work folder changed while this
    // action was running"; a read made during an open or with no folder open answers with the
    // readiness sentences a write gets. The race reply is kept for a real change during the call.
    // Descriptions stopped restating their inputs — `create_managed_task` listed eight and not
    // the required `folder_id` — so `create_managed_task`, `control_task`, `manage_role`,
    // `answer_task_question`, `message_task`, `schedule_task` and `wait_for_events` lost their
    // parameter lists, and the sentences that named an input moved onto it (`answer` carries the
    // Q1/Q2 grammar, `manage_role.action` what each verb does, `wait_for_events.after` how to
    // resume); `timeout_seconds` and `limit` no longer say "default 50". The hints themselves are
    // completed on the way out (`HostedMCPNextHintCompletion`: the proven `folder_id`, integer
    // `task_id`), which moves no registered text. No instruction text moved.
    // NOT measured live (REC.10, §7.1): no claim about agent behaviour is made here.
    // 2026-11-08 (`folder_status.event_cursor`, the same live session) — `ef5e914e79822842` →
    // `f335ddcd23ef0a93`. The cursor is the feed's HEAD: a wait from it scans only what is
    // appended after it, and the conditions already standing are materialized only by a call
    // with no cursor — so a session that resumed from it never heard of the question or review
    // already waiting. `folder_status` called it the "current event cursor"; it now says that
    // waiting from it yields only events after now and that what already stands is not among
    // them. `wait_for_events.after` says to omit it on a session's first call and then pass the
    // cursor the previous call returned. The feed is unchanged — re-snapshotting on this cursor
    // would reset what the agent was already told and deliver it all again. No instruction text
    // moved. NOT measured live (REC.10, §7.1).
    // 2026-11-08 (auto-off under a parked wait, the same live session) — `f335ddcd23ef0a93` →
    // `47038fb8af7f4d9a`. Activity was noted only when a call STARTED and the minute tick never
    // asked whether a wait was parked, so a sleep timer that may be a minute long turned the
    // Autovisor off under a wait of up to an hour and woke it with `not_ready`. Now activity is
    // noted again when a call ends, and under the external driver a wait in progress at the
    // deadline counts as activity and re-arms the timer. `folder_status`' `auto_off` sentence
    // says so: it counts from the end of your last call, and a wait still in progress counts as
    // activity — it said "counts from your last request". No instruction text moved. NOT
    // measured live (REC.10, §7.1).
    // 2026-11-09 (the argument vocabulary) — `47038fb8af7f4d9a` → `6508c210941e0443`. The hosted
    // tools refuse an argument their published schema does not declare
    // (`HostedMCPCatalog.undeclaredArgumentsRefusal`, worded by
    // `ToolArgumentVocabulary.unknownArgumentsMessage/externalMCP`); `folder_id` stays accepted on
    // `list_teams` / `list_tasks`, which check it without publishing it. `roleNotWaiting` left
    // this audience for the shared one (see above). The `schedule_task` refusal no longer offers
    // `interval_minutes`, which the published schema never declared. NOT measured live (REC.10,
    // §7.1).
    // 2026-11-09 (who paused, wave W1 of the MCP contract) — `6508c210941e0443` →
    // `29ccace832650280`. `wait_for_events` lists `resumed` and no `created` — only the agent
    // that creates a task owns it, so the event could only echo its own call — says that
    // `resumed`, `closed` and `deleted` carry `by` and that what the agent did itself is never
    // echoed, adds `by_agent` to the pause reasons, and says a snapshot's events carry no `seq`.
    // `task_status` names the five reasons; `folder_status` names `readiness.changed_by` and
    // `since`. The two shared replies above are `.localModel` and move the other fingerprint.
    // No instruction text moved. NOT measured live (REC.10, §7.1).
    // 2026-11-09 (the review of W1) — `29ccace832650280` → `ae5a0f2843cb657f`. One new external
    // reply: `requestInProgressMessage`, the refusal of a create whose `request_key` names a
    // creation still under way (`REQUEST_IN_PROGRESS`, next `list_tasks`) — the key was read only
    // from an in-memory map until now, so a retry in that window, or after a relaunch, made a
    // second task. `create_managed_task.request_key` now says how long a key holds: while the
    // task exists, across app restarts. NOT measured live (REC.10, §7.1).
    // 2026-11-09 (wave W3 of the MCP contract) — `ae5a0f2843cb657f` → `1022757064629152`.
    // Updated catalog tool descriptions and schemas for `list_tasks`, `task_status`,
    // `task_result`, and `task_log`: unified external status names matching wire events, moment
    // cursors (`after`, `next_before`, `next_after`), chronological `recent_messages` without
    // `role_id`, per-step `phase`, `model`, `llm_retry`, `awaiting_approval`, and owner-only
    // `request_key`. NOT measured live (REC.10, §7.1).
    // 2026-11-09 (wave W4 of the MCP contract) — `1022757064629152` → `90bc64dde778a1df`.
    // Updated catalog tool descriptions and schemas for `create_managed_task`, `schedule_task`, and
    // `control_task`: one-shot vs repeating startup rules, local time for `run_once_at` without offset,
    // 09:00 for `repeat_monthly_day` without time, `timeout_seconds` with per-run start accounting and
    // watchdog scope (note: interval_minutes was never on the external schema surface). NOT measured live (REC.10, §7.1).
    // 2026-11-10 (wave W7 of the MCP contract, incorporating W5 external text changes) — `90bc64dde778a1df` → `57e880a1f1752368`.
    // Added 15th hosted tool `task_changes`: registered tool description and schema with relative
    // file path filtering, file-based pagination without truncation, and explicit warning that changes
    // reflect all work folder alterations during the execution pass; incorporated W5 descriptions for
    // `list_teams` and `include_context`. NOT measured live (REC.10, §7.1).
    // 2026-11-10 (wave W6 of the MCP contract) — `57e880a1f1752368` → `7814470d6df5c3ac`.
    // HostedMCPInstructions updated (pause causes by_person/by_agent/timed_out, cursor from last
    // response, event authorship `by` and self-echo suppression, next suggestions on error, restart
    // reconnection advice, single-turn client polling), HostedMCPCatalog tool descriptions and schemas
    // updated for `control_task` (lifecycle verbs in action property, timeout_seconds), `manage_role`
    // (discarding on restart, surviving comments), and `create_managed_task` (asynchronous background
    // start, team_id source and active team fallback, title derivation). NOT measured live (REC.10, §7.1).
    // 2026-11-10 (F2 of the MCP contract fixes, `44c3a309`) — `7814470d6df5c3ac` →
    // `f4d8a60d736ae4d2`, recorded 2026-11-12 (F6 C9/T5): the `task_changes` description dropped
    // "including concurrent edits from other tasks or external processes" and named the
    // exclusions instead (F6 N15 put the first half back). F2 did not move this constant either.
    // 2026-11-11 (Milestone F4 Wave 4, `9aff09a4`) — `f4d8a60d736ae4d2` → `2ab0b898004ba35d`.
    // HostedMCPCatalog and tool schemas updated for Milestone F4: folder_status exposes stale and
    // what_the_person_must_do, bash availability renamed to allow_rules_unattended, removed unnamed
    // constants (judge_failure_code, top-level cross_server_transfer, agent.present), and per-server
    // cross_server_transfer documentation. NOT measured live (REC.10, §7.1).
    // 2026-11-11 (Milestone F5 Wave 5) — `2ab0b898004ba35d` → `2b0ac8a8fc0f8c5f`.
    // Catalog updates (waitForEvents timeout tasks heartbeat, taskStatus round_summary, taskChanges fields,
    // controlTask deduplication, team_id catalog source without sibling tool mention), HostedMCPInstructions
    // update (point pass diffs to task_changes), and census registration of 5 agent-facing string clusters
    // under .externalAgent (AutovisorReply.createdScheduled with/without date, llmUnreachableWarning, bash
    // whatThePersonMustDo remedies, setTimeoutRefusal cases, and task_changes refusal cases). NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave B1, snapshots) — `2b0ac8a8fc0f8c5f` → `44239e3f0e54f37a`. The
    // `task_changes` description says ignore rules are read as they stood when the pass started
    // (a rule written during it hides nothing until the next pass; the edited ignore file is a
    // change), names an enclosing repository's rules, the page-file fields `binary` and
    // `encoding` (`not_utf8`), the `<0xNN>` / `<U+XXXX>` spellings, and `not_tracked` entries as
    // a path and a reason; `file_path` says "as listed in files". Three new `meta.warnings`
    // builders registered (`TaskChangesWarnings`: hidden characters in a name, in a diff, a
    // file that is not UTF-8). NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave B1, review of «missed») — `44239e3f0e54f37a` → `ec48d5dc599a3dfc`.
    // The `task_changes` description says a directory the pass created that a rule written
    // during the pass covers is listed in `not_tracked` (trailing `/`, contents not read)
    // instead of shown, and that `hidden_by_round_rules` also names a file past the limit on
    // such files, or their directories when they are many. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave B2, snapshot store integrity) — `ec48d5dc599a3dfc` → `6f4226fa1aac05ae`.
    // One new `meta.warnings` builder registered: `TaskChangesWarnings.storeRestored`, the line a
    // `task_changes` page carries when the snapshot store was altered behind NanoTeams while the
    // pass was open (config, `info/` entries, alternates, hooks, `commondir` — fixed labels) and
    // was restored before any snapshot was taken or read. No description or instruction text
    // moved. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave C, snapshot resilience) — `6f4226fa1aac05ae` → `f2b56def5d573a98`.
    // Four new `meta.warnings` builders registered: `TaskChangesWarnings.lateStartSnapshot` (the
    // snapshot that opened the pass finished after it began) and `endSnapshotMissing` for
    // `timed_out`, `failed` and `completed_late` (the snapshot taken when the pass ended did not
    // land in time), read off the round's `Run.snapshotFailures`. No description or instruction
    // text moved. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave D1, one process per folder) — `f2b56def5d573a98` → `16b84b501423a0ad`.
    // A new readiness state `folder_in_use` — the folder is open in another NanoTeams process, so
    // this one opened nothing (`ExternalAutovisorReadiness.Refusal.folderInUse`: its reason and
    // what the person must do), the read refusal for it (`ExternalFolderRefusal.folderInUse`,
    // the same sentence, no next call), and the relay's answer when NanoTeams runs but its server
    // does not (`HostedMCPStdioRelay.serverNotAnsweringMessage` — it starts no second NanoTeams).
    // No description or instruction text moved. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (F6 wave D2, F3/F4 remainder) — `16b84b501423a0ad` → `26f303fd5e81b546`.
    // `folder_status` says what each availability value means (bash `allow_rules_unattended`
    // renamed `read_only_and_allow_rules`: read-only commands run too) and both values of a
    // server's `cross_server_transfer`; `include_context` no longer states what an omitted flag
    // equals; `timeout_seconds` says which run refuses a value at or below its age;
    // `task_status` names the schedule's `next_run_at` / `last_run_at` (were `next_fire_at` /
    // `last_fired_at`), and says a rule with no future occurrence reads back `enabled false` (it
    // said the whole `recurrence` went absent, which no path does). Two builders registered:
    // `timeoutNotPastElapsedMessage` (the set_timeout refusal, inline until now) and
    // `LLMRetryNotice.text` (`llm_retry`, one period before "Retrying"). NOT measured live
    // (REC.10, §7.1).
    // 2026-11-12 (F6 wave D2, review R4–R6) — `26f303fd5e81b546` → `e6e6162a5b1124fe`.
    // `list_tasks` and `task_status` list `acceptance_gate` among a task's statuses (the mapper
    // sent it; the lists had seven values), and `list_tasks` says what it means. `folder_status`:
    // a deny rule or the Auto judge may refuse a call under any availability, and
    // `read_only_and_allow_rules` excepts what an ask rule matches; to stay within the 2048-
    // character cap, the `llm.reachable` and `xcode_scheme` sentences say the same in fewer words.
    // Two builders
    // registered: `ExternalAutovisorApprovals.computerUseWhatThePersonMustDo` (both withheld
    // reasons — computer use carried no `what_the_person_must_do`, which the text promised) and
    // `ExternalAutovisorOperations.continuationPausesAtOnceWarning` (a `set_timeout` reply for a
    // run in review or failed that began longer ago than the value); `timeout_seconds` says the
    // reply carries `deadline_at` and `remaining` only for a run still going. NOT measured live
    // (REC.10, §7.1).
    // 2026-11-12 (F6 wave E1, L1/T2–T4, T11, S6, N15) — `e6e6162a5b1124fe` → `7e43fa66c09aa1c0`.
    // Every refusal of the external surface names a next call: 27 named calls with their reasons in
    // one builder, `ExternalNextCall.reason` (about thirty inline literals until now, none
    // registered), and a refusal that names none gets its code's at the exit seam
    // (`ExternalNextCall.ensuringNext`). `NOT_OWNER` points at `task_status`, `FOLDER_CHANGED` and
    // the folder states at `folder_status`, `schedule_task` / `set_timeout` refusals at the task's
    // `task_status`, `LIMIT_REACHED` on create at `list_tasks`, `RATE_LIMITED` at the same call.
    // The `set_timeout` and `task_changes` refusals are registered through the builders production
    // calls (`ControlVerb.refusalMessage`, `TaskChangesRefusal`), texts unchanged. `task_result`'s
    // `changed_files_note` points at `task_changes`, not `git status`. `task_status` names the
    // round summary's fields and what another's task withholds; `task_changes` says whose changes
    // it shows and that ignored files are not listed. An unknown tool name points at
    // `folder_status`, not back at itself. Two rows renamed for the builders they render
    // (`ExternalAutovisorApprovals.bashWhatThePersonMustDo`, `NTMSOrchestrator.staleRemedyText`),
    // texts unchanged. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (review of F6 wave E1, R1–R8) — `7e43fa66c09aa1c0` → `c04a921539df4bd5`.
    // `ExternalNextCall.reason`: an undeclared argument's next says to send each value under one
    // of the arguments the message lists, or without it (it said to drop them, beside a message
    // offering the rename); `FOLDER_CHANGED`'s says the message tells what the call did before
    // the change (it said "nothing was done", which a create that had made its task contradicted).
    // One builder registered: `NTMSOrchestrator.createdBeforeFolderChangedMessage`, the refusal of
    // a create whose folder changed after the task existed (names the task, `details.task_id`).
    // `task_changes` names the person's global git excludes file and the places NanoTeams hides
    // from a team's tools among what is never listed. NOT measured live (REC.10, §7.1).
    // 2026-11-12 (the person's Pause, held in the code; `DEBTS.md` D-M18) — `c04a921539df4bd5` →
    // `dc1aebe1a536173a`. `HostedMCPInstructions`: `by_person` reads "only the user can resume it,
    // so tell them and wait for resumed" (was "do not resume, tell user and wait — resumed will
    // follow" — a request, now a fact the code holds; 4081 → 4088 of 4096). `control_task` says a
    // pause the person made only they lift and that resume and start refuse it with
    // `PAUSED_BY_PERSON`; `manage_role`'s `correct` says it resumes and is refused on the person's
    // pause; `message_task` no longer claims to resume every paused run. One next call joins,
    // `ExternalNextCall.reason/personsResume` (`wait_for_events`: the person's `resumed` follows).
    // NOT measured live (REC.10, §7.1).
    // 2026-11-13 (an external agent may replace the Work Folder Context; decision A3 revised) —
    // `dc1aebe1a536173a` → `2da8c87bac21c1a1`. A sixteenth tool, `set_work_folder_context`: its
    // description and input schema (`folder_id`, `content`, an optional `expected_updated_at`);
    // its refusals — `NOT_ALLOWED` until the person allows the agent
    // (`contextReplacementNotAllowedMessage`, the remedy in `details.what_the_person_must_do`),
    // characters that change how text displays (`contextHiddenCharactersDetail`), a stamp that is
    // none (`contextStampNotAStampDetail`), a context replaced since it was read
    // (`AutovisorReply.workFolderContextChangedSinceRead`, both arms); and two next calls,
    // `personMustAllow` (the same call, once the person has allowed it) and `currentContext`
    // (`folder_status`). `folder_status`: the context rides the prompt of every role on a team
    // whose `reads_work_folder_context` is true — "EVERY role's", until now, was not true of the
    // Personal Assistant or Quest Party — and `stale` means project files changed since it was
    // written (a team's own artifacts made it true until now); its `what_the_person_must_do` went,
    // and `NTMSOrchestrator.staleRemedyText` with it. `list_teams` says what
    // `reads_work_folder_context` false means for a brief. The instructions did not move. NOT
    // measured live (REC.10, §7.1).
    // 2026-11-13, the same wave's review — `2da8c87bac21c1a1` → `287cadf77c5d4ef`. The precondition
    // is the text's revision, required, not the optional whole-second stamp, which a context never
    // stamped, two saves in a second and an omitted argument all slipped: the input schema names
    // `expected_revision` and requires it; `contextRevisionNotARevisionDetail` replaces
    // `contextStampNotAStampDetail`; `AutovisorReply.workFolderContextChangedSinceRead` names no
    // revision or stamp — one copied from a refusal would replace a text nobody read — so its
    // never-written arm went; `ExternalNextCall.reason/currentContext` says `folder_status` returns
    // the revision. `ExternalNextCall.reason/personMustAllow` no longer promises the same call goes
    // through ("ask them, then call it again"): nothing else the call sent was read.
    // `contextHiddenCharactersDetail` names directional marks, now refused. NOT measured live
    // (REC.10, §7.1).
    // 2026-11-14 (2.0.0 release audit) — `287cadf77c5d4ef` → `735e299125a7ebb3`.
    // `set_work_folder_context`'s description said "the one replaced is not kept"; copies of the
    // old text stay in the agent's own `folder_status` read (`external_calls/`) and in the roles'
    // prompts (`network_log.jsonl`), so it now says no earlier version is kept to restore. The
    // instruction to start from the current text and keep what is still true did not move. NOT
    // measured live (REC.10, §7.1).
    private static let expectedExternalAgentFingerprint = "735e299125a7ebb3"

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

    func testExternalAgentPromptText_hasNotChangedWithoutRecordingIt() {
        let actual = RuntimePromptFingerprint.externalAgent
        XCTAssertEqual(
            actual, Self.expectedExternalAgentFingerprint,
            """
            An external-agent runtime text changed (Hosted MCP instructions, tool descriptions, \
            or external-only replies — see RuntimePromptRegistry `.externalAgent`).
            
            1. Note the change above `expectedExternalAgentFingerprint`.
            2. Set `expectedExternalAgentFingerprint` in this test to: \(actual)
            """
        )
    }

    func testExternalAgentPromptRegistry_includesAllAgentFacingClusters() {
        let externalEntries = Set(RuntimePromptRegistry.entries.filter { $0.audience == .externalAgent }.map(\.name))

        // 1. created_scheduled reply (with and without date)
        XCTAssertTrue(externalEntries.contains("AutovisorReply.createdScheduled/withDate"), "missing createdScheduled with date")
        XCTAssertTrue(externalEntries.contains("AutovisorReply.createdScheduled/withoutDate"), "missing createdScheduled without date")

        // 2. LLM unreachable warning
        XCTAssertTrue(externalEntries.contains("ExternalAutovisorOperations.llmUnreachableWarning"), "missing llmUnreachableWarning")

        // 3. Bash what_the_person_must_do remedies
        XCTAssertTrue(externalEntries.contains("ExternalAutovisorApprovals.bashWhatThePersonMustDo/switched_off"), "missing switched_off bash remedy")
        XCTAssertTrue(externalEntries.contains("ExternalAutovisorApprovals.bashWhatThePersonMustDo/no_approver"), "missing no_approver bash remedy")

        // 4. set_timeout refusals — through the builder `ControlVerb.parse` calls (F6 T3)
        for name in ["actionNotSetTimeout", "argWithSetTimeout", "negativeTimeout", "invalidValue", "missingValue"] {
            XCTAssertTrue(externalEntries.contains("ControlVerb.refusalMessage/\(name)"), "missing \(name) refusal")
        }

        // 5. task_changes refusals — through the builders production calls (F6 T3)
        for name in [
            "invalidFilePath", "invalidPage", "invalidPageSize", "invalidRoundArgument", "invalidPageArgument",
            "protectedWorkFolder", "snapshotsUnavailable", "roundDoesNotExist",
        ] {
            XCTAssertTrue(externalEntries.contains("TaskChangesRefusal.\(name)"), "missing \(name) refusal")
        }

        // 6. the next call of every refusal (F6 L1/T4)
        for call in ExternalNextCall.allCases {
            XCTAssertTrue(externalEntries.contains("ExternalNextCall.reason/\(call.rawValue)"), "missing \(call) next reason")
        }
    }

    func testFingerprint_isStableWithinAProcess() {
        XCTAssertEqual(RuntimePromptFingerprint.current, RuntimePromptFingerprint.current)
        XCTAssertEqual(
            RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries, audience: .localModel),
            RuntimePromptFingerprint.current
        )
        XCTAssertEqual(RuntimePromptFingerprint.externalAgent, RuntimePromptFingerprint.externalAgent)
        XCTAssertEqual(
            RuntimePromptFingerprint.compute(RuntimePromptRegistry.entries, audience: .externalAgent),
            RuntimePromptFingerprint.externalAgent
        )
    }

    func testExternalAgentEntry_movesExternalFingerprintWithoutMovingLocalFingerprint() {
        var entries = RuntimePromptRegistry.entries
        entries.append(
            RuntimePromptRegistry.Entry(name: "SyntheticExternalEntry", audience: .externalAgent) {
                "External agent synthetic text."
            }
        )
        XCTAssertEqual(
            RuntimePromptFingerprint.compute(entries, audience: .localModel),
            RuntimePromptFingerprint.current,
            "adding an .externalAgent entry must not move the local-model fingerprint"
        )
        XCTAssertNotEqual(
            RuntimePromptFingerprint.compute(entries, audience: .externalAgent),
            RuntimePromptFingerprint.externalAgent,
            "adding an .externalAgent entry must move the external-agent fingerprint"
        )
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
        XCTAssertGreaterThanOrEqual(names.count, 333, "anti-vacuum: 333 entries on 2026-11-04")
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
