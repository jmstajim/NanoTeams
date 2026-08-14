import CoreGraphics
import XCTest

@testable import NanoTeams

/// Three defects in the ⌃⌥⌘K path that survived the coverage waves as characterizations —
/// behaviour recorded rather than fixed, because each was either unreachable from our own
/// writer or rested on an unmeasured premise. All three are now fixed or answered.
final class ClipboardSourceResolutionTests: XCTestCase {

    // MARK: - CRLF in the clip header

    /// `SourceContext.parse` split on `firstIndex(of: "\n")`, which compares `Character`s — and
    /// Swift merges CRLF into ONE cluster that is not equal to `"\n"`. A CRLF-terminated header
    /// therefore had no split point and the whole clip parsed to `nil`, losing the attribution
    /// AND the body: the card renders one undifferentiated blob with no source label.
    ///
    /// Not reachable from this file's own writer (it emits a bare LF, pinned below), but the
    /// trap is invisible in the source, and the reader side is the half that would meet a clip
    /// arriving from anywhere else.
    func testCRLFHeader_splitsIntoSourceAndBody() {
        let clip = "\u{200B}// Source: Sources/App.swift:10-12\r\nlet x = 1"

        let parsed = SourceContext.parse(clip)

        XCTAssertEqual(parsed?.source, "Sources/App.swift:10-12")
        XCTAssertEqual(parsed?.body, "let x = 1", "the \\r must not leak into the body")
    }

    func testLFHeader_stillSplitsExactlyAsBefore() {
        let parsed = SourceContext.parse("\u{200B}// Source: a.swift:1-2\nbody")

        XCTAssertEqual(parsed?.source, "a.swift:1-2")
        XCTAssertEqual(parsed?.body, "body")
    }

    /// A CR-only header (classic Mac line endings, still emitted by some editors) is a line
    /// break too — `firstIndex(of: "\n")` missed this one as well.
    func testCROnlyHeader_alsoSplits() {
        let parsed = SourceContext.parse("\u{200B}// Source: a.swift:1\rbody")

        XCTAssertEqual(parsed?.source, "a.swift:1")
        XCTAssertEqual(parsed?.body, "body")
    }

    /// A body whose FIRST line break is CRLF must keep it — only the header's terminator is
    /// consumed. Otherwise a captured CRLF file would come back subtly re-encoded.
    func testBodyLineEndings_arePreserved() {
        let parsed = SourceContext.parse("\u{200B}// Source: a.swift:1\nline1\r\nline2")

        XCTAssertEqual(parsed?.body, "line1\r\nline2")
    }

    func testHeaderWithNoBody_isStillRejected() {
        XCTAssertNil(SourceContext.parse("\u{200B}// Source: a.swift:1\r\n"))
        XCTAssertNil(SourceContext.parse("\u{200B}// Source: a.swift:1"))
    }

    func testTextWithoutTheSentinel_isNotAClip() {
        XCTAssertNil(SourceContext.parse("// Source: a.swift:1\nbody"),
                     "the zero-width space is what distinguishes our header from user code")
    }

    // MARK: - The document attribute an editor actually reports

    /// `kAXDocumentAttribute` is documented as a URL string and most editors send `file:///…`,
    /// but it carries whatever the app chose to put there and some report a BARE POSIX PATH.
    /// Those were dropped: `URL(string:)` succeeds on a bare path as a scheme-less relative URL,
    /// so the old `isFileURL` test was false and source enrichment silently switched itself off
    /// for that editor — no header, no signal, no way for the user to know it should be there.
    func testBarePOSIXPath_isAcceptedAsADocument() {
        let url = ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "/Users/a/Sources/App.swift")

