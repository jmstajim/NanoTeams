import XCTest

@testable import NanoTeams

/// `SupervisorFormTextRepair` — the `form` argument as `ornith-1.5:35b` spells it in Russian
/// (MeditationApp task 52, runs 9–11, 2026-09-11), read into the JSON the decoder wants, with
/// every rewrite reported. Not `@MainActor`: a pure function over a `String`.
final class SupervisorFormTextRepairTests: XCTestCase {

    private func parses(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func label(_ text: String, question q: Int = 0, option o: Int = 0) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = root["questions"] as? [[String: Any]],
              let options = questions[q]["options"] as? [[String: Any]]
        else { return nil }
        return options[o]["label"] as? String
    }

    // MARK: - Nothing to repair

    /// RED: rebuild `text` from the scalar walk unconditionally → a byte-identical copy
    /// still counts as "changed" for a caller comparing identity, and the note check below
    /// is the only thing that would notice.
    func testValidJSON_isReturnedUnchanged_withNoNotes() {
        let text = #"{"questions": [{"prompt": "Which?", "kind": "free_text"}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.notes, [])
        XCTAssertFalse(outcome.changed)
    }

    /// Typographic quotes INSIDE a `"`-string are content — a Russian detail full of them
    /// must come through untouched.
    func testGuillemetsInsideAQuotedString_areContent() {
        let text = #"{"questions": [{"prompt": "Тема «медитация» или «сон»?", "kind": "free_text"}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.notes, [])
    }

    // MARK: - « » as string delimiters

