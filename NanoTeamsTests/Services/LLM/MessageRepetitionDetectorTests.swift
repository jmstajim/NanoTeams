import XCTest
@testable import NanoTeams

/// Pins the cross-message and tool-call-sequence modes of the repetition detector
/// that powers auto-trigger of Pause-and-Decide on a stuck team:
///
///  - across-messages: the role keeps regenerating similar content each iteration
///    without progress (fuzzy LCS overlap across recent outputs).
///  - identical-tool-call-sequence: the same `(name, args)` pair emitted N× in a row.
///
/// The within-message (tail-anchored `detectTailLoop`) mode is covered by
/// `DetectTailLoopCornerTests` + `RealWorldThinkingLoopDetectionTests`.
final class MessageRepetitionDetectorTests: XCTestCase {

    // NOTE: within-message (tail-anchored `detectTailLoop`) coverage lives in
    // `DetectTailLoopCornerTests` + `RealWorldThinkingLoopDetectionTests`. This file
    // pins the other two modes.

    // MARK: - Across-messages

    func testAcrossMessages_threeNearlyIdenticalRecent_fires() {
        let nearly = """
        I'll read the file js/calculator.js to understand the buttons logic
        and propose a fix for the broken handlers in the keypad event listener.
        """
        let messages = [
            "First, let me list the project files.",
            nearly,
            nearly + " (Trying again.)",
            nearly + " (Hmm, same approach.)",
        ]
        let match = MessageRepetitionDetector.detectAcrossMessages(messages)
        XCTAssertNotNil(match,
                        "Three recent messages with high pairwise overlap must fire strategic-loop detection")
    }

    func testAcrossMessages_distinctRecent_returnsNil() {
        let messages = [
            "Reading the project structure.",
            "Found js/calculator.js — analyzing buttons.",
            "Found a missing event handler in app.js — drafting fix.",
            "Implementing the handler now.",
        ]
        XCTAssertNil(MessageRepetitionDetector.detectAcrossMessages(messages),
                     "Progressing distinct messages must not fire — false-positive would block legitimate work")
    }

    func testAcrossMessages_belowMinMessages_returnsNil() {
        let messages = ["a", "b"]
        XCTAssertNil(MessageRepetitionDetector.detectAcrossMessages(messages))
    }

