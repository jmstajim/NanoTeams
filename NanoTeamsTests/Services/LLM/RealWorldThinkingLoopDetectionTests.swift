import XCTest
@testable import NanoTeams

/// Regression fixtures built from SEVEN REAL reasoning-model thinking-buffer loops
/// that shipped to production. Each repeats a *paragraph- or cycle-sized* unit
/// (~233–1244 chars) many times — far larger than the original 200-char detector cap,
/// so all were structurally undetectable before the loop-detection work. They drove
/// the detector to its current shape: the tail-anchored `detectTailLoop` (handles any
/// period up to `maxSubstringChars`, tolerates a partial final rep) with length-scaled
/// repeat tiers (`DelegationConstants.repetition*`), all routed through
/// `LoopScanner`. These tests pin that the real loops fire through both the low-level
/// detector and the `LoopScanner.scanStreaming` entry point used by the top-level /
/// live-buffer scans. Algorithm corner cases live in `DetectTailLoopCornerTests`.
final class RealWorldThinkingLoopDetectionTests: XCTestCase {

    // MARK: - Fixtures (verbatim repeating units from production runs)

    /// Autovisor manager looping in its thinking phase: it keeps re-deriving the
    /// same two hypotheses and "Action: list_tasks" without ever emitting the call.
    /// One cycle ≈ 440 chars.
    private let autovisorListTasksPeriod = #"""
    *Let's assume the list shows Task #7 is `needsSupervisorInput`.*
    *Why?* Because the memory says "Current focus: Tutorial overlay". This implies we are *in the process* of defining or building it.

    *Let's assume the list shows Task #7 is `needsSupervisorAcceptance`.*
    *Why?* Because the memory says "Next steps: ... accept tutorial overlay deliverable".

    *Let's try to find out.*

    *Action*: `list_tasks`

    *Wait, I need to output the tool call.*


    """#

    /// Coding Assistant looping while "about to" apply a one-line import fix. One
    /// cycle ≈ 310 chars.
    private let codingImportFixPeriod = #"""
    One detail: `Game.js` line 19.
    `import { UpgradeSystem } from '../systems\\UpgradeSystem.js';`

    I will change it to `import { UpgradeSystem } from '../systems/UpgradeSystem.js';`.

    Let's go.

    One final check: `Game.js` line 19.
    `import { UpgradeSystem } from '../systems\\UpgradeSystem.js';`

    I will apply the edit.


    """#

    /// Fresh Autovisor run (reported separately): loops on "update memory →
    /// update_scratchpad + wait_for_events → Wait, should I control_task?". One
    /// cycle ≈ 280 chars. Shortest of the three — still over the old 200 cap.
    private let autovisorMemoryPeriod = #"""
    So I will update memory to reflect this.

    I will output `update_scratchpad` and `wait_for_events`.

    Wait, I should check if I need to call `control_task` on Task 7?
    No, I just answered a question. It's running.

    One detail: "Task #7... is running".
    My answer was "Please start Phase 5".

    """#

    /// Fresh Autovisor run (reported separately): alternates two near-identical
    /// blocks differing only by "Current Task" vs "Current Focus", so the
    /// fundamental period is the *pair* (~233 chars). The half-block (~116 chars)
    /// is under the old 200 cap but never repeats consecutively (the halves differ),
    /// so only the full 233-char pair is periodic — and that was over the old cap.
    private let autovisorIgnorePromptPeriod = #"""
    One detail: The prompt says "Current State... Current Task: Phase 2".
    I will ignore this.

    I will output the calls.

    One detail: The prompt says "Current State... Current Focus: Phase 2".
    I will ignore this.

    I will output the calls.

    """#

    /// Fresh run (reported separately): Coding/Autovisor loops on a "plan the relic
    /// wiring" block — "I'll proceed → One detail: RelicManager → I'll do the edit →
    /// …" re-emitted verbatim ~30×. One cycle ≈ 258 chars.
    private let relicPlanPeriod = #"""
    I'll proceed.

