import XCTest

@testable import NanoTeams

/// The malformed-JSON diagnostic for the one defect Foundation reports at the position the
/// string OPENED rather than where it breaks.
///
/// Live evidence, 2026-09-12, both `ornith-1.5:35b` on MeditationApp: two `ask_supervisor_form`
/// emissions closed their embedded document correctly and never wrote the closing quote of the
/// `form` value itself. Foundation said "Unterminated string around line 1, column 125"; the
/// model answered "I accidentally used non-ASCII curly quotes" and rewrote the quotes while the
/// missing closer stayed missing (task 74 run 1, reasoning quoted verbatim in its network log).
/// Same lesson as CLAUDE.md #295 one layer down — the fault first, in our own words, or the
/// text printed after it becomes the diagnosis.
final class UnterminatedStringDiagnosticTests: XCTestCase {

    /// Task 71 run 5, trimmed to its frame: the document is complete, the `form` string is not
    /// closed, and the emission ended on the model's own `<|end|>`.
    private static let liveUnterminatedForm = #"""
    <|call|>{"name":"ask_supervisor_form","arguments":{"headline":"Что делаем дальше","form":"{\"questions\": [{\"prompt\": \"Какую область работ выбираем дальше?\", \"kind\": \"free_text\", \"options\": []}]}}<|end|>
    """#

    /// RED: forward Foundation's message here → the defect reads as a column number pointing
    /// at where the string began, which is the failure this exists to stop.
    func testAnUnterminatedArgumentIsNamedByItsKey() throws {
        let defect = try XCTUnwrap(
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: Self.liveUnterminatedForm))
        XCTAssertTrue(defect.contains("`form`"), defect)
        XCTAssertTrue(defect.contains("was never written"), defect)
        XCTAssertFalse(defect.lowercased().contains("column"),
                       "a column number points at where the string opened, not at the fault: \(defect)")
    }

    /// The narrowness IS the contract: every other defect keeps Foundation's message, which
    /// for those does point at the offending character.
    func testAnOtherwiseBrokenEnvelopeKeepsFoundationsMessage() throws {
        // An invalid token, not an unclosed container — Foundation names the character, and
        // it is right to. (A trailing comma is deliberately NOT the specimen here: the repair
        // chain rescues that one, so the diagnostic correctly declines to describe it at all.)
        let invalid = #"<|call|>{"name":"read_file","arguments":{"path":@}}<|end|>"#
        let defect = try XCTUnwrap(ToolCallParsingHelpers.malformedJSONDiagnostic(in: invalid))
        XCTAssertFalse(defect.contains("was never written"), defect)
    }

    /// A well-formed envelope has no defect to name at all.
    func testAWholeEnvelopeYieldsNoDefect() {
        let ok = #"<|call|>{"name":"read_file","arguments":{"path":"a.txt"}}<|end|>"#
        XCTAssertNil(ToolCallParsingHelpers.malformedJSONDiagnostic(in: ok))
    }

    /// No key to attribute it to — the sentence still names the fault rather than a position.
    func testAnUnterminatedDocumentWithNoKeyStillNamesTheFault() throws {
        let defect = try XCTUnwrap(
            ToolCallParsingHelpers.unterminatedStringDefect(in: ##"["{\"a\": 1}"##))
        XCTAssertTrue(defect.contains("a string argument"), defect)
    }

    /// The discriminator, stated as a test: ending inside a string is NOT enough. A stray
    /// quote mid-object leaves byte-identical `unclosed` state (same closers, same
    /// `endsOnCompleteValue`, same `endsInsideString`) — and there Foundation's position is
    /// the fault, which `HarmonyJSONDefectRepairTests` pins.
    ///
    /// RED: gate on `endsInsideString` alone → this payload is described as an unwritten
    /// closing quote, and the model is sent to the end of the text for a defect in the middle.
    func testAStrayQuoteMidObjectIsNotCalledAnUnwrittenCloser() {
        let strayQuote = #"{"name":"write_file","arguments":{"note":"see 588,"path":"a.gd"}}"#
        XCTAssertNil(ToolCallParsingHelpers.unterminatedStringDefect(in: strayQuote))
    }

    /// A document abandoned halfway is a truncated emission, not an unwritten closing quote —
    /// naming it as one would send the model to the wrong end of its own text.
    func testADocumentAbandonedHalfwayIsNotCalledAnUnwrittenCloser() {
        let halfway = ##"{"name":"ask_supervisor_form","arguments":{"form":"{\"questions\": [{\"prompt\""##
        XCTAssertNil(ToolCallParsingHelpers.unterminatedStringDefect(in: halfway))
    }

    /// And the open string has to hold a DOCUMENT, not any text: a prose argument cut off
    /// mid-sentence is a truncated emission, which is a different thing to say.
    func testAnUnterminatedProseArgumentIsNotCalledADocument() {
        let prose = #"{"name":"ask_supervisor","arguments":{"question":"What should I do next"#
        XCTAssertNil(ToolCallParsingHelpers.unterminatedStringDefect(in: prose))
    }

    /// The tool the failing call was FOR, read off text that by definition does not parse.
    func testTheFailingToolIsNamedWhenItsNameSurvived() {
        XCTAssertEqual(
            ToolCallParsingHelpers.intendedToolName(in: Self.liveUnterminatedForm),
            ToolNames.askSupervisorForm)
    }

    /// A name that is not a tool is never echoed back as though the call was nearly right —
    /// that is `.missingToolName`'s arm, which exists to say so.
    func testAnUnregisteredNameIsNotEchoedBack() {
        let hallucinated = #"<|call|>{"name":"grep_files","arguments":{"q":"x<|end|>"#
        XCTAssertNil(ToolCallParsingHelpers.intendedToolName(in: hallucinated))
    }

    /// The nudge carries both halves: the tool it is about, and the fault in our own words.
    func testTheNudgeNamesTheToolAndTheFault() {
        let defect = ToolCallParsingHelpers.malformedJSONDiagnostic(in: Self.liveUnterminatedForm)!
        let nudge = NoToolTurnNudges.malformedJSON(
            defect: "parser error: \(defect)",
            allowedToolNames: [ToolNames.readFile],
            failingToolName: ToolCallParsingHelpers.intendedToolName(in: Self.liveUnterminatedForm))
        XCTAssertTrue(nudge.hasPrefix("The call to `ask_supervisor_form`"), nudge)
        XCTAssertTrue(nudge.contains("`form`"), nudge)
    }

    /// Without a name it stays the sentence it always was.
    func testTheNudgeFallsBackToTheGenericSubject() {
        let nudge = NoToolTurnNudges.malformedJSON(
            defect: "parser error: x", allowedToolNames: [ToolNames.readFile])
        XCTAssertTrue(nudge.hasPrefix("The tool call in the turn"), nudge)
    }

    // MARK: - Both halves of each predicate

    /// A document is a document whichever container opens it. `team_config`'s twin defect
    /// carries an ARRAY at the top of the embedded value, and an argument cut off around one
    /// is the same fault with the same wrong column number — so the `[` half of the opener
    /// test has to hold, not just the `{` half every live payload happened to use.
    ///
    /// RED: drop `|| first == "["` → the array-topped document stops being recognised and the
    /// model gets Foundation's column again.
    func testADocumentOpeningWithAnArrayIsRecognisedToo() throws {
        let arrayTopped = #"""
        <|call|>{"name":"ask_supervisor_form","arguments":{"headline":"H","form":"[{\"prompt\": \"P\", \"kind\": \"free_text\"}]}}<|end|>
        """#
        let defect = try XCTUnwrap(
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: arrayTopped))
        XCTAssertTrue(defect.contains("`form`"), defect)
        XCTAssertTrue(defect.contains("was never written"), defect)
    }

    /// Two defects in one emission: an UNQUOTED key (the shape `repairUnquotedJSONKeys`
    /// exists for) and the unwritten closing quote. The first one means no key string ever
    /// closed before the `:`, so the walk has nothing to name the argument with — and the
    /// sentence degrades to the generic subject instead of naming the wrong key or returning
    /// nothing at all. Naming the fault is worth more than naming the slot.
    ///
    /// RED: drop the `?? key` fallback → an emission carrying two `:` before any closed
    /// string nulls a key it had already found, and the subject names the wrong argument.
    func testAnUnquotedKeyLeavesTheSubjectGenericRatherThanWrong() throws {
        let unquotedKey = #"""
        <|call|>{name:"ask_supervisor_form",arguments:{form:"{\"questions\": [{\"prompt\": \"P\", \"kind\": \"free_text\"}]}}<|end|>
        """#
        let defect = try XCTUnwrap(
            ToolCallParsingHelpers.malformedJSONDiagnostic(in: unquotedKey))
        XCTAssertTrue(defect.contains("a string argument"), defect)
        XCTAssertTrue(defect.contains("was never written"), defect)
    }
}
