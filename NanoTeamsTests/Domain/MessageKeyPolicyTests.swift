import XCTest
@testable import NanoTeams

/// Pins the Enter / Shift+Enter / Cmd+Enter truth-table that
/// `MessageComposer.messageField` consults on every Return-key press.
///
/// The policy used to live as conditional branches inside
/// `EnterSendsMessageModifier` (SwiftUI `.onKeyPress` workaround). Extracted
/// to Domain so it's Foundation-only — testable without rendering a view
/// or bringing up `@MainActor`.
final class MessageKeyPolicyTests: XCTestCase {

    // MARK: - Enter-sends mode

    func testEnterSends_plainEnter_canSubmit_submits() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: false, hasCommand: false,
                canSubmit: true, isSubmitting: false
            ),
            .submit
        )
    }

    func testEnterSends_shiftEnter_insertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: true, hasCommand: false,
                canSubmit: true, isSubmitting: false
            ),
            .insertNewline
        )
    }

    func testEnterSends_cmdEnter_insertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: false, hasCommand: true,
                canSubmit: true, isSubmitting: false
            ),
            .insertNewline
        )
    }

    func testEnterSends_shiftCmdEnter_insertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: true, hasCommand: true,
                canSubmit: true, isSubmitting: false
            ),
            .insertNewline
        )
    }

    func testEnterSends_plainEnter_cannotSubmit_ignores() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: false, hasCommand: false,
                canSubmit: false, isSubmitting: false
            ),
            .ignore
        )
    }

    func testEnterSends_plainEnter_isSubmitting_ignores() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: false, hasCommand: false,
                canSubmit: true, isSubmitting: true
            ),
            .ignore
        )
    }

    // Shift+Enter must insert newline even when form is unsubmittable —
    // it's an explicit "do not send" gesture.
    func testEnterSends_shiftEnter_cannotSubmit_stillInsertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: true, hasShift: true, hasCommand: false,
                canSubmit: false, isSubmitting: false
            ),
            .insertNewline
        )
    }

    // MARK: - Normal mode (Enter inserts newline, Cmd+Enter submits)

    func testNormal_plainEnter_insertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: false, hasCommand: false,
                canSubmit: true, isSubmitting: false
            ),
            .insertNewline
        )
    }

    func testNormal_shiftEnter_insertsNewline() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: true, hasCommand: false,
                canSubmit: true, isSubmitting: false
            ),
            .insertNewline
        )
    }

    func testNormal_cmdEnter_canSubmit_submits() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: false, hasCommand: true,
                canSubmit: true, isSubmitting: false
            ),
            .submit
        )
    }

    func testNormal_shiftCmdEnter_submits() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: true, hasCommand: true,
                canSubmit: true, isSubmitting: false
            ),
            .submit
        )
    }

    func testNormal_cmdEnter_cannotSubmit_ignores() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: false, hasCommand: true,
                canSubmit: false, isSubmitting: false
            ),
            .ignore
        )
    }

    func testNormal_cmdEnter_isSubmitting_ignores() {
        XCTAssertEqual(
            MessageKeyPolicy.resolveReturnKey(
                enterSendsMessage: false, hasShift: false, hasCommand: true,
                canSubmit: true, isSubmitting: true
            ),
            .ignore
        )
    }

    // MARK: - Exhaustive sweep

    /// Belt-and-braces guard: enumerate the entire 2^5 input space and
    /// assert `resolveReturnKey` matches the locally-computed expected
    /// value. Catches drift if the implementation grows new branches
    /// without the case-table tests above being updated.
    func testExhaustive_allSixteenCombinations_matchExpected() {
        for enterSendsMessage in [true, false] {
            for hasShift in [true, false] {
                for hasCommand in [true, false] {
                    for canSubmit in [true, false] {
                        for isSubmitting in [true, false] {
                            let expected = Self.referenceImpl(
                                enterSendsMessage: enterSendsMessage,
                                hasShift: hasShift,
                                hasCommand: hasCommand,
                                canSubmit: canSubmit,
                                isSubmitting: isSubmitting
                            )
                            let actual = MessageKeyPolicy.resolveReturnKey(
                                enterSendsMessage: enterSendsMessage,
                                hasShift: hasShift,
                                hasCommand: hasCommand,
                                canSubmit: canSubmit,
                                isSubmitting: isSubmitting
                            )
                            XCTAssertEqual(
                                actual, expected,
                                "Mismatch for enterSends=\(enterSendsMessage) shift=\(hasShift) cmd=\(hasCommand) canSubmit=\(canSubmit) isSubmitting=\(isSubmitting)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Independent re-encoding of the truth-table for the exhaustive sweep
    /// to compare against. Kept structurally simple so a mistake here
    /// stands out from a mistake in the implementation.
    private static func referenceImpl(
        enterSendsMessage: Bool,
        hasShift: Bool,
        hasCommand: Bool,
        canSubmit: Bool,
        isSubmitting: Bool
    ) -> MessageKeyPolicy.KeyAction {
        let submittable = canSubmit && !isSubmitting
        if enterSendsMessage {
            if hasShift || hasCommand { return .insertNewline }
            return submittable ? .submit : .ignore
        } else {
            if hasCommand { return submittable ? .submit : .ignore }
            return .insertNewline
        }
    }
}