        XCTAssertEqual(url?.path, "/Users/a/Sources/App.swift")
    }

    func testFileURL_stillResolves() {
        let url = ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "file:///Users/a/App.swift")

        XCTAssertEqual(url?.path, "/Users/a/App.swift")
    }

    /// Percent-escapes only mean something in the URL form. A bare path is taken literally, so a
    /// file genuinely named `My%20File.swift` resolves to itself rather than to `My File.swift`.
    func testPercentEscapes_areDecodedForURLsAndTakenLiterallyForPaths() {
        XCTAssertEqual(
            ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "file:///Users/a/My%20File.swift")?.path,
            "/Users/a/My File.swift")
        XCTAssertEqual(
            ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "/Users/a/My%20File.swift")?.path,
            "/Users/a/My%20File.swift")
    }

    /// The leading-slash requirement is the guard that matters. `URL(fileURLWithPath:)` resolves
    /// a RELATIVE string against the process's current directory — measured — so accepting one
    /// would fabricate a path inside whatever directory the app happened to be launched from,
    /// and `isWithin` might even admit it.
    func testRelativeString_isRejectedRatherThanResolvedAgainstTheCWD() {
        XCTAssertNil(ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "Sources/App.swift"))
        XCTAssertNil(ClipboardCaptureService.documentURL(fromAXDocumentAttribute: ""))
    }

    /// A non-file scheme is not a document on disk. `read_file` could never open it.
    func testNonFileScheme_isRejected() {
        XCTAssertNil(ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "https://example.com/App.swift"))
        XCTAssertNil(ClipboardCaptureService.documentURL(fromAXDocumentAttribute: "untitled:Untitled-1"))
    }

    // MARK: - fileName is derived, not stored

    /// It used to be a second stored field, set from the same `docURL` the path came from — two
    /// values that had to agree with nothing making them agree — and after the header moved to
    /// `NTMSPaths.relativePathFromProjectRoot` nothing in production read it at all.
    func testFileName_isDerivedFromThePath() {
        XCTAssertEqual(
            SourceContext(filePath: "/Users/a/Sources/App.swift", lineStart: 1, lineEnd: 2).fileName,
            "App.swift")
        XCTAssertEqual(SourceContext(filePath: "", lineStart: nil, lineEnd: nil).fileName, "")
    }

    // MARK: - typeText's single-event premise

    /// `InputControlService.typeText` hands the WHOLE UTF-16 buffer to one
    /// `keyboardSetUnicodeString`. That is only safe if `CGEvent` doesn't cap the string — a cap
    /// would truncate long text silently, which is the failure mode this codebase treats as
    /// worse than the cap itself ("no silent caps").
    ///
    /// Measured here rather than assumed, and measured WITHOUT posting: the string is written to
    /// an unposted event and read back. Posting is what would type into the developer's
    /// frontmost window, and no test may do that.
    ///
    /// What this does NOT establish: whether a RECEIVING application consumes the whole string
    /// once the event is posted. That is the target app's behaviour, outside this process and
    /// unmeasurable without synthesizing real input.
    func testCGEventCarriesLongStringsWholeSoTypeTextNeedsNoChunking() throws {
        for length in [1, 128, 4096, 20_000] {
            XCTAssertEqual(try roundTripUTF16Count(String(repeating: "a", count: length)), length,
                           "CGEvent truncated at \(length) UTF-16 units")
        }
    }

    /// Non-BMP text is two UTF-16 units per character, so the buffer `typeText` builds is longer
    /// than the string's `count`. Pins that the surrogate pairs survive intact.
    func testCGEventCarriesSurrogatePairsIntact() throws {
        XCTAssertEqual(try roundTripUTF16Count(String(repeating: "😀", count: 200)), 400)
    }

    /// Writes `text` onto an unposted keyboard event and reads it back, returning the UTF-16
    /// length the event actually retained.
    private func roundTripUTF16Count(_ text: String) throws -> Int {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            throw XCTSkip("CGEvent could not be created in this environment")
        }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        var actual = 0
        // Ask for far more than was written, so a short answer means the event truncated.
        var out = [UniChar](repeating: 0, count: utf16.count + 4096)
        out.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                event.keyboardGetUnicodeString(
                    maxStringLength: buffer.count, actualStringLength: &actual, unicodeString: base)
            }
        }
        return actual
    }
}
