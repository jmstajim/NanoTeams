import SwiftUI
import XCTest
@testable import NanoTeams

/// Pin: `MessageComposer.maxTextFieldHeight` must default to a non-nil pixel
/// cap (sourced from `MessageComposerLayout.defaultMaxTextFieldHeight`).
/// Pixel-cap mode is the default so new caller surfaces (anyone adding
/// `MessageComposer(...)`) inherit iMessage-style scrolling instead of
/// silently regressing to legacy unbounded-grow mode.
///
/// If a future refactor flips either init's default back to `nil`, or
/// hardcodes a value that drifts from the central token, the matching test
/// below fails and the failure message points the reader at the durability
/// rationale (see CLAUDE.md "MessageComposer.maxTextFieldHeight default").
@MainActor
final class MessageComposerDefaultsTests: XCTestCase {

    func testConvenienceInit_default_isPixelCapMode() {
        let composer = MessageComposer(
            text: .constant(""),
            attachments: .constant([]),
            placeholder: "",
            canSubmit: false,
            isSubmitting: false,
            onSubmit: {},
            onStageAttachment: { _ in nil },
            onRemoveAttachment: { _ in }
        )
        XCTAssertEqual(
            composer.maxTextFieldHeight,
            MessageComposerLayout.defaultMaxTextFieldHeight,
            "Convenience init's default must read from MessageComposerLayout — hardcoding a literal here lets the two init defaults drift."
        )
        XCTAssertEqual(
            composer.minLineCount, 1,
            "Default `minLineCount` must be 1 — `.lineLimit(0...)` produces undefined SwiftUI behavior."
        )
    }

    /// Pins the non-Optional signature on `maxTextFieldHeight` so a future
    /// refactor can't silently re-introduce the Optional wrapper — `let _: CGFloat`
    /// would fail to compile if the property regressed to `CGFloat?`.
    func testMemberwiseInit_maxTextFieldHeight_isNonOptional_CGFloat() {
        let composer = MessageComposer(
            text: .constant(""),
            attachments: .constant([]),
            clips: nil,
            placeholder: "",
            canSubmit: false,
            isSubmitting: false,
            onSubmit: {},
            onStageAttachment: { _ in nil },
            onRemoveAttachment: { _ in },
            filePickerBinding: nil,
            autofocusOnAppear: false,
            minLineCount: 1
        ) {
            EmptyView()
        }
        let _: CGFloat = composer.maxTextFieldHeight
    }

    // MARK: - clampMinLines

    /// `.lineLimit(0...)` and `.lineLimit(-1...)` produce undefined SwiftUI
    /// behavior; `MessageComposer.messageField` defends via
    /// `MessageComposer.clampMinLines(_:)` (≥ 1 floor). A future refactor that
    /// removed the clamp on the assumption "default is 1, so we're safe" would
    /// silently lose this defense; these tests pin the helper directly so the
    /// invariant can't drift.