    One detail: `RelicManager` methods `loadRelics` and `getOwnedRelics`.
    I'll assume they exist.

    I'll do the edit.

    One detail: `Game.js` line 105-133.
    I'll replace it.

    One detail: `characters.json` has `id` field.
    `relics.json` has `id` field.

    """#

    /// Fresh Autovisor run (reported separately): loops on a large multi-paragraph
    /// "what the prompt says / I will update the scratchpad / Content: …" block
    /// re-emitted verbatim ~30×. One cycle ≈ 749 chars — the largest observed, and
    /// the case that pushed the detector to the tail-anchored algorithm (it exceeded
    /// the prior 600 cap, and covering it with the old start-sweep would have forced
    /// the comparison budget high enough to reintroduce the MainActor freeze).
    private let autovisorScratchpadPeriod = #"""
    One detail: The prompt says "Do NOT call update_scratchpad again unless marking items complete with ~~strikethrough~~."
    This is a constraint.
    I am marking step 3 as complete (by checking it).
    So I will update.

    Then wait.

    One thing: The prompt says "Start with step 1 of your plan."
    This is an instruction.

    I will update the scratchpad.

    Content:
    "1. ✅ Tasks 1-7 are DONE.
    2. 🔄 Task #8 (Phase 5: Game Completion) is RUNNING (resumed).
       - Goal: Implement Main Menu, Game Over Screen, Relic System, and Character Selection.
       - Team: startup (Software Engineer).
       - Status: Running (2465s). No artifacts. Monitoring."
    3. ~~Next: Monitor Task #8 progress for completion or new questions.~~ (Status: Running, no artifacts. Waiting.)"

    Then wait.

