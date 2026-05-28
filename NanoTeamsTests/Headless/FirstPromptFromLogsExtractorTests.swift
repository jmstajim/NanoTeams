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

    private func writeLog(_ records: [NetworkLogRecord]) throws -> URL {
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

    func testExtract_malformedLog_throwsMalformedLog() throws {
        let url = tempDir.appendingPathComponent("network_log.json")
        try Data("not-json-{".utf8).write(to: url)
        XCTAssertThrowsError(try FirstPromptFromLogsExtractor.extract(from: url, roleSubstring: "engineer")) { error in
            guard case FirstPromptFromLogsExtractor.ExtractError.malformedLog = error else {
                return XCTFail("expected .malformedLog, got \(error)")
            }
        }
    }
}
