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
        XCTAssertTrue(json.contains("1970-01-01T00:00:00Z"), "Expected ISO 8601 date, got: \(json)")
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
        XCTAssertTrue(json.contains("1970-01-01T00:00:00Z"), "Expected ISO 8601 date, got: \(json)")
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
        XCTAssertTrue(json.contains("1970-01-01T00:00:00Z"), "Expected ISO 8601 date, got: \(json)")
    }

    // MARK: - Date Decoder

    func testDateDecoderDecodesISO8601() throws {
        let json = #"{"date":"1970-01-01T00:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONCoderFactory.makeDateDecoder()
        let wrapper = try decoder.decode(DateWrapper.self, from: data)
        XCTAssertEqual(wrapper.date.timeIntervalSince1970, 0, accuracy: 1)
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
