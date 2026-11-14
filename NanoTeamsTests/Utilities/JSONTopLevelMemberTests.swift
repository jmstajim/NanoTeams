import XCTest

@testable import NanoTeams

/// `JSONTopLevelMember` — one member of a JSON object's top level, found and rewritten in the
/// text itself, so every other byte of the document survives. Not `@MainActor`: pure functions
/// over a `String`.
final class JSONTopLevelMemberTests: XCTestCase {

    /// The raw text of `key`'s top-level value, or `nil` when there is no such member.
    private func value(of key: String, in json: String) -> String? {
        JSONTopLevelMember(named: key, in: json)?.value
    }

    /// `json` with `key`'s top-level value replaced, or `nil` when there is no such member.
    private func replacingValue(of key: String, in json: String, with newValue: String) -> String? {
        JSONTopLevelMember(named: key, in: json)?.replacingValue(with: newValue)
    }

    // MARK: - value

    func testFindsEachTopLevelValueWhateverItsKind() {
        let json = #"{"data":{"a":[1,2,{"b":"}"}]},"error":null,"meta":{"warnings":[]},"next":{"reason":"r","suggested_cmd":"x"},"ok":true,"n":-1.5e3}"#
        XCTAssertEqual(value(of: "data", in: json), #"{"a":[1,2,{"b":"}"}]}"#)
        XCTAssertEqual(value(of: "error", in: json), "null")
        XCTAssertEqual(value(of: "next", in: json), #"{"reason":"r","suggested_cmd":"x"}"#)
        XCTAssertEqual(value(of: "ok", in: json), "true")
        XCTAssertEqual(value(of: "n", in: json), "-1.5e3")
    }

    /// A key that exists only deeper down is not a top-level member — `task_result`'s data could
    /// hold a `next` of its own, and rewriting that one would corrupt a deliverable.
    func testANestedKeyOfTheSameNameIsNotTheMember() {
        let json = #"{"data":{"next":{"suggested_cmd":"inner"}},"ok":true}"#
        XCTAssertNil(value(of: "next", in: json))
    }

    /// Inside a string a quote is escaped, so `"next":` spelled in text is not a key; neither are
    /// braces and brackets in string content.
    func testKeysAndBracketsInsideStringsAreText() {
        let json = #"{"data":"he said \"next\": {[ and left","next":{"reason":"a \"quoted\" \\ end"},"ok":false}"#
        XCTAssertEqual(
            value(of: "next", in: json),
            #"{"reason":"a \"quoted\" \\ end"}"#)
    }

    func testWhitespaceAroundTokensIsAllowed() {
        let json = "{ \n \"ok\" : true ,\n\t\"next\"\t:\n [ 1 , 2 ] \n}\n"
        XCTAssertEqual(value(of: "next", in: json), "[ 1 , 2 ]")
        XCTAssertEqual(value(of: "ok", in: json), "true")
    }

    /// The scan is byte-wise; a multi-byte character before the member must not shift it.
    func testNonASCIITextBeforeTheMemberKeepsTheRangeRight() {
        let json = #"{"data":{"title":"Задача — проверка 🚀"},"next":{"reason":"ок"}}"#
        XCTAssertEqual(value(of: "next", in: json), #"{"reason":"ок"}"#)
    }

    /// A key spelled with an escape is the same key.
    func testAnEscapedKeyIsDecodedBeforeItIsCompared() {
        let json = #"{"ne\u0078t":{"reason":"r"}}"#
        XCTAssertEqual(value(of: "next", in: json), #"{"reason":"r"}"#)
    }

    func testAbsentKeyEmptyObjectAndNonObjectAnswerNil() {
        XCTAssertNil(value(of: "next", in: #"{"ok":true}"#))
        XCTAssertNil(value(of: "next", in: "{}"))
        XCTAssertNil(value(of: "next", in: ""))
        XCTAssertNil(value(of: "next", in: #"[{"next":1}]"#))
        XCTAssertNil(value(of: "next", in: #""next""#))
        XCTAssertNil(value(of: "next", in: "not json"))
    }

    /// Text that stops mid-document answers nil rather than a range that runs off its end.
    func testTruncatedTextAnswersNil() {
        XCTAssertNil(value(of: "next", in: #"{"next":{"reason":"r""#))
        XCTAssertNil(value(of: "next", in: #"{"next":"unterminated"#))
        XCTAssertNil(value(of: "next", in: #"{"next":"#))
        XCTAssertNil(value(of: "next", in: #"{"ok":true,"#))
        XCTAssertNil(value(of: "next", in: #"{"ok" true,"next":1}"#))
    }

    /// Text that stops where a KEY should begin — after the opening brace, after a comma, with or
    /// without whitespace — and a key that is no string at all, or a string that never closes.
    func testTextThatStopsWhereAKeyShouldBeginAnswersNil() {
        XCTAssertNil(value(of: "next", in: "{"))
        XCTAssertNil(value(of: "next", in: "{ \n"))
        XCTAssertNil(value(of: "next", in: #"{"next":1,"#))
        XCTAssertNil(value(of: "next", in: #"{"next":1, "#), "whitespace after the comma is not a key")
        XCTAssertNil(value(of: "next", in: #"{"ne"#), "a key that never closes")
        XCTAssertNil(value(of: "next", in: #"{next:1}"#), "a bare key is no key")
        XCTAssertNil(value(of: "next", in: #"{"next":1,}"#), "a trailing comma leaves no key where one should begin")
    }

    /// A string that never closes INSIDE a container: the container scan skips strings whole, and
    /// one with no closing quote has no end to skip to — the container is unterminated through it.
    func testAnUnterminatedStringInsideAContainerAnswersNil() {
        XCTAssertNil(value(of: "next", in: #"{"next":{"reason":"r"#))
        XCTAssertNil(value(of: "next", in: #"{"next":["a","b"#))
        XCTAssertNil(value(of: "next", in: #"{"next":{"a":{"b":"c}"#), "the brace inside the open string closes nothing")
        XCTAssertNil(value(of: "next", in: #"{"data":{"x":"y},"next":1}"#), "an earlier member's open string swallows the rest")
    }

    /// A bare value that is NO bytes — the value position holds the delimiter itself — is not a
    /// value: `{"a": }` has no `a`. The spelling of a bare value is not checked, though: `-` alone
    /// is answered as written, since this finds members in a document an encoder wrote.
    func testABareValueOfNoBytesAnswersNil_whileItsSpellingIsNotChecked() {
        XCTAssertNil(value(of: "a", in: #"{"a": }"#))
        XCTAssertNil(value(of: "a", in: #"{"a":}"#))
        XCTAssertNil(value(of: "a", in: #"{"a":,"b":1}"#))
        XCTAssertNil(value(of: "b", in: #"{"a":,"b":1}"#), "the document is refused whole, not just the empty member")
        XCTAssertNil(value(of: "a", in: #"{"a":]}"#))
        XCTAssertEqual(value(of: "a", in: #"{"a": -}"#), "-", "not validated: a bare value is whatever stands before its delimiter")
        XCTAssertEqual(value(of: "a", in: #"{"a":nul}"#), "nul")
    }

    /// A bare number, `true`, `false` or `null` ends at the delimiter after it, so text cut right
    /// after one — or in the middle of one — cannot say where it ends: `{"next":12` may have been
    /// `{"next":123}`. Review of 2026-11-08: the scan accepted the member at the end of the
    /// text and answered `1` and `true` for documents that never closed.
    func testTextThatStopsAfterABareValueAnswersNil() {
        XCTAssertNil(value(of: "next", in: #"{"next":1"#))
        XCTAssertNil(value(of: "next", in: #"{"ok":true,"next":true"#))
        XCTAssertNil(value(of: "next", in: "{\"next\":null \n\t"), "whitespace is no delimiter")
        XCTAssertNil(value(of: "next", in: #"{"next":-1.5e"#))
        XCTAssertNil(value(of: "next", in: #"{"next":fals"#))
        XCTAssertNil(value(of: "next", in: #"{"next":1]"#), "a bracket closes no object")
    }

    /// A member whose own value is complete is still in a document that may not be: the scan
    /// reads to the object's closing brace before it answers, so `replacingValue` never splices
    /// into text that stops after the member — or after any member past it.
    func testTextThatStopsAfterTheMemberAnswersNil() {
        XCTAssertNil(value(of: "next", in: #"{"next":"x""#))
        XCTAssertNil(value(of: "next", in: #"{"next":{"a":1}"#))
        XCTAssertNil(value(of: "next", in: #"{"next":[1,2] "#))
        XCTAssertNil(value(of: "next", in: #"{"next":{"a":1},"ok":tr"#))
        XCTAssertNil(value(of: "next", in: #"{"next":{"a":1},"ok":true"#))
        XCTAssertNil(value(of: "next", in: #"{"next":{"a":1},"#))
        XCTAssertNil(replacingValue(of: "next", in: #"{"ok":true,"next":true"#, with: "false"))
        XCTAssertNil(replacingValue(of: "next", in: #"{"next":{"a":1},"ok":true"#, with: "null"))
    }

    /// The top level must be ONE object: anything but whitespace after its closing brace makes
    /// the text something else.
    func testTextAfterTheClosingBraceAnswersNil() {
        XCTAssertNil(value(of: "next", in: #"{"next":1}x"#))
        XCTAssertNil(value(of: "next", in: #"{"next":1}{"next":2}"#))
        XCTAssertNil(value(of: "next", in: #"{"next":1},"#))
        XCTAssertEqual(value(of: "next", in: "{\"next\":1}\n"), "1", "a trailing newline is whitespace")
    }

    /// The boundaries a bare value meets in a complete document: the closing brace with and
    /// without whitespace, a comma, and the last member.
    func testABareValueEndsAtTheDelimiterAfterIt() {
        XCTAssertEqual(value(of: "next", in: #"{"next":1}"#), "1")
        XCTAssertEqual(value(of: "next", in: "{\"next\":null \n}"), "null")
        XCTAssertEqual(value(of: "next", in: #"{"next":false,"ok":true}"#), "false")
        XCTAssertEqual(value(of: "ok", in: #"{"next":false,"ok":true}"#), "true")
        XCTAssertEqual(
            replacingValue(of: "next", in: #"{"next":1,"ok":true}"#, with: #"{"a":2}"#),
            #"{"next":{"a":2},"ok":true}"#)
    }

    /// Of two members with the same name the first is the member — what `JSONSerialization`
    /// reads too — and the document is still read to its end.
    func testADuplicateKeyAnswersTheFirstAndStillNeedsAWholeDocument() {
        XCTAssertEqual(value(of: "next", in: #"{"next":1,"next":2}"#), "1")
        XCTAssertNil(value(of: "next", in: #"{"next":1,"next":2"#))
    }

    // MARK: - replacingValue

    /// Only the member's value moves; the bytes before and after — an ordered `data` object
    /// included — come back exactly as they were.
    func testReplacingKeepsEveryOtherByte() {
        let json = #"{"data":{"index":[1],"deliverables":[],"changed_files":[]},"error":null,"meta":{},"next":{"suggested_cmd":"x"},"ok":true}"#
        let replaced = replacingValue(of: "next", in: json, with: #"{"suggested_cmd":"y","suggested_args":{"task_id":3}}"#)
        XCTAssertEqual(
            replaced,
            #"{"data":{"index":[1],"deliverables":[],"changed_files":[]},"error":null,"meta":{},"next":{"suggested_cmd":"y","suggested_args":{"task_id":3}},"ok":true}"#)
    }

    func testReplacingTheLastMemberAndANonASCIIValue() {
        let json = #"{"ok":true,"next":"старое"}"#
        XCTAssertEqual(
            replacingValue(of: "next", in: json, with: #""новое""#),
            #"{"ok":true,"next":"новое"}"#)
    }

    func testReplacingAnAbsentMemberAnswersNil() {
        XCTAssertNil(replacingValue(of: "next", in: #"{"ok":true}"#, with: "1"))
        XCTAssertNil(replacingValue(of: "next", in: "garbage", with: "1"))
    }

    /// One scan serves both looks: the member read and the member rewritten are the same range,
    /// so the handle rewrites exactly the bytes it reads — the first member, the last, an empty
    /// value in between — and rewriting twice from one handle starts from the original each time.
    func testOneHandleReadsAndRewritesTheSameBytes() throws {
        let json = #"{"first":[1],"next":{},"last":"z"}"#
        let first = try XCTUnwrap(JSONTopLevelMember(named: "first", in: json))
        let next = try XCTUnwrap(JSONTopLevelMember(named: "next", in: json))
        let last = try XCTUnwrap(JSONTopLevelMember(named: "last", in: json))
        XCTAssertEqual(first.value, "[1]")
        XCTAssertEqual(next.value, "{}")
        XCTAssertEqual(last.value, #""z""#)
        XCTAssertEqual(first.replacingValue(with: "0"), #"{"first":0,"next":{},"last":"z"}"#)
        XCTAssertEqual(next.replacingValue(with: #"{"a":1}"#), #"{"first":[1],"next":{"a":1},"last":"z"}"#)
        XCTAssertEqual(last.replacingValue(with: "null"), #"{"first":[1],"next":{},"last":null}"#)
        XCTAssertEqual(next.replacingValue(with: ""), #"{"first":[1],"next":,"last":"z"}"#, "the caller's text, whatever it is")
        XCTAssertEqual(
            next.replacingValue(with: "1"), #"{"first":[1],"next":1,"last":"z"}"#,
            "a later rewrite starts from the original, not from the rewrite before it")
    }
}
