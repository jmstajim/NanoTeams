import XCTest

@testable import NanoTeams

/// Regression guard for the LM Studio bearer-token leak vector.
///
/// `NetworkLogRecord` intentionally has NO `headers` field, and `NetworkLogger`
/// intentionally does NOT capture `URLRequest.allHTTPHeaderFields`. If a future
/// contributor adds either, the LM Studio API token would silently start landing
/// in `network_log.json` on every request. This test fails fast in that case
/// and forces the change to also wire explicit `Authorization` redaction.
///
/// See CLAUDE.md "LM Studio Authentication" for the full leak-vector reasoning.
final class NetworkLoggerHeadersGuardTests: XCTestCase {

    func testNetworkLogRecord_serializedJSON_hasNoHeadersField() throws {
        let record = NetworkLogger.createRequestRecord(
            url: URL(string: "http://localhost:1234/api/v1/chat")!,
            method: "POST",
            body: Data("{}".utf8),
            stepID: nil,
            roleName: nil
        )

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(record)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let banned: Set<String> = ["headers", "httpHeaders", "allHTTPHeaderFields",
                                    "authorization", "Authorization"]
        let leaks = banned.intersection(Set(json.keys))
        XCTAssertTrue(
            leaks.isEmpty,
            "NetworkLogRecord must not serialize header data — found banned keys: \(leaks). "
                + "Adding header capture without explicit Authorization redaction would leak "
                + "LM Studio bearer tokens into .nanoteams/internal/runs/*/network_log.json. "
                + "If this is intentional, also add a redaction step + update the auth tests."
        )
    }

    func testNetworkLogRecord_responseSerialization_hasNoHeadersField() throws {
        let request = NetworkLogger.createRequestRecord(
            url: URL(string: "http://localhost:1234/api/v1/chat")!,
            method: "POST",
            body: nil,
            stepID: nil,
            roleName: nil
        )
        let response = NetworkLogger.createResponseRecord(
            for: request,
            statusCode: 200,
            durationMs: 12.0,
            body: "{}",
            error: nil
        )

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let data = try encoder.encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let banned: Set<String> = ["headers", "httpHeaders", "responseHeaders",
                                    "authorization", "Authorization"]
        let leaks = banned.intersection(Set(json.keys))
        XCTAssertTrue(leaks.isEmpty, "Response record must not serialize headers; found: \(leaks)")
    }
}
