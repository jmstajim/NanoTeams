import XCTest

@testable import NanoTeams

/// `JSONStructuralCloserRepair` — the one scan that says where a model dropped a `}` or a
/// `]`, shared by the two seams that carry a JSON document inside a `String` tool argument
/// (`create_team`'s `team_config`, `ask_supervisor_form`'s `form`).
/// Not `@MainActor`: a pure function over a `String`.
final class JSONStructuralCloserRepairTests: XCTestCase {

    private func repaired(_ text: String) -> String? {
        JSONStructuralCloserRepair.insertingDroppedCloser(in: text)
    }

    private func closed(_ text: String) -> String? {
        JSONStructuralCloserRepair.closingTheTopLevelContainer(in: text)
    }

    private func parses(_ text: String?) -> Bool {
        guard let text, let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    // MARK: - Nothing dropped

    /// RED: drop the KEY-POSITION condition (`lastSignificant` is `,` or `{`) from that branch
    /// → a container standing as an ordinary VALUE fires it, and `"d": [{"e": 2}]` after a
    /// comma reads as a drop.
    func testValidJSON_getsNoCandidate() {
        XCTAssertNil(repaired(#"{"q":[{"a":1},{"b":2}]}"#))
        XCTAssertNil(repaired(#"{"a":{"b":{"c":1}},"d":[{"e":2}]}"#))
        XCTAssertNil(repaired("{}"))
        XCTAssertNil(repaired(""))
    }

    /// An object as a VALUE is ordinary JSON — it stands right after `:` — and must never be
    /// read as the key-position defect below.
    func testAnObjectAsAValue_isNotADrop() {
        XCTAssertNil(repaired(#"{"outer":{"inner":{"deep":true}}}"#))
    }

    // MARK: - The three contradictions

    /// The live shape of MeditationApp task 65 run 0, attempt 1 (abridged): the options array
    /// closed, and then a new question object opened where the enclosing question still
    /// wanted a KEY. The `}` belongs before the separating comma, not at the point the
    /// contradiction was noticed.
    ///
    /// RED: insert at the offending `{` instead of walking back to the comma → the candidate
    /// reads `…}], }{"prompt"…` and does not parse.
    func testAnObjectWhereAKeyBelongs_closesTheEnclosingObjectBeforeTheComma() {
        let text = #"{"questions":[{"prompt":"A","kind":"single_choice","options":[{"label":"x"}], {"prompt":"B","kind":"free_text"}]}"#
        let candidate = repaired(text)
        XCTAssertEqual(
            candidate,
            #"{"questions":[{"prompt":"A","kind":"single_choice","options":[{"label":"x"}]}, {"prompt":"B","kind":"free_text"}]}"#)
        XCTAssertTrue(parses(candidate))
    }

    /// The walk-back target is the separating comma, so a container in key position with no
    /// comma before it is not this shape — it is a missing separator as well as a missing
    /// closer, and guessing which came first would invent two edits from one observation.
    func testAContainerInKeyPositionWithNoSeparator_getsNoCandidate() {
        XCTAssertNil(repaired(#"{"a":{{"c":2}}"#))
    }

    /// A `}` while an array is innermost: the array's `]` was dropped.
    func testAnArrayClosedByTheObjectsBrace_getsItsBracket() {
        let candidate = repaired(#"{"roles":[{"name":"A","tools":["read_file"}]}"#)
        XCTAssertEqual(candidate, #"{"roles":[{"name":"A","tools":["read_file"]}]}"#)
        XCTAssertTrue(parses(candidate))
    }

    /// A `]` while an object is innermost: the object's `}` was dropped.
    func testAnObjectClosedByTheArraysBracket_getsItsBrace() {
        let candidate = repaired(#"{"a":{"b":[1,2}}"#)
        XCTAssertEqual(candidate, #"{"a":{"b":[1,2]}}"#)
        XCTAssertTrue(parses(candidate))
    }

    /// A `key: value` pair inside an array — impossible in JSON, so the array's `]` was
    /// dropped before the key. This is the `create_team` shape the repair was written for.
    func testAKeyInsideAnArray_closesTheArrayBeforeTheSeparatingComma() {
        let candidate = repaired(#"{"roles":[{"name":"A"}, "artifacts": ["x"]}"#)
        XCTAssertEqual(candidate, #"{"roles":[{"name":"A"}], "artifacts": ["x"]}"#)
        XCTAssertTrue(parses(candidate))
    }

    /// The comma is the ONLY place the bracket can go. A key standing as the array's FIRST
    /// element has no comma before it, and closing at the key's own start would put `]`
    /// immediately before a `"` — which no container accepts after a closer. Until
    /// 2026-09-12 the scan offered that position anyway and every caller refused the result,
    /// because it could not parse; the arm was removed rather than pinned (CLAUDE.md #189).
    ///
    /// RED: restore `arrayComma ?? keyStart` → this returns `{"roles":[]"name":"A"]}`.
    func testAKeyAsTheArraysFirstElement_getsNoCandidate() {
        XCTAssertNil(repaired(#"{"roles":["name":"A"]}"#))
    }

    // MARK: - Where the repair stops

    /// A document that simply STOPS is not MIS-NESTED: nothing in it contradicts itself, so
    /// this scan has nothing to insert. What such a tail owes is the other repair's question,
    /// and it answers it far more narrowly — see `closingTheTopLevelContainer` below.
    ///
    /// RED: return a candidate whenever the walk reaches end of text with a non-empty stack →
    /// this returns `…"free_text"}]}` from the insertion repair, which is supposed to insert
    /// INSIDE the document.
    func testATruncatedDocument_getsNoInsertion() {
        XCTAssertNil(repaired(#"{"questions": [{"prompt": "Which?", "kind": "free_text"}"#))
        XCTAssertNil(repaired(#"{"questions": [{"prompt": "Whi"#))
    }

    /// A missing COMMA is not a missing closer, and the two are not interchangeable.
    func testAMissingSeparator_isNotADroppedCloser() {
        XCTAssertNil(repaired(
            #"{"questions": [{"prompt": "A", "kind": "free_text"} {"prompt": "B", "kind": "free_text"}]}"#))
    }

    /// Exactly one closer. Two drops are a different failure, and a scan that kept inserting
    /// would eventually make any debris parse.
    func testOnlyOneCloserIsEverInserted() {
        let candidate = repaired(#"{"a":[{"b":["c"}}"#)
        XCTAssertFalse(parses(candidate), "one insertion cannot close two drops: \(candidate ?? "nil")")
    }

    /// Braces and brackets inside a string are content; a scan that counted them would
    /// "repair" a form whose prompt mentions JSON.
    func testStructuralCharactersInsideStrings_areContent() {
        XCTAssertNil(repaired(#"{"q":[{"prompt":"Use {\"a\": [1]} here?","kind":"free_text"}]}"#))
    }

    /// An escaped quote does not end a string, so the scan must not resume counting inside
    /// one — `\"` is two scalars and one character of content.
    func testAnEscapedQuote_doesNotEndTheString() {
        XCTAssertNil(repaired(#"{"q":[{"prompt":"He said \"}]\" once","kind":"free_text"}]}"#))
    }

    /// The scan does not decide whether the candidate is good — the caller does, by decoding
    /// it. Here the comma is real and the brace is in key position, so the scan fires; the
    /// document is broken in a second way it cannot see, and the candidate still fails.
    func testACandidateIsReturnedUnparsed_soTheCallerCanRefuseIt() {
        let candidate = repaired(#"{"a":{"b":1,{"c":2}}}"#)
        XCTAssertEqual(candidate, #"{"a":{"b":1},{"c":2}}}"#)
        XCTAssertFalse(parses(candidate), "the caller's decode is the adoption test")
    }

    /// A dropped OPENER is the other live shape (2026-09-10): the top-level value closes and
    /// prose-shaped debris follows. Nothing is mis-nested before that point, so the scan
    /// stays out and the form is refused with the excerpt, as it was.
    func testADroppedOpenerAfterTheTopLevelValue_getsNoCandidate() {
        XCTAssertNil(repaired(
            #"{"questions":[{"prompt":"A","kind":"free_text"}]},"prompt":"B","kind":"free_text"}]}"#))
    }

    // MARK: - The form's own closer, at end of text

    /// The live shape of MeditationApp task 67 run 1 (abridged to its structure): every
    /// container the model opened inside the document is closed, and only the `}` around the
    /// whole thing is missing. Nothing is missing from the CONTENT, so putting the frame back
    /// invents nothing.
    ///
    /// RED: require `endsOnCompleteValue` to be false → the live shape is refused and the
    /// three-call, fifty-second round trip this repair exists to remove comes back.
    func testADocumentMissingOnlyItsOwnCloser_getsIt() {
        let text = #"{"questions": [{"prompt":"A","kind":"free_text"},{"prompt":"B","kind":"free_text"}]"#
        let candidate = closed(text)
        XCTAssertEqual(candidate, text + "}")
        XCTAssertTrue(parses(candidate))
    }

    /// A top-level ARRAY owes its own bracket, not a brace — the closer is read off what was
    /// opened, never assumed.
    func testATopLevelArray_getsABracket() {
        XCTAssertEqual(closed(#"[{"a":1},{"b":2}"#), #"[{"a":1},{"b":2}]"#)
    }

    /// Two or more containers open at the end is the other thing entirely: something the
    /// model was in the middle of writing never finished, and closing it would launder an
    /// abandoned emission into a questionnaire that reads as whole (CLAUDE.md #293).
    ///
    /// RED: bound the repair by `maxDroppedClosers` (3) instead of by ONE → a form abandoned
    /// after its first question is padded into a form with one question, and the Supervisor
    /// is asked to fill in a questionnaire the model never finished writing.
    func testMoreThanTheFrameOpen_isRefused() {
        XCTAssertNil(closed(#"{"questions": [{"prompt":"A","kind":"free_text"}"#))
        XCTAssertNil(closed(#"{"questions": [{"prompt":"A","kind":"single_choice","options":[{"label":"x"}]"#))
    }

    /// A separator or an opener as the last thing written means the value after it was never
    /// written — brackets are not what is missing.
    ///
    /// RED: drop the `endsOnCompleteValue` guard → `{"a":1,}` and `{"a":}` are "repaired"
    /// into text that still does not parse, and the refusal that would have named the real
    /// state never runs.
    func testATailThatBreaksOffMidValue_isRefused() {
        XCTAssertNil(closed(#"{"a":1,"#))
        XCTAssertNil(closed(#"{"a":"#))
        XCTAssertNil(closed(#"{"a":["#))
        XCTAssertNil(closed(#"{"#))
    }

    /// A bare literal at end of text is the cut nothing downstream can see: `12` is a
    /// well-formed number, and so is the `125` the model was writing. The rule is therefore
    /// the small ALLOWED set — a closed string or a closed container — and not a list of
    /// exclusions, which would admit every literal by omission.
    ///
    /// RED: state the guard as "not `,` `:` `{` `[`" → `{"a":[1,2],"b":12` is closed into a
    /// document that parses, with `b` silently truncated to a different number.
    func testABareLiteralAtEndOfText_isNotACompleteValue() {
        XCTAssertNil(closed(#"{"a":[1,2],"b":12"#))
        XCTAssertNil(closed(#"{"a":tru"#))
        XCTAssertNil(closed(#"{"a":true"#))
        XCTAssertNil(closed(#"{"a":null"#))
    }

    /// An unterminated string is the same state seen from inside one: the value itself breaks
    /// off, and the brace counting stopped being meaningful at the opening quote.
    func testATailInsideAString_isRefused() {
        XCTAssertNil(closed(#"{"questions":[{"prompt":"Как"#))
        XCTAssertNil(closed(##"{"a":"x\""##))
    }

    /// Nothing owed, nothing appended — a valid document is never touched, and neither is one
    /// whose tail is surplus closers (that is `SupervisorFormTextRepair`'s).
    func testABalancedDocument_isNotPadded() {
        XCTAssertNil(closed(#"{"questions":[{"a":1}]}"#))
        XCTAssertNil(closed(#"{"a":1}}"#))
        XCTAssertNil(closed(""))
        XCTAssertNil(closed("   "))
    }

    /// Braces inside a string are content on this path too — a form whose prompt quotes JSON
    /// must not be read as owing a bracket.
    func testStructuralCharactersInsideStrings_areNotOwed() {
        XCTAssertNil(closed(#"{"q":[{"prompt":"Use {\"a\": [1]} here?","kind":"free_text"}]}"#))
        XCTAssertEqual(
            closed(#"{"q":[{"prompt":"Use {} here?","kind":"free_text"}]"#),
            #"{"q":[{"prompt":"Use {} here?","kind":"free_text"}]}"#)
    }

    /// The two repairs answer different questions about the same walk, and a document that
    /// contradicts itself INSIDE belongs to the first one: the tail repair must not fire on
    /// it, or a mis-nested document would get a closer appended at the wrong end.
    ///
    /// RED: report the end-of-text stack even when the walk returned a drop → this document
    /// gets `}` appended and the insertion that would have fixed it is never tried.
    func testADocumentWithADropInside_isNotTheTailRepairsShape() {
        let text = #"{"questions":[{"prompt":"A","options":[{"label":"x"}], {"prompt":"B"}]}"#
        XCTAssertNil(closed(text))
        XCTAssertTrue(parses(repaired(text)))
    }

    /// The candidate is unparsed here too: a document that owes exactly one closer can still
    /// be broken in a way the walk cannot see — here a separator the model never wrote — and
    /// the caller's decode is the adoption test.
    func testTheTailCandidateIsReturnedUnparsed() {
        let candidate = closed(#"{"a":"x" "b":"y""#)
        XCTAssertEqual(candidate, #"{"a":"x" "b":"y"}"#)
        XCTAssertFalse(parses(candidate), "the caller's decode is the adoption test")
    }

    // MARK: - What is owed

    /// The refusal has to tell the model what to append, so the owed closers are read off the
    /// same walk — innermost first, in the order they would be written.
    func testTheOwedClosersAreReportedInWritingOrder() {
        let unclosed = JSONStructuralCloserRepair.unclosed(
            in: #"{"questions":[{"prompt":"A","options":[{"label":"x"}"#)
        XCTAssertEqual(unclosed?.closers, "]}]}")
        XCTAssertEqual(unclosed?.endsOnCompleteValue, true)
    }

    /// RED: report `endsOnCompleteValue` from the stack rather than from the last thing
    /// written → a form that stops after a comma is reported as merely short of brackets,
    /// and the refusal names the wrong fault.
    func testATailThatBreaksOffMidValue_saysSo() {
        XCTAssertEqual(
            JSONStructuralCloserRepair.unclosed(in: #"{"questions":[{"prompt":"#)?
                .endsOnCompleteValue,
            false)
        XCTAssertEqual(
            JSONStructuralCloserRepair.unclosed(in: #"{"questions":[{"prompt":"A","#)?
                .endsOnCompleteValue,
            false)
    }

    func testABalancedDocument_owesNothing() {
        XCTAssertNil(JSONStructuralCloserRepair.unclosed(in: #"{"a":1}"#))
        XCTAssertNil(JSONStructuralCloserRepair.unclosed(in: ""))
    }

    // MARK: - Closers in the wrong order

    /// The live shape, reduced to its skeleton: an option object inside an `options` array
    /// inside a question object inside a `questions` array inside `form` inside `arguments`
    /// inside the envelope owes `}]}]}}}`, and the model wrote `}]}}]}}` — the same seven
    /// closers with two of them swapped.
    ///
    /// RED: drop the reorder from `appliedRepairs` → `ornith-1.5:35b` loses 8 of every 34
    /// questionnaires to `MALFORMED_TOOL_CALL` (MeditationApp task 75, 2026-09-12).
    func testTheLiveTransposedTail_isPutBackInNestingOrder() throws {
        let head = #"{"name":"f","arguments":{"form":{"questions":[{"options":[{"label":"x""#
        let repaired = try XCTUnwrap(
            JSONStructuralCloserRepair.reorderingTrailingClosers(in: head + "}]}}]}}"))
        XCTAssertEqual(repaired, head + "}]}]}}}")
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(repaired.utf8)),
            "the repaired candidate is what the caller adopts, so it has to parse")
    }

    /// The shallower live variant: four closers, two of them swapped.
    func testAShortTail_isReordered() {
        let head = #"{"a":{"b":[{"c":"x""#
        XCTAssertEqual(
            JSONStructuralCloserRepair.reorderingTrailingClosers(in: head + "}}]}"),
            head + "}]}}")
    }

    /// RED: compare the sorted runs only → a tail already in the right order is "repaired"
    /// into itself, the caller adopts a no-op rewrite and reports a defect that was not there.
    func testATailAlreadyInTheRightOrder_isNotARepair() {
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(
            in: #"{"a":{"b":[{"c":"x"}]}}"#))
    }

    /// The other two live miscounts: one closer too many, and a run of the right length whose
    /// KINDS do not match what is open. Reordering cannot express either, and inventing an
    /// answer for them would launder a different defect into a dispatched call.
    func testARunThatOwesADifferentMultiset_isRefused() {
        // One `}` too many — the shape of MeditationApp task 75 run 7, emission 5.
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(
            in: #"{"a":{"b":"x""# + "}}}"))
        // Four closers where four are owed, but two `]` against one.
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(
            in: #"{"a":{"b":[{"c":"x""# + "]]}}"))
    }

    /// A single owed closer cannot be out of order, and a text ending on something else is
    /// not this defect at all.
    func testATailOfFewerThanTwoClosers_isRefused() {
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(in: #"{"a":"x""# + "}"))
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(in: #"{"a":"x""#))
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(in: ""))
    }

    /// RED: drop the `endsOnCompleteValue` guard → an emission abandoned after a colon or a
    /// comma gets its brackets shuffled and reads as a finished document (R3.7.6, #293).
    func testAnEmissionAbandonedMidValue_isRefused() {
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(
            in: #"{"a":{"b":[{"c":"# + "}}]}"))
        XCTAssertNil(JSONStructuralCloserRepair.reorderingTrailingClosers(
            in: #"{"a":{"b":[{"c":"x","# + "}}]}"))
    }

    /// Closers that live INSIDE a string are text, not structure — the trailing run stops at
    /// the quote that closes them, so the `}]}` in this value is never counted.
    func testClosersInsideAStringValue_areNotTheTrailingRun() {
        XCTAssertEqual(
            JSONStructuralCloserRepair.reorderingTrailingClosers(
                in: #"{"a":{"b":[{"c":"}]}""# + "}}]}"),
            #"{"a":{"b":[{"c":"}]}""# + "}]}}")
    }
}