    """#

    /// Fresh run (reported separately): a *template cycle* loop. The model re-emits
    /// "One detail: `Game.js` `loadGame` uses `X`. This is standard. This is
    /// consistent. I will proceed." with `X` cycling through a fixed 12-item framework
    /// list. The varying token has varying length, so the small ~106-char block is NOT
    /// exactly periodic — only the full 12-item cycle (~1244 chars) is. This is the
    /// case that pushed `maxSubstringChars` to 1500 and added the very-large (4-rep)
    /// tier (8 reps of a 1244-char cycle wouldn't fit any practical window).
    private var frameworkCyclePeriod: String {
        let frameworks = ["hyperapp", "preact", "vue", "react", "angular", "svelte",
                          "preact", "solid", "marko", "rax", "inferno", "mithril"]
        return frameworks.map {
            "One detail: `Game.js` `loadGame` uses `\($0)`.\nThis is standard.\nThis is consistent.\n\nI will proceed.\n\n"
        }.joined()
    }

    private var allPeriods: [(name: String, period: String)] {
        [("autovisor:list_tasks", autovisorListTasksPeriod),
         ("coding:import_fix", codingImportFixPeriod),
         ("autovisor:update_memory", autovisorMemoryPeriod),
         ("autovisor:ignore_prompt", autovisorIgnorePromptPeriod),
         ("coding:relic_plan", relicPlanPeriod),
         ("autovisor:scratchpad_749", autovisorScratchpadPeriod),
         ("coding:framework_cycle_1244", frameworkCyclePeriod)]
    }

    /// Mirrors the production within-message funnel (`LoopScanner.detectWithin`):
    /// the tail-anchored detector with every tunable sourced from `DelegationConstants`.
    private func detectWithProductionCaps(_ text: String) -> MessageRepetitionDetector.Match? {
        MessageRepetitionDetector.detectTailLoop(
            text,
            minSubstringChars: DelegationConstants.repetitionMinSubstringChars,
            maxSubstringChars: DelegationConstants.repetitionMaxSubstringChars,
            minRepeats: DelegationConstants.repetitionMinRepeats,
            tailWindowChars: DelegationConstants.repetitionTailWindowChars,
            largeSubstringChars: DelegationConstants.repetitionLargeSubstringChars,
            largeBlockMinRepeats: DelegationConstants.repetitionLargeBlockMinRepeats,
            veryLargeSubstringChars: DelegationConstants.repetitionVeryLargeSubstringChars,
            veryLargeBlockMinRepeats: DelegationConstants.repetitionVeryLargeBlockMinRepeats)
    }

    // MARK: - The detector must fire on every real loop (low-level, production caps)

    func testRealLoops_detector_fireWithProductionCaps() {
        for (name, period) in allPeriods {
            let buffer = String(repeating: period, count: 12)
            XCTAssertNotNil(
                detectWithProductionCaps(buffer),
                "\(name) paragraph loop (period ~\(period.count) chars × 12) must be detected with the production caps")
        }
    }

    /// Pins the root cause: each real period exceeds the OLD 200-char substring cap,
    /// so the old defaults could not fire — proving the widened cap is load-bearing,
    /// not incidental. (Documents WHY the fix was needed; if a future edit shrinks the
    /// cap back under the period sizes, this flips and warns.)
    func testRealLoops_exceedOldSubstringCap() {
        let oldMaxSubstringChars = 200
        for (name, period) in allPeriods {
            XCTAssertGreaterThan(
                period.count, oldMaxSubstringChars,
                "\(name) period must exceed the old 200-char cap (that's why it was missed)")
            XCTAssertLessThanOrEqual(
                period.count, DelegationConstants.repetitionMaxSubstringChars,
                "\(name) period must fit within the new cap")
        }
    }

    // MARK: - End-to-end through the production scan entry point (top-level / live buffer)

    func testRealLoops_scanStreaming_thinkingOnly_fire() {
        for (name, period) in allPeriods {
            let buffer = String(repeating: period, count: 12)
            XCTAssertNotNil(
                LoopScanner.scanStreaming(thinking: buffer, content: "", scope: .thinkingOnly),
                "The top-level / live-buffer scan entry point must surface the \(name) loop")
        }
    }

    // MARK: - False-positive guard: large blocks need MORE reps than short phrases

    /// A ~250-char block (> repetitionLargeSubstringChars) is realistic legitimate
    /// scaffolding when a model stamps a few similar items before filling them in.
    /// Crafted at the OLD threshold (5 reps) — must NOT fire under the length-scaled
    /// rule (large blocks need `repetitionLargeBlockMinRepeats`). An adversarial
    /// false-positive sweep showed 14/15 legitimate-but-repetitive buffers fired at
    /// exactly 5 reps before this guard.
    /// ~330 chars, ends on a non-whitespace char so `String(repeating:)` produces
    /// byte-identical reps with no trailing-whitespace trim eating the last one.
    private let largeScaffoldBlock = #"""
    Test case: verify mutateTask persists across the active/background split.
      Arrange: build an orchestrator with the stub embedding client, open a temp
               work folder, create a task, start a run, let one role reach .working.
      Act: call mutateTask and mutate a step.
      Assert: TODO — fill in the exact expectation for this case (item end).
    """#

    func testLargeBlock_belowThreshold_isLegitScaffold_doesNotFire() {
        XCTAssertGreaterThan(largeScaffoldBlock.count, DelegationConstants.repetitionLargeSubstringChars,
                             "test premise: block must be in the large-block regime")
        let reps = DelegationConstants.repetitionLargeBlockMinRepeats - 1  // 7 < 8 threshold
        XCTAssertNil(
            LoopScanner.scanStreaming(thinking: String(repeating: largeScaffoldBlock, count: reps), content: "", scope: .thinkingOnly),
            "A large block repeated \(reps)× (below the \(DelegationConstants.repetitionLargeBlockMinRepeats) threshold) is legitimate scaffolding — must NOT fire")
    }

    func testLargeBlock_atThreshold_isGenuineLoop_fires() {
        let reps = DelegationConstants.repetitionLargeBlockMinRepeats  // exactly 8
        XCTAssertNotNil(
            LoopScanner.scanStreaming(thinking: String(repeating: largeScaffoldBlock, count: reps), content: "", scope: .thinkingOnly),
            "The same large block repeated \(reps)× is a genuine loop — must fire")
    }

    /// A varied ~570-char block (> repetitionVeryLargeSubstringChars) with no internal
    /// repetition — the "very large / multi-paragraph cycle" regime.
    private let veryLargeBlock = """
    Reconsidering the delegation handler once more: it validates eligibility, builds \
    the child task, then enters the awaiter. The seeded chain routes the child's \
    ask_supervisor back up to the delegating role. On needs-acceptance it auto-closes \
    via the closedAt fast-path. An HTTP 400 from a poisoned chain triggers a stateless \
    rebuild. The pause-and-decide control plane validates the active child id before \
    acting on cancel, resume, or forward. Recursion is capped at depth three and the \
    per-delegation timeout is thirty minutes. None of this repeats internally, ending here.
    """

    /// Very-large tier: a >500-char block needs only `repetitionVeryLargeBlockMinRepeats`
    /// (4) — a block that big repeated even 4× verbatim is unambiguously a loop, and
    /// demanding the full 8 would need an impractical window. Below the threshold → no fire.
    func testVeryLargeBlock_belowTier_doesNotFire() {
        XCTAssertGreaterThan(veryLargeBlock.count, DelegationConstants.repetitionVeryLargeSubstringChars,
                             "test premise: block must be in the very-large regime")
        let reps = DelegationConstants.repetitionVeryLargeBlockMinRepeats - 1  // 3 < 4
        XCTAssertNil(
            LoopScanner.scanStreaming(thinking: String(repeating: veryLargeBlock, count: reps), content: "", scope: .thinkingOnly),
            "A very-large block repeated \(reps)× (below the \(DelegationConstants.repetitionVeryLargeBlockMinRepeats) threshold) must not fire")
    }

    func testVeryLargeBlock_atTier_fires() {
        let reps = DelegationConstants.repetitionVeryLargeBlockMinRepeats  // exactly 4
        XCTAssertNotNil(
            LoopScanner.scanStreaming(thinking: String(repeating: veryLargeBlock, count: reps), content: "", scope: .thinkingOnly),
            "A very-large block repeated \(reps)× is a genuine loop — must fire")
    }

    /// Length-scaling must NOT desensitize short-phrase detection: a short phrase
    /// looping 5× is still obviously stuck and must fire (the original behavior).
    /// Phrase ends in punctuation (not whitespace) so no trailing-trim boundary issue.
    func testShortPhrase_fiveReps_stillFires() {
        let phrase = "rethink."  // 8 chars ≤ repetitionLargeSubstringChars → keeps the 5-rep threshold
        XCTAssertLessThanOrEqual(phrase.count, DelegationConstants.repetitionLargeSubstringChars)
        XCTAssertNotNil(
            LoopScanner.scanStreaming(thinking: String(repeating: phrase, count: 5), content: "", scope: .thinkingOnly),
            "Short-phrase 5× loops must still fire — length-scaling only tightens large blocks")
    }

    /// Self-similar but NON-looping thinking (a long shared prefix with a varying
    /// suffix per "rep") must NOT fire — there's no exact repeat. This is also the
    /// worst case for scan cost (the shared prefix defeats the per-pair early-exit);
    /// the comparison budget caps it and returns nil, the correct verdict. Stable
    /// correctness assertion (no wall-clock timing — that would flake on CI).
    func testSelfSimilarNonLoop_doesNotFire() {
        let prefix = "Let me carefully reconsider the delegation handler invariants once more, tracing each path through awaitDelegationCompletion and the seeded chain before I commit to any edit here: "
        var buffer = ""
        for i in 0..<28 { buffer += prefix + "variant-\(i). " }  // ~5400 chars, no exact repeat
        XCTAssertNil(
            LoopScanner.scanStreaming(thinking: buffer, content: "", scope: .thinkingOnly),
            "Self-similar text with a varying suffix is not a loop — must NOT fire")
    }
}