    func testAcrossMessages_diagnosticDescribesOverlap() {
        let nearly = String(repeating: "the team will read js/calculator.js then fix the buttons. ", count: 3)
        let messages = [nearly, nearly, nearly, nearly]
        let match = MessageRepetitionDetector.detectAcrossMessages(messages)
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.diagnostic.contains("overlap") ?? false,
                      "Diagnostic must mention overlap so parent role's LLM understands the signal")
    }

    // MARK: - Identical tool-call sequence

    /// Three identical `(name, argsJSON)` pairs at the tail must fire —
    /// the precise tool-spam loop signal. Threshold 3 compensates for the
    /// off-by-one with `commitStreaming` running before `appendToolCalls`
    /// (see `DelegationConstants.repetitionMinIdenticalToolCalls` doc).
    func testToolCallSequence_threeIdenticalAtTail_fires() {
        let calls: [(name: String, argsJSON: String)] = [
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
        ]
        let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3)
        XCTAssertNotNil(match, "Three identical tool calls at the tail must fire")
        XCTAssertEqual(match?.repeatCount, 3)
    }

    /// Suffix-only — older calls in the middle of the array don't dilute the
    /// signal. Mirrors real `step.toolCalls` shape: history grows over a
    /// step's lifetime, only the recent tail matters for loop detection.
    func testToolCallSequence_priorVarietyThenIdenticalSuffix_fires() {
        let calls: [(name: String, argsJSON: String)] = [
            (name: "read_file", argsJSON: #"{"path":"index.html"}"#),
            (name: "edit_file", argsJSON: #"{"path":"index.html","old":"a","new":"b"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
        ]
        let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3)
        XCTAssertNotNil(match, "Suffix-of-3 identical must fire even with varied prior history")
    }

    /// Exactly 2 identical tail entries must NOT fire on threshold 3 —
    /// boundary check. Two identical reads happen legitimately
    /// (read → edit → read), only the third in a row is a loop signal.
    func testToolCallSequence_twoIdentical_belowThreshold_returnsNil() {
        let calls: [(name: String, argsJSON: String)] = [
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
        ]
        XCTAssertNil(
            MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3),
            "Two identical calls is a legitimate read→re-read pattern, NOT a loop"
        )
    }

    /// One identical call breaking the suffix means no loop. The tail-3 must
    /// be ALL identical, not "majority identical".
    func testToolCallSequence_brokenSuffix_returnsNil() {
        let calls: [(name: String, argsJSON: String)] = [
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"index.html"}"#),
        ]
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3),
                     "Different args at the tail breaks the identical-suffix pattern")
    }

    /// Same `name` but different `argsJSON` is not a loop — model is
    /// progressing through different files / different operations.
    func testToolCallSequence_sameNameDifferentArgs_returnsNil() {
        let calls: [(name: String, argsJSON: String)] = [
            (name: "read_file", argsJSON: #"{"path":"a.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"b.js"}"#),
            (name: "read_file", argsJSON: #"{"path":"c.js"}"#),
        ]
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3),
                     "Same tool name with varying args is exploration, not a loop")
    }

    /// Empty array, single element, and below-threshold inputs must all
    /// return nil without crashing.
    func testToolCallSequence_edgeCases_returnNil() {
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence([], minRepeats: 3))
        let one: [(name: String, argsJSON: String)] = [(name: "x", argsJSON: "{}")]
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence(one, minRepeats: 3))
    }

    /// `minRepeats < 2` is meaningless (1 call is never a "loop") — must
    /// return nil even for a 5-element identical array, not crash or fire.
    /// Pinned because the only call site uses
    /// `DelegationConstants.repetitionMinIdenticalToolCalls`, but a future
    /// caller / test plumbing through `0` or `1` should bail safely.
    func testToolCallSequence_minRepeatsBelowTwo_returnsNil() {
        let five: [(name: String, argsJSON: String)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"x"}"#),
            count: 5
        )
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence(five, minRepeats: 1))
        XCTAssertNil(MessageRepetitionDetector.detectIdenticalToolCallSequence(five, minRepeats: 0))
    }

    /// Diagnostic must include the tool name AND a (truncated) argsJSON
    /// prefix so the parent role can disambiguate "spammed read_file" vs
    /// "spammed write_file" without re-reading the entire history.
    func testToolCallSequence_diagnosticIncludesToolNameAndArgsPrefix() {
        let calls: [(name: String, argsJSON: String)] = Array(
            repeating: (name: "read_file", argsJSON: #"{"path":"script.js"}"#),
            count: 3
        )
        let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3)
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.diagnostic.contains("read_file") ?? false,
                      "Diagnostic must surface the tool name; got: \(match?.diagnostic ?? "nil")")
        XCTAssertTrue(match?.diagnostic.contains("script.js") ?? false,
                      "Diagnostic must include args prefix so the parent role knows what was spammed")
    }

    /// Long argsJSON (e.g. a write_file with embedded source) must be
    /// truncated in the diagnostic — the paused envelope's
    /// `supervisor_message` is read by the parent role's LLM and shouldn't
    /// blow up its context with a 5KB blob just because the loop happened
    /// to involve a long argument.
    func testToolCallSequence_diagnosticTruncatesLongArgs() {
        let longArgs = #"{"path":"big.js","content":""# + String(repeating: "x", count: 2000) + #""}"#
        let calls: [(name: String, argsJSON: String)] = Array(
            repeating: (name: "write_file", argsJSON: longArgs),
            count: 3
        )
        let match = MessageRepetitionDetector.detectIdenticalToolCallSequence(calls, minRepeats: 3)
        XCTAssertNotNil(match)
        XCTAssertLessThanOrEqual(match?.diagnostic.count ?? 0, 250,
                                 "Diagnostic must stay compact for long args; got \(match?.diagnostic.count ?? -1) chars")
    }
}
