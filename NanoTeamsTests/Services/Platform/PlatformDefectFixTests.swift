import CoreGraphics
import XCTest

@testable import NanoTeams

// Three defects the wave-5 coverage pass surfaced in TCC-gated platform code, each of which had
// been unreachable from a test because the arithmetic or the status was welded into a path that
// posts a real CGEvent or talks to Carbon. Each is now behind a pure seam, and each seam is
// pinned here.

// MARK: - ClipboardCaptureService.lineRange

/// `detectLineRange` clamped the START of the selected range at both ends but derived the END
/// from the RAW, unclamped location. Two consequences, both on the Ctrl+Opt+Cmd+K path:
///
///  • `location == kCFNotFound` (-1) — which some AX providers really do return — counted the
///    start line from a clamped 0 and the end line from -1, so the `// Source: path:start-end`
///    header handed to the LLM named a range the snippet does not occupy.
///  • `location + length < 0` produced a negative offset for `NSString.substring(to:)`, whose
///    parameter is `NSUInteger`. The negative `Int` bridges to a huge unsigned value and ObjC
///    raises `NSRangeException` — not a Swift error, so nothing catches it and the app aborts.
final class ClipboardLineRangeClampTests: XCTestCase {

    /// Four lines, so an off-by-one in either endpoint is visible rather than absorbed.
    private static let text = "alpha\nbravo\ncharlie\ndelta"

    private func range(_ location: Int, _ length: Int) -> (start: Int, end: Int) {
        ClipboardCaptureService.lineRange(inUTF16Text: Self.text, location: location, length: length)
    }

    // MARK: The regression

    /// THE crash. Pre-fix this raised `NSRangeException` and took the process down; the
    /// assertion is secondary — simply returning is the pin.
    func testNegativeSum_doesNotTrapAndClampsToTheFirstLine() {
        XCTAssertEqual(range(-5, 1).start, 1)
        XCTAssertEqual(range(-5, 1).end, 1, "an end before the start is meaningless")
    }

    /// `kCFNotFound`, the reachable half. Both endpoints must be computed from the same clamped
    /// origin, or the header names a line range the snippet never occupied.
    ///
    /// Length 6 is chosen so the discrepancy CROSSES a line boundary: "alpha\n" ends at offset 6,
    /// so deriving the end from the raw -1 lands on offset 5 (still line 1) while deriving it
    /// from the clamped 0 lands on 6 (line 2). At most lengths both derivations agree and the
    /// test would pass against the unfixed code — a vacuous pin.
    func testKCFNotFoundLocation_bothEndpointsUseTheClampedOrigin() {
        let sentinel = range(kCFNotFound, 6)
        let clamped = range(0, 6)

        XCTAssertEqual(sentinel.start, clamped.start)
        XCTAssertEqual(sentinel.end, clamped.end,
                       "endLine must derive from the clamped location, not the raw one")
        XCTAssertEqual(sentinel.end, 2, "offset 6 is past the first newline")
    }

    /// A negative length is as much garbage as a negative location. It must collapse the range,
    /// never invert it — `substring(to:)` with an end before the start is the same NSUInteger
    /// bridge that crashes.
    func testNegativeLength_collapsesToTheStartLine() {
        let r = range(12, -100)
        XCTAssertEqual(r.start, r.end)
        XCTAssertEqual(r.start, 3, "offset 12 is on line 3")
    }

    func testEndIsNeverBeforeStart() {
        let r = range(12, -100)
        XCTAssertLessThanOrEqual(r.start, r.end)
    }

    // MARK: Ordinary ranges — anti-vacuity

    /// Without these the clamp tests would pass against a stub returning `(1, 1)`.
    func testSelectionWithinOneLine_reportsThatLineTwice() {
        // "bravo" starts at offset 6 and holds no newline.
        XCTAssertEqual(range(6, 5).start, 2)
        XCTAssertEqual(range(6, 5).end, 2)
    }

    func testSelectionSpanningLines_reportsBothEnds() {
        // From the start of "bravo" (6) through "charlie" (ends at 19).
        let r = range(6, 13)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 3)
    }

    func testLocationPastTheEnd_clampsToTheLastLine() {
        let r = range(9_999, 1)
        XCTAssertEqual(r.start, 4)
        XCTAssertEqual(r.end, 4)
    }

    /// `Int.max` length would overflow the addition. The overflow branch existed already; this
    /// keeps it honest now that the end is also floored at the start.
    func testOverflowingLength_clampsToTheEndOfTheText() {
        let r = range(6, Int.max)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 4)
    }

    /// CRLF must not double-count: the line count comes from `\n`, and `\r` rides along inside
    /// the preceding line.
    func testCRLFText_countsEachLineOnce() {
        let r = ClipboardCaptureService.lineRange(
            inUTF16Text: "one\r\ntwo\r\nthree", location: 5, length: 3)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    /// UTF-16 offsets, not Characters: an emoji is one Character and two code units, so indexing
    /// the Swift `String` directly would put every later endpoint on the wrong line.
    func testNonBMPText_offsetsAreUTF16CodeUnits() {
        // "😀" is 2 UTF-16 units, so "\n" sits at offset 2 and "b" at 3.
        let r = ClipboardCaptureService.lineRange(inUTF16Text: "😀\nb", location: 3, length: 1)
        XCTAssertEqual(r.start, 2, "offset 3 is on the second line under UTF-16 counting")
    }
}

