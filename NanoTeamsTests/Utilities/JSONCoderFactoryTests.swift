import XCTest
@testable import NanoTeams

final class JSONCoderFactoryTests: XCTestCase {

    // MARK: - Persistence Encoder

    func testPersistenceEncoderHasExpectedFormatting() {
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        XCTAssertTrue(encoder.outputFormatting.contains(.prettyPrinted))
        XCTAssertTrue(encoder.outputFormatting.contains(.sortedKeys))
        XCTAssertTrue(encoder.outputFormatting.contains(.withoutEscapingSlashes))
    }

    func testPersistenceEncoderEncodesDateAsISO8601() throws {
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let wrapper = DateWrapper(date: Date(timeIntervalSince1970: 0))
        let data = try encoder.encode(wrapper)
        let json = String(data: data, encoding: .utf8)!
        // Fractional-seconds precision preserves MonotonicClock's ms ordering through roundtrip.
        XCTAssertTrue(json.contains("1970-01-01T00:00:00.000Z"), "Expected ISO 8601 date with fractional seconds, got: \(json)")
    }

    // MARK: - Export Encoder

    func testExportEncoderHasExpectedFormatting() {
        let encoder = JSONCoderFactory.makeExportEncoder()
        XCTAssertTrue(encoder.outputFormatting.contains(.prettyPrinted))
        XCTAssertTrue(encoder.outputFormatting.contains(.sortedKeys))
        XCTAssertFalse(encoder.outputFormatting.contains(.withoutEscapingSlashes))
    }

    func testExportEncoderEncodesDateAsISO8601() throws {
        let encoder = JSONCoderFactory.makeExportEncoder()
        let wrapper = DateWrapper(date: Date(timeIntervalSince1970: 0))
        let data = try encoder.encode(wrapper)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("1970-01-01T00:00:00.000Z"), "Expected ISO 8601 date with fractional seconds, got: \(json)")
    }

    // MARK: - JSONL Encoder

    func testJSONLEncoderIsCompact() {
        let encoder = JSONCoderFactory.makeJSONLEncoder()
        XCTAssertFalse(encoder.outputFormatting.contains(.prettyPrinted))
        XCTAssertTrue(encoder.outputFormatting.contains(.withoutEscapingSlashes))
    }

    func testJSONLEncoderEncodesDateAsISO8601() throws {
        let encoder = JSONCoderFactory.makeJSONLEncoder()
        let wrapper = DateWrapper(date: Date(timeIntervalSince1970: 0))
        let data = try encoder.encode(wrapper)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("1970-01-01T00:00:00.000Z"), "Expected ISO 8601 date with fractional seconds, got: \(json)")
    }

    // MARK: - Date Decoder

    func testDateDecoderDecodesISO8601() throws {
        let json = #"{"date":"1970-01-01T00:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONCoderFactory.makeDateDecoder()
        let wrapper = try decoder.decode(DateWrapper.self, from: data)
        XCTAssertEqual(wrapper.date.timeIntervalSince1970, 0, accuracy: 1)
    }

    /// Pins the backward-compatibility fallback: pre-fractional-seconds files
    /// on disk (written before JSONCoderFactory switched to fractional output)
    /// must still decode. If someone removes `plainFormatter` from the custom
    /// decoding strategy, this test fails and task.json loading breaks for
    /// existing installations.
    func testDateDecoderDecodesLegacySecondPrecisionFormat() throws {
        let json = #"{"date":"2020-06-15T12:34:56Z"}"#  // no fractional seconds
        let data = json.data(using: .utf8)!
        let decoder = JSONCoderFactory.makeDateDecoder()
        let wrapper = try decoder.decode(DateWrapper.self, from: data)
        // Expected: 2020-06-15 12:34:56 UTC = 1592224496
        XCTAssertEqual(wrapper.date.timeIntervalSince1970, 1_592_224_496, accuracy: 1)
    }

    func testDateDecoderDecodesFractionalSecondsFormat() throws {
        let json = #"{"date":"2020-06-15T12:34:56.789Z"}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONCoderFactory.makeDateDecoder()
        let wrapper = try decoder.decode(DateWrapper.self, from: data)
        XCTAssertEqual(wrapper.date.timeIntervalSince1970, 1_592_224_496.789, accuracy: 0.01)
    }

    // MARK: - Roundtrip

    func testPersistenceRoundtrip() throws {
        let original = DateWrapper(date: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(original)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(DateWrapper.self, from: data)
        XCTAssertEqual(decoded.date.timeIntervalSince1970, original.date.timeIntervalSince1970, accuracy: 1)
    }

    func testExportRoundtrip() throws {
        let original = DateWrapper(date: Date(timeIntervalSince1970: 2_000_000))
        let data = try JSONCoderFactory.makeExportEncoder().encode(original)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(DateWrapper.self, from: data)
        XCTAssertEqual(decoded.date.timeIntervalSince1970, original.date.timeIntervalSince1970, accuracy: 1)
    }
}

// MARK: - Test Helper

private struct DateWrapper: Codable {
    let date: Date
}
