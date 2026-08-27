import XCTest
@testable import NanoTeams

/// Pins `LoopRecoveryPolicy` — the pure top-level stream-loop decision
/// (retry-with-correction within budget → mode-aware terminal).
final class LoopRecoveryPolicyTests: XCTestCase {

    private let signal = LoopSignal.withinMessage(diagnostic: "looped")

    private func decide(
        breakCount: Int,
        mode: SupervisorMode = .autonomous,
        isChatMode: Bool = true,
        canPark: Bool = false
    ) -> LoopRecoveryPolicy.Decision {
        LoopRecoveryPolicy.decide(
            signal: signal, breakCount: breakCount,
            maxRetries: LLMConstants.maxThinkingLoopBreaks,
            supervisorMode: mode, isChatMode: isChatMode,
            canParkForSupervisor: canPark, roleName: "Autovisor")
    }

    func testWithinBudget_retriesWithNudge() {
        // breakCount 1 < maxThinkingLoopBreaks (2) → retry carrying a correction.
        guard case .retryWithNudge(let nudge) = decide(breakCount: 1) else {
            return XCTFail("within budget must retry with a nudge")
        }
        XCTAssertFalse(nudge.isEmpty, "the retry MUST carry a perturbation — an empty "
            + "nudge would resend byte-identical bytes and re-enter the same loop")
    }