// MARK: - QuickCaptureController.unclaimedHotkeyMessage

/// `GlobalHotkeyManager.register` captured `RegisterEventHotKey`'s status into a local and never
/// read it. When another app already owns a combo — Alfred, Raycast and Keyboard Maestro all
/// claim triple-modifier ones — the registration failed, `hotkeyRefs` stayed empty, and the
/// shortcut the Settings sheet advertises simply never fired, with nothing reported anywhere.
final class UnclaimedHotkeyMessageTests: XCTestCase {

    func testBothRegistered_reportsNothing() {
        XCTAssertNil(QuickCaptureController.unclaimedHotkeyMessage(
            openRegistered: true, clipRegistered: true))
    }

    func testOpenHotkeyRefused_namesThatComboOnly() {
        let message = QuickCaptureController.unclaimedHotkeyMessage(
            openRegistered: false, clipRegistered: true)

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("⌃⌥⌘0") ?? false, "got: \(message ?? "nil")")
        XCTAssertFalse(message?.contains("⌃⌥⌘K") ?? true, "must not name a combo that registered")
    }

    func testClipHotkeyRefused_namesThatComboOnly() {
        let message = QuickCaptureController.unclaimedHotkeyMessage(
            openRegistered: true, clipRegistered: false)

        XCTAssertTrue(message?.contains("⌃⌥⌘K") ?? false, "got: \(message ?? "nil")")
        XCTAssertFalse(message?.contains("⌃⌥⌘0") ?? true)
    }

    /// `lastErrorMessage` is a single coalescing slot (CLAUDE.md §45) — the banner consumes it on
    /// render — so two failures have to arrive as ONE message or the user only ever sees the
    /// second one.
    func testBothRefused_isASingleMessageNamingBoth() {
        let message = QuickCaptureController.unclaimedHotkeyMessage(
            openRegistered: false, clipRegistered: false)

        XCTAssertTrue(message?.contains("⌃⌥⌘0") ?? false, "got: \(message ?? "nil")")
        XCTAssertTrue(message?.contains("⌃⌥⌘K") ?? false, "got: \(message ?? "nil")")
        XCTAssertTrue(message?.contains("those shortcuts") ?? false, "plural when both failed")
    }
}

// MARK: - InputControlService.parseKeyCombo, "+" as a key

/// The trailing-`"+"` normalization could never end in a successful parse: it rewrote a trailing
/// empty token into a `"+"` key token, and neither keycode table has a `"+"` entry, so the guard
/// at the end always returned nil. `ui_key("cmd++")` — zoom in, an ordinary combo — burned a
/// round-trip on `unknownKeyCombo` while the code read as though "+" were supported.
///
/// The separator and the key are now told apart by how many empty tokens trail, so the
/// modifier-only rejection below is preserved rather than traded away.
final class ParseKeyComboPlusTests: XCTestCase {

    /// US-ANSI `kVK_ANSI_Equal`. "+" is shift+"=", so it has no keycode of its own.
    private let equalsKeyCode: CGKeyCode = 24

    func testCmdPlusPlus_parsesAsCommandShiftEquals() {
        let parsed = InputControlService.parseKeyCombo("cmd++")

        XCTAssertEqual(parsed?.keyCode, equalsKeyCode)
        XCTAssertTrue(parsed?.flags.contains(.maskCommand) ?? false)
        XCTAssertTrue(parsed?.flags.contains(.maskShift) ?? false,
                      "the shift in \"+\" is implicit — the caller must not have to spell it")
    }

    func testBarePlus_parsesAsShiftEquals() {
        let parsed = InputControlService.parseKeyCombo("+")

        XCTAssertEqual(parsed?.keyCode, equalsKeyCode)
        XCTAssertEqual(parsed?.flags, .maskShift)
    }

    /// The case the fix must NOT break: one trailing empty token is a stray separator after a
    /// modifier, not a "+" key. Pinned independently by `testParse_modifierOnly_returnsNil`;
    /// repeated here because it is exactly what distinguishes the two shapes.
    func testTrailingSeparatorAfterModifier_isStillRejected() {
        XCTAssertNil(InputControlService.parseKeyCombo("shift+"))
        XCTAssertNil(InputControlService.parseKeyCombo("cmd+"))
    }

    /// Unchanged neighbours, so the rewrite can't have widened the parse.
    func testOrdinaryCombosAreUnaffected() {
        XCTAssertEqual(InputControlService.parseKeyCombo("cmd+=")?.keyCode, equalsKeyCode)
        XCTAssertEqual(InputControlService.parseKeyCombo("cmd+=")?.flags, .maskCommand)
        XCTAssertNil(InputControlService.parseKeyCombo("cmd+nope"))
    }
}
