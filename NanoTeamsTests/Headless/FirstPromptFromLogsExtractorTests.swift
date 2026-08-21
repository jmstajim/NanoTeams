import XCTest
@testable import NanoTeams

/// Regression pin for the `--from-logs` extraction pipeline. Mirrors the jq
/// filter in `train_first_prompt.sh:extract_mode` so a future endpoint /
/// field-shape change breaks here loudly instead of silently producing
/// stale audit output from the CLI.
final class FirstPromptFromLogsExtractorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstPromptFromLogsExtractorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    /// Current format: JSONL, one record per line — what NetworkLogger writes
    /// since 2026-08-21.
    private func writeLog(_ records: [NetworkLogRecord]) throws -> URL {
        let url = tempDir.appendingPathComponent("network_log.jsonl")
        let encoder = JSONCoderFactory.makeJSONLEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    /// Pre-2026-08-21 format: a JSON array. Log artifacts die with their run,
    /// so nothing converts old files — the extractor must keep reading them.
    private func writeLegacyArrayLog(_ records: [NetworkLogRecord]) throws -> URL {
        let url = tempDir.appendingPathComponent("network_log.json")
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(records)
        try data.write(to: url)
        return url
    }

    private func makeRequest(
        createdAt: Date,
        roleName: String?,
        url: String = "http://127.0.0.1:1234/api/v1/chat",
        body: String? = "{\"messages\":[]}",
        method: String = "POST"
    ) -> NetworkLogRecord {
        NetworkLogRecord(
            id: UUID(),
            createdAt: createdAt,
            direction: .request,
            httpMethod: method,
            url: url,
            statusCode: nil,
            body: body,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil,
            inputTokens: nil,
            outputTokens: nil,
            roleName: roleName
        )
    }

    // MARK: - Happy paths

    func testExtract_singleMatch_returnsCount1() throws {
        let log = try writeLog([
            makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Software Engineer")
        ])
        let match = try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "engineer")
        XCTAssertEqual(match.matchedCount, 1)
        XCTAssertEqual(match.wireBody.roleName, "Software Engineer")
    }

    func testExtract_multipleMatches_returnsEarliestByCreatedAt() throws {
        // Simulates restartRole / requestRevision: two stateless first-requests for
        // the same role within a run. CLI must print the earliest one.
        let earlier = makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Software Engineer", body: "{\"first\":true}")
        let later   = makeRequest(createdAt: Date(timeIntervalSince1970: 200), roleName: "Software Engineer", body: "{\"second\":true}")
        let log = try writeLog([later, earlier])  // out-of-order in the file
        let match = try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "engineer")
        XCTAssertEqual(match.matchedCount, 2)
        XCTAssertEqual(match.wireBody.body, "{\"first\":true}",
                       "must return the record with the EARLIER createdAt")
    }

    func testExtract_caseInsensitiveSubstringMatch() throws {
        let log = try writeLog([
            makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Coding Agent")
        ])
        let match = try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "CODING")
        XCTAssertEqual(match.wireBody.roleName, "Coding Agent")
    }

    // MARK: - Filter predicates

    func testExtract_filtersOutResponses() throws {
        let response = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            direction: .response, httpMethod: "POST",
            url: "http://127.0.0.1:1234/api/v1/chat", statusCode: 200,
            body: "{\"id\":\"resp\"}", durationMs: 12,
            errorMessage: nil, correlationID: UUID(),
            stepID: nil, inputTokens: nil, outputTokens: nil,
            roleName: "Software Engineer"
        )
        let log = try writeLog([response])
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "engineer"))
    }

    func testExtract_filtersOutWrongEndpoint() throws {
        let log = try writeLog([
            makeRequest(createdAt: Date(timeIntervalSince1970: 100),
                        roleName: "Software Engineer",
                        url: "http://127.0.0.1:1234/v1/embeddings")
        ])
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "engineer")) { error in
            guard case FirstPromptFromLogsExtractor.ExtractError.noMatch = error else {
                return XCTFail("expected .noMatch, got \(error)")
            }
        }
    }

    func testExtract_filtersOutNilRoleName() throws {
        // Meetings, vision, supervisor auto-answer, workfolder-context all log
        // with roleName: nil. They're intentionally not surfaced by --from-logs.
        let log = try writeLog([
            makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: nil)
        ])
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "any"))
    }

    // MARK: - Error paths

    func testExtract_missingBody_throwsMissingBody() throws {
        let log = try writeLog([
            makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Software Engineer", body: nil)
        ])
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: log, roleSubstring: "engineer")) { error in
            guard case FirstPromptFromLogsExtractor.ExtractError.missingBody = error else {
                return XCTFail("expected .missingBody, got \(error)")
            }
        }
    }

    func testExtract_brokenArray_throwsMalformedLog() throws {
        // A `[`-led file claims the legacy ARRAY shape; a broken one is a hard
        // error — the whole-array decoder has no per-row recovery.
        let url = tempDir.appendingPathComponent("network_log.json")
        try Data("[{\"broken\":".utf8).write(to: url)
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: url, roleSubstring: "engineer")) { error in
            guard case FirstPromptFromLogsExtractor.ExtractError.malformedLog = error else {
                return XCTFail("expected .malformedLog, got \(error)")
            }
        }
    }

    func testExtract_undecodableNonArrayBlob_readsAsZeroRecords() throws {
        // Not `[`-led → treated as JSONL, where a bad line costs one ROW: a blob
        // of zero decodable lines is an empty log (noMatch), not a hard error.
        let url = tempDir.appendingPathComponent("network_log.jsonl")
        try Data("not-json-{".utf8).write(to: url)
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: url, roleSubstring: "engineer")) { error in
            guard case FirstPromptFromLogsExtractor.ExtractError.noMatch = error else {
                return XCTFail("expected .noMatch, got \(error)")
            }
        }
    }

    /// The JSONL failure contract, end to end: a torn line (process died
    /// mid-write) loses that row and NOTHING else. The array shape lost the
    /// whole file to one bad byte — the difference is the point of the format.
    func testExtract_tornTrailingLine_stillYieldsTheGoodRecords() throws {
        let good = makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Software Engineer")
        let url = try writeLog([good])
        var data = try Data(contentsOf: url)
        data.append(Data("{\"id\":\"torn-mid-wri".utf8))
        try data.write(to: url)

        let match = try FirstPromptFromLogsExtractor.extract(from: url, roleSubstring: "engineer")
        XCTAssertEqual(match.matchedCount, 1)
    }

    /// Legacy fallback: a pre-2026-08-21 array log must still extract — the
    /// same predicate, the other decoder branch.
    func testExtract_legacyArrayLog_stillExtracts() throws {
        let early = makeRequest(createdAt: Date(timeIntervalSince1970: 100), roleName: "Software Engineer")
        let late = makeRequest(createdAt: Date(timeIntervalSince1970: 200), roleName: "Software Engineer")
        let url = try writeLegacyArrayLog([late, early])

        let match = try FirstPromptFromLogsExtractor.extract(from: url, roleSubstring: "engineer")
        XCTAssertEqual(match.matchedCount, 2)
        XCTAssertEqual(match.wireBody.createdAt, early.createdAt, "earliest by createdAt wins")
    }
}