    func testGuillemetDelimitedValue_becomesAQuotedString() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "single_choice", "options": [{"label": «Тёмная тема»}, {"label": «Светлая»}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Тёмная тема")
        XCTAssertEqual(label(outcome.text, option: 1), "Светлая")
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.requotedNote(count: 2)])
    }

    /// The live shape of run 9: opened with `«`, closed with a bare `"` before the comma.
    func testGuillemetOpenedValue_closedByAPlainQuoteBeforeAComma_isTheLiveShape() {
        let text = #"{"questions": [{"prompt": "Тени?", "kind": "single_choice", "options": [{"label": «Без правок по теням", "detail": "Оставить как есть."}, {"label": "Тонкие тени"}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Без правок по теням")
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.requotedNote(count: 1)])
    }

    func testNestedGuillemets_insideAGuillemetString_areKeptVerbatim() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "single_choice", "options": [{"label": «Тёмная «медитативная» тема»}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Тёмная «медитативная» тема")
    }

    /// A `"` inside a typographic string that is NOT followed by structure is content, and
    /// content has to be escaped or the emitted JSON string ends early.
    func testAQuoteInsideAGuillemetString_notBeforeStructure_isEscapedNotAClose() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "single_choice", "options": [{"label": «Режим "тихий" по умолчанию»}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Режим \"тихий\" по умолчанию")
    }

    /// An already-escaped quote is copied once, never doubled into `\\"`.
    func testAnEscapedQuoteInsideAGuillemetString_isCopiedOnce() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "single_choice", "options": [{"label": «Режим \"тихий\"»}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Режим \"тихий\"")
    }

    func testGuillemetKeys_areReadAsKeys() {
        let text = #"{«questions»: [{«prompt»: «Какой?», «kind»: «free_text»}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.requotedNote(count: 5)])
    }

    func testCurlyDoubleQuotes_areReadTheSameWay() {
        let text = #"{"questions": [{"prompt": "Which?", "kind": "single_choice", "options": [{"label": “Dark theme”}, {"label": “Light”}]}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(label(outcome.text), "Dark theme")
        XCTAssertEqual(label(outcome.text, option: 1), "Light")
    }

    /// The first closer wins. Read greedily to the next `»`, this string would swallow
    /// `", "b": "y` and the document would end inside a value.
    func testTheFirstCloserWins_aLaterGuillemetDoesNotSwallowTheNextValue() {
        let text = #"{"a": «x", "b": "y»z"}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        let data = outcome.text.data(using: .utf8)!
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(root["a"], "x")
        XCTAssertEqual(root["b"], "y»z")
    }

    /// `»` at depth zero closes on its own — the structural character may sit on the next line.
    func testACloserFollowedByANewline_thenAComma_closes() {
        let text = "{\"questions\": [{\"prompt\": «Какой?»\n, \"kind\": \"free_text\"}]}"
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
    }

    /// Everything repaired BEFORE the unterminated quote is kept; the rest is handed to the
    /// parser as written, so the excerpt names the very character.
    func testAnUnterminatedGuillemet_keepsEarlierRepairs_andLeavesTheRest() {
        let text = #"{"questions": [{"prompt": «Первый», "kind": "free_text"}, {"prompt": «Второй без конца"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(outcome.text.hasPrefix(#"{"questions": [{"prompt": "Первый", "kind": "free_text"}, {"prompt": «Второй без конца"#), outcome.text)
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.requotedNote(count: 1)])
        XCTAssertFalse(parses(outcome.text))
    }

    // MARK: - Extra closers

    /// Run 11 ended every attempt with `}]}]}}` — one `}` past the top-level object.
    func testExtraClosingBracesAfterTheTopLevelValue_areDroppedAndCounted() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "single_choice", "options": [{"label": "A"}]}]}}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertTrue(parses(outcome.text), outcome.text)
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.droppedClosersNote(count: 1)])
        let three = SupervisorFormTextRepair.repair(text + "]}\n")
        XCTAssertTrue(parses(three.text), three.text)
        XCTAssertEqual(three.notes, [SupervisorFormTextRepair.droppedClosersNote(count: 3)])
    }

    func testBracesInsideStrings_doNotCloseTheTopLevelValue() {
        let text = #"{"questions": [{"prompt": "Скобки } и ] в тексте", "kind": "free_text"}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.notes, [])
    }

    /// A tail that is not closers is not a shape this pass reads.
    func testTrailingProseAfterTheTopLevelValue_isLeftForTheParser() {
        let text = #"{"questions": [{"prompt": "Какой?", "kind": "free_text"}]} и ещё текст"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.notes, [])
        XCTAssertFalse(parses(outcome.text))
    }

    // MARK: - Notes and idempotence

    func testNotesNameEachRuleOnce_withCounts() {
        let text = #"{"questions": [{"prompt": «А», "kind": "free_text"}, {"prompt": «Б», "kind": "free_text"}]}}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(outcome.notes, [
            SupervisorFormTextRepair.requotedNote(count: 2),
            SupervisorFormTextRepair.droppedClosersNote(count: 1),
        ])
        XCTAssertTrue(outcome.notes[0].hasPrefix("2 string(s)"), outcome.notes[0])
        XCTAssertTrue(outcome.notes[1].hasPrefix("1 closing bracket(s)"), outcome.notes[1])
    }

    /// An escape pair inside an ordinary `"`-string is copied as ONE unit while a repair runs
    /// elsewhere in the same document: `\"` must not end the string, and a `\\` right before
    /// the closing quote must not swallow it. RED: drop the pair-copy branch of the in-string
    /// walk → the `\"` closes the headline early and the parser stops on `go`.
    func testAnEscapePairInsideAQuotedString_isCopiedAsOneUnit_whileARepairRunsElsewhere() {
        let text = #"{"headline": "He said \"go\" now \\", "questions": [{"prompt": «Что?», "kind": "free_text"}]}"#
        let outcome = SupervisorFormTextRepair.repair(text)
        XCTAssertEqual(
            outcome.text,
            #"{"headline": "He said \"go\" now \\", "questions": [{"prompt": "Что?", "kind": "free_text"}]}"#)
        XCTAssertEqual(outcome.notes, [SupervisorFormTextRepair.requotedNote(count: 1)])
        XCTAssertTrue(parses(outcome.text))
        let root = try? JSONSerialization.jsonObject(with: Data(outcome.text.utf8)) as? [String: Any]
        XCTAssertEqual(root?["headline"] as? String, "He said \"go\" now \\")
    }

    func testRepairIsIdempotent() {
        let text = #"{"questions": [{"prompt": «Какой?», "kind": "single_choice", "options": [{"label": «Тёмная «медитативная» тема»}, {"label": «Свет"}]}]}}"#
        let once = SupervisorFormTextRepair.repair(text)
        let twice = SupervisorFormTextRepair.repair(once.text)
        XCTAssertEqual(twice.text, once.text)
        XCTAssertEqual(twice.notes, [])
    }

    // MARK: - The bound on surplus closers

    /// REC.5 bounds every tolerant-parse seam by a named constant. Past the bound the tail is
    /// debris rather than a slip, and the remainder goes to the parser verbatim so the
    /// message can name where it stopped.
    ///
    /// RED: drop the `maxDroppedClosers` guard → the fourth closer is swallowed too, the
    /// text parses, and a form the model never finished writing is parked.
    func testSurplusClosersPastTheBound_areLeftForTheParser() {
        let form = #"{"questions": [{"prompt": "Which?", "kind": "free_text"}]}"#
        let atBound = SupervisorFormTextRepair.repair(form + "}}}")
        XCTAssertEqual(atBound.notes, [SupervisorFormTextRepair.droppedClosersNote(count: 3)])
        XCTAssertTrue(parses(atBound.text))

        let pastBound = SupervisorFormTextRepair.repair(form + "}}}}")
        XCTAssertFalse(parses(pastBound.text),
                       "past the bound nothing is dropped and the parser reports it: \(pastBound.text)")
    }

    func testEmptyText_isReturnedUnchanged() {
        let outcome = SupervisorFormTextRepair.repair("")
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.notes, [])
    }
}