    func testClampMinLines_passesPositiveValuesThrough() {
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(1), 1)
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(3), 3)
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(100), 100)
    }

    func testClampMinLines_zero_clampsToOne() {
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(0), 1)
    }

    func testClampMinLines_negative_clampsToOne() {
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(-1), 1)
        XCTAssertEqual(MessageComposer<EmptyView>.clampMinLines(-100), 1)
    }

    // MARK: - explicit override

    // MARK: - Editor-field mode (Autovisor Goal composer)

    /// The regular (message) inits must default `isEditorField` to false so every
    /// existing send-capable surface keeps its send button + keyhint + submit-on-Return.
    func testMessageInits_defaultIsEditorFieldFalse() {
        let convenience = MessageComposer(
            text: .constant(""), attachments: .constant([]),
            placeholder: "", canSubmit: false, isSubmitting: false,
            onSubmit: {}, onStageAttachment: { _ in nil }, onRemoveAttachment: { _ in }
        )
        XCTAssertFalse(convenience.isEditorField)

        let memberwise = MessageComposer(
            text: .constant(""), attachments: .constant([]), clips: nil,
            placeholder: "", canSubmit: false, isSubmitting: false,
            onSubmit: {}, onStageAttachment: { _ in nil }, onRemoveAttachment: { _ in },
            filePickerBinding: nil, autofocusOnAppear: false, minLineCount: 1
        ) { EmptyView() }
        XCTAssertFalse(memberwise.isEditorField)
    }

    /// The editor convenience init opts into send-less mode: `isEditorField` true,
    /// `canSubmit` false (nothing to submit), and a taller default `minLineCount`.
    func testEditorInit_configuresSendlessEditorMode() {
        let composer = MessageComposer(
            editorText: .constant(""),
            attachments: .constant([]),
            onStageAttachment: { _ in nil },
            onRemoveAttachment: { _ in }
        )
        XCTAssertTrue(composer.isEditorField)
        XCTAssertFalse(composer.canSubmit, "Editor mode has nothing to submit.")
        XCTAssertEqual(composer.minLineCount, 3)
        XCTAssertEqual(
            composer.maxTextFieldHeight,
            MessageComposerLayout.defaultMaxTextFieldHeight,
            "Editor init's default must read from MessageComposerLayout, not a literal."
        )
    }

    // MARK: - returnAction

    /// Editor mode always inserts a newline — the send button is gone, so Return
    /// must never submit regardless of the `enterSendsMessage` preference or modifiers.
    func testReturnAction_editorMode_alwaysInsertsNewline() {
        for enterSends in [true, false] {
            for shift in [true, false] {
                for command in [true, false] {
                    for canSubmit in [true, false] {
                        let action = MessageComposer<EmptyView>.returnAction(
                            isEditorField: true,
                            enterSendsMessage: enterSends,
                            hasShift: shift,
                            hasCommand: command,
                            canSubmit: canSubmit,
                            isSubmitting: false
                        )
                        XCTAssertEqual(action, .insertNewline,
                                       "editor mode must insert newline (enterSends=\(enterSends) shift=\(shift) cmd=\(command) canSubmit=\(canSubmit))")
                    }
                }
            }
        }
    }

    /// Non-editor mode delegates verbatim to `MessageKeyPolicy` — the shared submit
    /// semantics for every message surface stay unchanged.
    func testReturnAction_nonEditor_delegatesToMessageKeyPolicy() {
        for enterSends in [true, false] {
            for shift in [true, false] {
                for command in [true, false] {
                    for canSubmit in [true, false] {
                        for submitting in [true, false] {
                            let via = MessageComposer<EmptyView>.returnAction(
                                isEditorField: false,
                                enterSendsMessage: enterSends,
                                hasShift: shift, hasCommand: command,
                                canSubmit: canSubmit, isSubmitting: submitting
                            )
                            let direct = MessageKeyPolicy.resolveReturnKey(
                                enterSendsMessage: enterSends,
                                hasShift: shift, hasCommand: command,
                                canSubmit: canSubmit, isSubmitting: submitting
                            )
                            XCTAssertEqual(via, direct)
                        }
                    }
                }
            }
        }
    }

    func testConvenienceInit_explicitOverride_passesThrough() {
        let composer = MessageComposer(
            text: .constant(""),
            attachments: .constant([]),
            placeholder: "",
            canSubmit: false,
            isSubmitting: false,
            onSubmit: {},
            onStageAttachment: { _ in nil },
            onRemoveAttachment: { _ in },
            maxTextFieldHeight: 88
        )
        XCTAssertEqual(composer.maxTextFieldHeight, 88)
    }

    /// The memberwise init's default is the one `TeamActivityComposer` and any
    /// future surface passing a custom `settingsMenu` trailing closure rely on
    /// (the convenience init is type-restricted to `EmbedFilesSettingsButton<EmptyView>`
    /// and not reachable when callers pass their own settings menu). A future
    /// refactor flipping the property's default back to `nil` while leaving the
    /// convenience init unchanged would pass `testConvenienceInit_default_isPixelCapMode`
    /// and still regress activity-feed/Watchtower/QuickCapture-supervisor-answer
    /// behavior. This test pins the memberwise default specifically.
    func testMemberwiseInit_default_isPixelCapMode() {
        let composer = MessageComposer(
            text: .constant(""),
            attachments: .constant([]),
            clips: nil,
            placeholder: "",
            canSubmit: false,
            isSubmitting: false,
            onSubmit: {},
            onStageAttachment: { _ in nil },
            onRemoveAttachment: { _ in },
            filePickerBinding: nil,
            autofocusOnAppear: false,
            minLineCount: 1
        ) {
            EmptyView()
        }
        XCTAssertEqual(
            composer.maxTextFieldHeight,
            MessageComposerLayout.defaultMaxTextFieldHeight,
            "Memberwise-init default must read from MessageComposerLayout — TeamActivityComposer and any caller passing a custom settingsMenu reach this path, not the convenience init. See CLAUDE.md."
        )
    }
}
