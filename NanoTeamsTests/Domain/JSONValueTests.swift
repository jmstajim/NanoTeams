import XCTest

@testable import NanoTeams

/// `JSONValue` holds a foreign JSON document verbatim and renders it back byte-stably.
/// The canonical rendering is a trust input — it is what a tool pin hashes — so the
/// cases that would make the same schema hash differently across launches are the ones
/// worth pinning.
final class JSONValueTests: XCTestCase {

    // MARK: - Round trip

    func testDecodesEveryScalarShape() throws {
        let json = #"{"n": null, "b": true, "i": 42, "d": 1.5, "s": "x"}"#
        let value = try decode(json)
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["i"], .int(42))
        XCTAssertEqual(value["d"], .double(1.5))
        XCTAssertEqual(value["s"], .string("x"))
    }

    func testBooleanDoesNotDecodeAsNumber() throws {
        // `JSONDecoder` will read `true` through `Int` if asked — a schema's
        // `"readOnly": true` would then pin, and render to a reviewer, as `1`.
        let value = try decode(#"{"readOnly": true}"#)
        XCTAssertEqual(value["readOnly"], .bool(true))
        XCTAssertNil(value["readOnly"]?.intValue)
    }

    func testIntegerStaysIntegerThroughRoundTrip() throws {
        let value = try decode(#"{"maxItems": 5}"#)
        XCTAssertEqual(value.canonicalJSONString(), #"{"maxItems":5}"#)
        let reencoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(again.canonicalJSONString(), #"{"maxItems":5}"#)
    }

    func testNestedContainersSurviveRoundTrip() throws {
        let json = #"{"a": [1, {"b": [true, null]}], "c": {}}"#
        let value = try decode(json)
        let reencoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(value, again)
        XCTAssertEqual(again.canonicalJSONString(), #"{"a":[1,{"b":[true,null]}],"c":{}}"#)
    }

    // MARK: - Canonical form

    func testCanonicalSortsKeysRegardlessOfInsertionOrder() {
        let one: JSONValue = .object(["b": .int(1), "a": .int(2), "C": .int(3)])
        let two: JSONValue = .object(["C": .int(3), "a": .int(2), "b": .int(1)])
        XCTAssertEqual(one.canonicalJSONString(), two.canonicalJSONString())
        // Uppercase sorts before lowercase — unicode scalar order, not a locale collation.
        XCTAssertEqual(one.canonicalJSONString(), #"{"C":3,"a":2,"b":1}"#)
    }

    func testCanonicalSortsNestedObjectsToo() {
        let value: JSONValue = .object(["outer": .object(["z": .int(1), "a": .int(2)])])
        XCTAssertEqual(value.canonicalJSONString(), #"{"outer":{"a":2,"z":1}}"#)
    }

    func testCanonicalRendersIntegralDoubleWithoutFractionalTail() {
        // `2` and `2.0` are the same JSON number; rendering them differently would make a
        // schema's hash depend on which case the decoder happened to pick.
        XCTAssertEqual(JSONValue.double(2.0).canonicalJSONString(), "2")
        XCTAssertEqual(JSONValue.int(2).canonicalJSONString(), "2")
    }

    func testCanonicalRendersFractionalDouble() {
        XCTAssertEqual(JSONValue.double(1.5).canonicalJSONString(), "1.5")
        XCTAssertEqual(JSONValue.double(-0.25).canonicalJSONString(), "-0.25")
    }

    func testCanonicalRendersNonFiniteAsNull() {
        // JSON has no spelling for these. They cannot arrive by decoding; rendering them
        // as `null` keeps the canonical form total instead of trapping inside a hash.
        XCTAssertEqual(JSONValue.double(.infinity).canonicalJSONString(), "null")
        XCTAssertEqual(JSONValue.double(.nan).canonicalJSONString(), "null")
    }

    func testCanonicalEscapesControlCharactersAndQuotes() {
        let value: JSONValue = .string("a\"b\\c\nd\te\u{07}f")
        XCTAssertEqual(value.canonicalJSONString(), #""a\"b\\c\nd\te\u0007f""#)
    }

    func testCanonicalEscapesInvisibleCharactersInsideKeys() {
        // A zero-width joiner in a key must not disappear into the canonical form — two
        // schemas differing only by an invisible character have to hash differently.
        let visible: JSONValue = .object(["ab": .int(1)])
        let invisible: JSONValue = .object(["a\u{200D}b": .int(1)])
        XCTAssertNotEqual(visible.canonicalJSONString(), invisible.canonicalJSONString())
    }

    func testCanonicalEmptyContainers() {
        XCTAssertEqual(JSONValue.object([:]).canonicalJSONString(), "{}")
        XCTAssertEqual(JSONValue.array([]).canonicalJSONString(), "[]")
    }

    // MARK: - Foundation bridging

    func testFromFoundationDistinguishesBoolFromNumber() throws {
        let any = try JSONSerialization.jsonObject(with: Data(#"{"b": true, "i": 1}"#.utf8))
        let value = try XCTUnwrap(JSONValue.fromFoundation(any))
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["i"], .int(1))
    }

    func testFromFoundationKeepsFractionalNumbersDouble() throws {
        let any = try JSONSerialization.jsonObject(with: Data(#"{"d": 1.5, "e": 1.0}"#.utf8))
        let value = try XCTUnwrap(JSONValue.fromFoundation(any))
        XCTAssertEqual(value["d"], .double(1.5))
        // `1.0` was written with a fractional part, so it stays a double — and still
        // renders canonically as `1`, which is what keeps the pin stable either way.
        XCTAssertEqual(value["e"], .double(1.0))
        XCTAssertEqual(value.canonicalJSONString(), #"{"d":1.5,"e":1}"#)
    }

    func testFromFoundationRefusesNonJSONLeaf() {
        XCTAssertNil(JSONValue.fromFoundation(["k": Date()]))
        XCTAssertNil(JSONValue.fromFoundation(Double.infinity as NSNumber))
        XCTAssertNil(JSONValue.fromFoundation([URL(fileURLWithPath: "/tmp")]))
    }

    func testToFoundationIsSerializable() throws {
        let value: JSONValue = .object([
            "s": .string("x"), "i": .int(1), "d": .double(1.5),
            "b": .bool(false), "n": .null, "a": .array([.int(1)]),
        ])
        let data = try JSONSerialization.data(withJSONObject: value.toFoundation(), options: [.sortedKeys])
        let back = try XCTUnwrap(JSONValue.fromFoundation(try JSONSerialization.jsonObject(with: data)))
        XCTAssertEqual(back.canonicalJSONString(), value.canonicalJSONString())
    }

    // MARK: - Accessors

    func testAccessorsAnswerNilOffShape() {
        let value: JSONValue = .string("x")
        XCTAssertNil(value.objectValue)
        XCTAssertNil(value.arrayValue)
        XCTAssertNil(value.intValue)
        XCTAssertNil(value["anything"])
        XCTAssertFalse(value.isNull)
        XCTAssertTrue(JSONValue.null.isNull)
    }

    func testIntValueAcceptsIntegralDoubleButNotFractional() {
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(1e300).intValue)
    }

    func testDoubleValueWidensInt() {
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3.0)
        XCTAssertNil(JSONValue.string("3").doubleValue)
    }

    func testLiteralsBuildTheExpectedCases() {
        let value: JSONValue = ["a": 1, "b": [true, nil], "c": "s", "d": 1.5]
        XCTAssertEqual(value["a"], .int(1))
        XCTAssertEqual(value["b"], .array([.bool(true), .null]))
        XCTAssertEqual(value["c"], .string("s"))
        XCTAssertEqual(value["d"], .double(1.5))
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: - Encoding

    /// An integral double encodes as an integer, so `{"depth":1}` does not come back as
    /// `{"depth":1.0}` — a byte the model never wrote and the server never cached.
    func testEncodingWritesAnIntegralDoubleAsAnInteger() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = JSONValue.object([
            "whole": .double(1),
            "fraction": .double(1.5),
            "int": .int(7),
            "flag": .bool(true),
            "text": .string("hi"),
            "nothing": .null,
            "list": .array([.int(1), .double(2)]),
        ])
        let json = String(data: try encoder.encode(value), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"whole\":1"), json)
        XCTAssertFalse(json.contains("1.0"), json)
        XCTAssertTrue(json.contains("\"fraction\":1.5"), json)
        XCTAssertTrue(json.contains("\"nothing\":null"), json)
    }

    /// A value too large to be an `Int64`, and one that is not finite, stay doubles rather
    /// than being rounded into a different number.
    func testAHugeOrNonFiniteDoubleStaysADouble() throws {
        let data = try JSONEncoder().encode(JSONValue.double(1e300))
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("e+"))
    }

    func testAValueRoundTripsThroughCodable() throws {
        let value = JSONValue.object(["a": .array([.int(1), .string("x"), .bool(false), .null])])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
        XCTAssertEqual(decoded.objectValue?["a"]?.arrayValue?.count, 4)
    }

    func testTheDictionaryLiteralBuildsAnObject() {
        let value: JSONValue = ["a": .int(1), "b": .string("x")]
        XCTAssertEqual(value.objectValue?["a"], .int(1))
        XCTAssertTrue(value.isObject)
    }

    func testAnIntReadsAsADoubleWhenACallerAsksForOne() {
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3)
        XCTAssertEqual(JSONValue.double(3.5).doubleValue, 3.5)
        XCTAssertNil(JSONValue.string("3").doubleValue)
    }

    /// Every escape the canonical form owes JSON, in one string.
    func testTheCanonicalFormEscapesWhatJSONRequiresAndNothingElse() {
        let value = JSONValue.string("q\"b\\s\n\t\r\u{8}\u{c}\u{1}/")
        let canonical = value.canonicalJSONString()
        XCTAssertTrue(canonical.contains("\\\""), canonical)
        XCTAssertTrue(canonical.contains("\\\\"), canonical)
        XCTAssertTrue(canonical.contains("\\n"), canonical)
        XCTAssertTrue(canonical.contains("\\t"), canonical)
        XCTAssertTrue(canonical.contains("\\r"), canonical)
        XCTAssertTrue(canonical.contains("\\b"), canonical)
        XCTAssertTrue(canonical.contains("\\f"), canonical)
        XCTAssertTrue(canonical.contains("\\u0001"), canonical)
        XCTAssertTrue(canonical.contains("/"), "a forward slash is not escaped: \(canonical)")
    }

    // MARK: - The pretty form (display only)

    /// The review sheet's raw schema: the canonical form laid out for reading — the same
    /// members in the same order, the same escapes, the same numbers, whitespace added between
    /// tokens and nowhere else. Empty containers stay on their line.
    func testThePrettyFormIsTheCanonicalFormLaidOut() throws {
        let value = try decode(#"{"b": [1, 2.5, {"z": null, "a": "x\u0001/"}], "a": {}, "c": [], "d": true}"#)
        XCTAssertEqual(value.prettyJSONString(), #"""
        {
          "a": {},
          "b": [
            1,
            2.5,
            {
              "a": "x\u0001/",
              "z": null
            }
          ],
          "c": [],
          "d": true
        }
        """#)
        XCTAssertEqual(try decode(value.prettyJSONString()), value, "it reads back as the same value")
    }

    /// Member ORDER is the canonical form's for every key, not only for ASCII ones. Swift's
    /// `String <` compares canonically-equivalent forms, so it puts "f" before "e\u{301}"
    /// (read as "é", U+00E9), while the canonical order is by unicode scalars ("e" U+0065 first).
    /// The pretty form with its layout taken out is the canonical form, scalar for scalar — at
    /// the top level and nested.
    ///
    /// RED until 2026-10-28: if the pretty form ordered keys by `String <`, every
    /// test here, all over ASCII keys, passed.
    func testThePrettyFormOrdersEveryKeyAsTheCanonicalFormDoes() throws {
        XCTAssertTrue("f" < "e\u{301}", "premise: String order puts the decomposed key after \"f\"")
        let value = JSONValue.object([
            "f": .int(1),
            "e\u{301}": .object(["f": .bool(true), "e\u{301}": .null]),
        ])
        let canonical = value.canonicalJSONString()
        XCTAssertEqual(
            Array(canonical.unicodeScalars),
            Array("{\"e\u{301}\":{\"e\u{301}\":null,\"f\":true},\"f\":1}".unicodeScalars),
            "premise: the canonical order is by scalars")
        XCTAssertEqual(Array(Self.withoutLayout(value.prettyJSONString()).unicodeScalars), Array(canonical.unicodeScalars))
    }

    /// The pretty form with the whitespace it adds between tokens removed — whitespace inside
    /// a string is the value's, and stays.
    private static func withoutLayout(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inString = false
        var escaped = false
        for scalar in text.unicodeScalars {
            if inString {
                out.append(scalar)
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
            } else if scalar == "\"" {
                inString = true
                out.append(scalar)
            } else if !(scalar == " " || scalar == "\n") {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// A scalar has nothing to lay out: its pretty form is its canonical form.
    func testAScalarsPrettyFormIsItsCanonicalForm() {
        for value: JSONValue in [.null, .bool(false), .int(-3), .double(2.5), .string("a\"b\n/")] {
            XCTAssertEqual(value.prettyJSONString(), value.canonicalJSONString(), "\(value)")
        }
    }
}
