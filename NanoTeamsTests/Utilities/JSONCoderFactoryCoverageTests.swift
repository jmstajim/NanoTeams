import XCTest

@testable import NanoTeams

/// Coverage wave 1 — the two `JSONCoderFactory` surfaces nothing exercised.
///
/// `JSONCoderFactoryTests` already pins the round-trip behaviour of the encoders that have many
/// consumers. What it never reached was (a) the ISO-8601 decoder's THROW arm — the branch that
/// decides whether a corrupt date makes a work folder unreadable — and (b) `makeDisplayEncoder`,
/// whose single consumer lives under `Views/` and therefore never runs under test.
final class JSONCoderFactoryCoverageTests: XCTestCase {

    private struct Stamped: Codable, Equatable { let at: Date }

    // MARK: - The date decoder's throw arm

    /// The decoder accepts two shapes and throws on anything else. The two accepted shapes are a
    /// compat contract — fractional seconds (current) and second precision (files already on
    /// disk before that changed) — so the throw arm is what separates "an older file" from
    /// "a corrupt one", and misclassifying the first as the second makes a work folder
    /// unreadable rather than upgradable.
    ///
    /// RED: reorder the two `if let` probes so `plainFormatter` runs first → the fractional case
    /// still passes (it is a prefix match), but replacing either probe with `return nil` fails
    /// the corresponding assertion here.
    func testDateDecoder_acceptsBothStoredShapes() throws {
        let decoder = JSONCoderFactory.makeDateDecoder()

        let fractional = try decoder.decode(Stamped.self, from: Data(#"{"at":"2026-08-08T21:36:21.123Z"}"#.utf8))
        let plain = try decoder.decode(Stamped.self, from: Data(#"{"at":"2026-08-08T21:36:21Z"}"#.utf8))

        XCTAssertEqual(plain.at.timeIntervalSince1970,
                       fractional.at.timeIntervalSince1970, accuracy: 1.0,
                       "the two accepted shapes must denote the same instant — the second-precision "
                       + "form is what pre-fix files on disk carry")
    }

    /// RED: delete the `throw DecodingError.dataCorruptedError(...)` and return a fixed date →
    /// this test fails, and a corrupt timestamp would silently become a real one, which is worse
    /// than an unreadable file because it propagates into ordering.
    func testDateDecoder_rejectsAnUndecodableString() {
        let decoder = JSONCoderFactory.makeDateDecoder()

        for bad in [#"{"at":"not a date"}"#, #"{"at":""}"#, #"{"at":"2026-13-45T99:99:99Z"}"#] {
            XCTAssertThrowsError(try decoder.decode(Stamped.self, from: Data(bad.utf8)),
                                 "\(bad) must not decode") { error in
                guard case DecodingError.dataCorrupted(let context) = error else {
                    return XCTFail("expected .dataCorrupted, got \(error)")
                }
                XCTAssertTrue(context.debugDescription.contains("Invalid ISO 8601 date string"),
                              "the message must name the offending string so the file can be found")
            }
        }
    }

    /// Round-trip through the pair that actually persists work folders, so the throw arm above is
    /// pinned against a decoder that still accepts what we write.
    func testPersistenceEncoderOutputSurvivesTheDateDecoder() throws {
        let original = Stamped(at: Date(timeIntervalSince1970: 1_786_181_766.46))
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(original)
        let restored = try JSONCoderFactory.makeDateDecoder().decode(Stamped.self, from: data)
        XCTAssertEqual(restored.at.timeIntervalSince1970, original.at.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - makeDisplayEncoder

    /// Its only consumer is `ToolDefinitionEditorSheetView`, under `Views/`, so it had never run.
    ///
    /// The properties asserted are the ones its consumer depends on: human-readable output with a
    /// stable key order (a JSON blob the user edits must not reshuffle between renders) and no
    /// escaped slashes (`\/` in a displayed path reads as a typo).
    ///
    /// RED: drop `.sortedKeys` → the key-order assertion fails. Drop `.withoutEscapingSlashes` →
    /// the slash assertion fails.
    func testDisplayEncoder_isPrettyStablyOrderedAndDoesNotEscapeSlashes() throws {
        struct Shape: Encodable { let zebra: String; let apple: String; let path: String }
        let data = try JSONCoderFactory.makeDisplayEncoder()
            .encode(Shape(zebra: "z", apple: "a", path: "Sources/App/main.swift"))
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\n"), "display output is pretty-printed for a human to edit")
        XCTAssertTrue(text.contains("Sources/App/main.swift"),
                      "slashes must not be escaped — \\/ in a displayed path reads as a typo")
        guard let apple = text.range(of: "apple"), let zebra = text.range(of: "zebra") else {
            return XCTFail("both keys should be present: \(text)")
        }
        XCTAssertLessThan(apple.lowerBound, zebra.lowerBound,
                          "sortedKeys keeps an edited JSON blob from reshuffling between renders")
    }

    /// The display encoder must NOT carry a date strategy — it is documented as "No dates", and
    /// a silent ISO-8601 strategy here would make displayed output diverge from persisted output
    /// in a way only a date field would reveal.
    func testDisplayEncoderDiffersFromPersistenceOnlyInDateHandling() throws {
        struct NoDates: Encodable { let a: Int }
        let display = try JSONCoderFactory.makeDisplayEncoder().encode(NoDates(a: 1))
        let persistence = try JSONCoderFactory.makePersistenceEncoder().encode(NoDates(a: 1))
        XCTAssertEqual(String(decoding: display, as: UTF8.self),
                       String(decoding: persistence, as: UTF8.self),
                       "with no dates involved the two encoders must agree; if they ever diverge, "
                       + "the formatting options drifted apart")
    }
}