    func testAtBudget_manual_escalatesSupervisor() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks, mode: .manual)
        guard case .terminal(.escalateSupervisor) = d else {
            return XCTFail("manual + budget-exhausted must escalate to Supervisor, got \(d)")
        }
    }

    /// An autonomous chat role that nothing will wake again still finishes gracefully —
    /// parking one would strand it waiting on a human who was never told to expect a
    /// question. Covers every bundled chat team except the manager.
    func testAtBudget_autonomousChat_noWaker_finishesGraceful() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks,
                       mode: .autonomous, isChatMode: true, canPark: false)
        XCTAssertEqual(d, .terminal(.finishGraceful))
    }

    /// The Autovisor shape: an autonomous chat role WITH a waker parks carrying the
    /// diagnostic instead of finishing silently. A silent finish there is a false
    /// success — it ends the pass having done nothing and the schedule repeats it.
    func testAtBudget_autonomousChat_withWaker_parksWithDiagnostic() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks,
                       mode: .autonomous, isChatMode: true, canPark: true)
        guard case .terminal(.parkForSupervisor(let q)) = d else {
            return XCTFail("a park-capable autonomous chat role must park, got \(d)")
        }
        XCTAssertTrue(q.contains("looped"), "the park question carries the diagnostic")
    }

    /// `canParkForSupervisor` must not leak into any other branch: a NON-chat
    /// autonomous role still fails the step even when it could park.
    func testAtBudget_autonomousNonChat_failsStep_evenWhenParkCapable() {
        for canPark in [false, true] {
            let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks,
                           mode: .autonomous, isChatMode: false, canPark: canPark)
            guard case .terminal(.failStep) = d else {
                return XCTFail("autonomous + non-chat must fail the step (canPark: \(canPark)), got \(d)")
            }
        }
    }

    /// Manual mode outranks park-capability — a human is present, so ask them.
    func testAtBudget_manual_escalates_evenWhenParkCapable() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks,
                       mode: .manual, isChatMode: true, canPark: true)
        guard case .terminal(.escalateSupervisor) = d else {
            return XCTFail("manual must escalate regardless of park capability, got \(d)")
        }
    }

    // MARK: - Boundaries

    /// breakCount strictly above the budget still terminates (not an infinite-retry
    /// off-by-one). Defends `breakCount < maxRetries` against a `<=` slip.
    func testAboveBudget_stillTerminal() {
        let d = decide(breakCount: LLMConstants.maxThinkingLoopBreaks + 5, mode: .autonomous, isChatMode: false)
        guard case .terminal = d else { return XCTFail("above-budget must be terminal, got \(d)") }
    }

    /// The retry-budget boundary is exclusive: with maxRetries == 1 the FIRST break
    /// (breakCount 1) is already terminal — no retry is granted.
    func testMaxRetriesOne_firstBreakIsTerminal() {
        let d = LoopRecoveryPolicy.decide(
            signal: signal, breakCount: 1, maxRetries: 1,
            supervisorMode: .autonomous, isChatMode: false,
            canParkForSupervisor: false, roleName: "R")
        guard case .terminal(.failStep) = d else {
            return XCTFail("maxRetries==1 → breakCount 1 is terminal, got \(d)")
        }
    }

    /// The terminal message/question carries the signal's scope + diagnostic so the
    /// human/role sees WHAT looped.
    func testTerminalText_carriesSignalDiagnostic() {
        let s = LoopSignal.identicalToolCallSequence(diagnostic: "called read_file 3x")
        let d = LoopRecoveryPolicy.decide(
            signal: s, breakCount: 9, maxRetries: 2,
            supervisorMode: .manual, isChatMode: false,
            canParkForSupervisor: false, roleName: "Autovisor")
        guard case .terminal(.escalateSupervisor(let q)) = d else { return XCTFail() }
        XCTAssertTrue(q.contains("Autovisor"), "question names the role")
        XCTAssertTrue(q.contains("called read_file 3x"), "question carries the diagnostic")
        XCTAssertTrue(q.contains(s.scope), "question carries the scope")
    }

    // MARK: - Nudge content

    /// The nudge carries the stable marker prefix — so the persisted turn is identifiable in
    /// `wireTranscript` / the feed after the fact — and NOTHING authored for another audience.
    ///
    /// Re-aimed 2026-08-24 (CLAUDE.md #104). It used to assert the opposite of its second and
    /// third lines: that the nudge carries `signal.diagnostic` and `signal.scope`. Both are
    /// written for a HUMAN or for a delegating parent role — `diagnostic`'s own doc comment says
    /// it is "suitable for the paused envelope's `supervisor_message`" — and quoting them at the
    /// model is what shipped `(within-message)` and an 80-char slice of the model's own looping
    /// text into the prompt. Those two facts are still pinned, on the surfaces that want them,
    /// by `testTerminalText_carriesSignalDiagnostic`.
    func testNudge_carriesTheMarker_butNotTheHumanFacingDiagnostic() {
        let s = LoopSignal.withinMessage(diagnostic: "period 233 x6")
        guard case .retryWithNudge(let nudge) = LoopRecoveryPolicy.decide(
            signal: s, breakCount: 1, maxRetries: 2,
            supervisorMode: .autonomous, isChatMode: true,
            canParkForSupervisor: false, roleName: "Autovisor")
        else { return XCTFail("expected a nudge") }
        // `contains`, not `hasPrefix`: the marker sits INSIDE a delimited block so
        // it survives the providers' merge of consecutive user turns.
        XCTAssertTrue(nudge.contains(LoopRecoveryPolicy.nudgePrefix))
        XCTAssertFalse(nudge.contains("period 233 x6"),
                       "the diagnostic is the human/parent-facing rendering — the model gets the "
                           + "SHAPE of the repetition, never a quote of what it repeated")
        XCTAssertFalse(nudge.contains(s.scope),
                       "`\(s.scope)` is an internal classification label mirrored for the "
                           + "delegation envelope, not text written for the model")
    }

    /// The whole point of the correction is to break a repetition, and it rides the prefix of
    /// every remaining request of the step (stateless transport, nothing prunes the
    /// conversation). Echoing the repeated text back re-primes exactly what it is discarding.
    ///
    /// RED against the pre-fix production: the diagnostic was interpolated verbatim.
    func testNudge_doesNotEchoTheLoopedTextBackIntoThePrompt() {
        let looped = "Wait! Looking at the list again"
        let s = LoopSignal.withinMessage(
            diagnostic: "substring \"\(looped)\" repeated 4 times consecutively")
        guard case .retryWithNudge(let nudge) = LoopRecoveryPolicy.decide(
            signal: s, breakCount: 1, maxRetries: 2,
            supervisorMode: .autonomous, isChatMode: true,
            canParkForSupervisor: false, roleName: "R")
        else { return XCTFail("expected a nudge") }
        XCTAssertFalse(nudge.contains(looped),
                       "the model's own looping text must not return to its prompt")
        XCTAssertFalse(nudge.contains(s.diagnostic))
    }

    /// Each signal shape gets its own clause, so the correction says something true about what
    /// happened without reading a string composed for someone else. All three still carry the
    /// greppable marker.
    func testNudge_describesEachSignalShapeDistinctly() {
        let signals: [LoopSignal] = [
            .withinMessage(diagnostic: "d1"),
            .acrossMessages(diagnostic: "d2"),
            .identicalToolCallSequence(diagnostic: "d3"),
        ]
        var texts: Set<String> = []
        for s in signals {
            guard case .retryWithNudge(let n) = LoopRecoveryPolicy.decide(
                signal: s, breakCount: 1, maxRetries: 2,
                supervisorMode: .autonomous, isChatMode: true,
                canParkForSupervisor: false, roleName: "R")
            else { return XCTFail("expected a nudge for \(s)") }
            XCTAssertTrue(n.contains(LoopRecoveryPolicy.nudgePrefix), "\(s) lost the marker")
            texts.insert(n)
        }
        XCTAssertEqual(texts.count, signals.count,
                       "a shared clause would tell the model 'something repeated' and nothing more")
    }

    /// Both providers flatten consecutive user-side turns into one message, so an
    /// undelimited nudge reads as a trailing paragraph of the preceding tool result
    /// rather than as its own turn.
    func testNudge_isDelimitedSoItSurvivesTheUserMerge() {
        guard case .retryWithNudge(let nudge) = LoopRecoveryPolicy.decide(
            signal: .withinMessage(diagnostic: "d"), breakCount: 1, maxRetries: 3,
            supervisorMode: .autonomous, isChatMode: true,
            canParkForSupervisor: false, roleName: "R")
        else { return XCTFail("expected a nudge") }

        XCTAssertTrue(nudge.hasPrefix(MessageSourceContext.loopCorrectionBlockOpen + "\n"),
                      "the open marker must start its own line")
        XCTAssertTrue(nudge.hasSuffix("\n" + MessageSourceContext.loopCorrectionBlockClose),
                      "the close marker must end on its own line")
    }

    /// The retry budget is spent re-sampling the same conditioning, so attempt 2 must
    /// not be attempt 1 again. (Nudges accumulate on the wire, so the text differing is
    /// what makes the accumulation say something.)
    func testSecondAttempt_escalatesRatherThanRepeating() {
        func nudge(attempt: Int) -> String {
            guard case .retryWithNudge(let n) = LoopRecoveryPolicy.decide(
                signal: .withinMessage(diagnostic: "d"), breakCount: attempt, maxRetries: 3,
                supervisorMode: .autonomous, isChatMode: true,
                canParkForSupervisor: false, roleName: "R")
            else { XCTFail("expected a nudge"); return "" }
            return n
        }

        let first = nudge(attempt: 1)
        let second = nudge(attempt: 2)
        XCTAssertNotEqual(first, second, "a repeat of the same correction is not a second attempt")
        XCTAssertTrue(second.contains("2 times in a row"),
                      "the escalation must name the repetition it is responding to")
        XCTAssertTrue(second.contains(LoopRecoveryPolicy.nudgePrefix),
                      "…while still carrying the greppable marker")
    }

    /// The nudge rides the prefix of every remaining request of the step (stateless
    /// transport, nothing prunes the conversation), so it must NOT carry an open-ended
    /// style instruction that would bias a step still running for dozens of iterations.
    func testNudge_carriesNoUnboundedStyleInstruction() {
        guard case .retryWithNudge(let nudge) = decide(breakCount: 1) else { return XCTFail() }
        for banned in ["be brief", "be concise", "keep it short", "from now on", "for the rest"] {
            XCTAssertFalse(nudge.lowercased().contains(banned),
                           "nudge must not carry the unbounded instruction '\(banned)'")
        }
    }

    /// Per-role toolsets differ, so steering toward a named sibling tool earns a
    /// `tool_not_authorized` ping-pong for any role that lacks it.
    ///
    /// **The fixture is the incident** (CLAUDE.md #56, reading #3). This test used the
    /// class-level `signal` — `.withinMessage(diagnostic: "looped")` — until 2026-08-24. The
    /// nudge TEMPLATE names no tool, so the interpolated diagnostic is the only channel by
    /// which one can arrive, and a diagnostic without a tool name is the one input that cannot
    /// violate the property. Meanwhile production shipped this, quoting the model's own text:
    ///
    ///     substring "'s call `read_file` for `scripts/core/frame_diff.gd`. Wait!…"
    ///
    /// i.e. a tool name AND a path, steering the role straight back at what it was looping on.
    func testNudge_namesNoSiblingTool() {
        let s = LoopSignal.withinMessage(
            diagnostic: "substring \"'s call `read_file` for `scripts/core/frame_diff.gd`.  "
                + "Wait! Looking at the lis…\" repeated 4 times consecutively")
        // Anti-vacuum: without a tool name in the fixture this asserts nothing at all —
        // which is precisely how the pre-2026-08-24 version stayed green over the defect.
        XCTAssertTrue(ToolNames.allNames.contains { s.diagnostic.contains($0) },
                      "the fixture must carry a tool name for this pin to mean anything")

        guard case .retryWithNudge(let nudge) = LoopRecoveryPolicy.decide(
            signal: s, breakCount: 1, maxRetries: 2,
            supervisorMode: .autonomous, isChatMode: true,
            canParkForSupervisor: false, roleName: "R")
        else { return XCTFail("expected a nudge") }
        for tool in ToolNames.allNames {
            XCTAssertFalse(nudge.contains(tool), "nudge must not name the tool '\(tool)'")
        }
    }

    /// …and the property is total across the three shapes, including the one whose signal IS
    /// about a tool call. Naming it would be defensible (the role obviously holds a tool it
    /// just called three times) but pointless: the model can see its own calls, and an
    /// exception here is an exception the next reader has to re-derive.
    func testNudge_namesNoSiblingTool_forEverySignalShape() {
        let quoted = "called `read_file` with identical arguments"
        for s: LoopSignal in [
            .withinMessage(diagnostic: quoted),
            .acrossMessages(diagnostic: quoted),
            .identicalToolCallSequence(diagnostic: quoted),
        ] {
            guard case .retryWithNudge(let nudge) = LoopRecoveryPolicy.decide(
                signal: s, breakCount: 1, maxRetries: 2,
                supervisorMode: .autonomous, isChatMode: true,
                canParkForSupervisor: false, roleName: "R")
            else { return XCTFail("expected a nudge for \(s)") }
            for tool in ToolNames.allNames {
                XCTAssertFalse(nudge.contains(tool), "\(s.scope): nudge names the tool '\(tool)'")
            }
        }
    }
}
