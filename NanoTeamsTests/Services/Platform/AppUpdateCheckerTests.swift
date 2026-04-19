import XCTest
@testable import NanoTeams

/// End-to-end decode test for `AppUpdateChecker` — the GitHub payload parsing
/// is the failure-prone part, not the HTTP code which is a thin URLSession
/// wrapper. Exercises happy path + HTTP error + malformed JSON.
@MainActor
final class AppUpdateCheckerTests: XCTestCase {

    // MARK: - MockNetworkSession

    private final class MockNetworkSession: NetworkSession, @unchecked Sendable {
        var responseBody: Data = Data()
        var statusCode: Int = 200
        var capturedRequest: URLRequest?

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private var mock: MockNetworkSession!
    private var sut: AppUpdateChecker!

    override func setUp() {
        super.setUp()
        mock = MockNetworkSession()
        sut = AppUpdateChecker(session: mock)
    }

    override func tearDown() {
        sut = nil
        mock = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testFetchLatestRelease_decodesPayload() async throws {
        mock.responseBody = #"""
        {
            "tag_name": "v1.2.3",
            "html_url": "https://github.com/jmstajim/NanoTeams/releases/tag/v1.2.3",
            "body": "Release notes here."
        }
        """#.data(using: .utf8)!

        let release = try await sut.fetchLatestRelease()

        XCTAssertEqual(release.tag, "v1.2.3")
        XCTAssertEqual(release.htmlURL.absoluteString,
                       "https://github.com/jmstajim/NanoTeams/releases/tag/v1.2.3")
        XCTAssertEqual(release.body, "Release notes here.")
    }

    func testFetchLatestRelease_missingBodyDecodesToEmptyString() async throws {
        mock.responseBody = #"""
        {
            "tag_name": "1.0.0",
            "html_url": "https://example.com/r"
        }
        """#.data(using: .utf8)!

        let release = try await sut.fetchLatestRelease()
        XCTAssertEqual(release.body, "")
    }

    func testFetchLatestRelease_sendsUserAgentAndAccept() async throws {
        // GitHub rejects requests without User-Agent. Accept header opts into
        // the stable v3 JSON format.
        mock.responseBody = #"""
        {"tag_name":"v1","html_url":"https://example.com/r"}
        """#.data(using: .utf8)!

        _ = try await sut.fetchLatestRelease()

        let req = try XCTUnwrap(mock.capturedRequest)
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("NanoTeams/") ?? false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    // MARK: - Error paths

    func testFetchLatestRelease_httpErrorThrows() async {
        mock.statusCode = 404
        mock.responseBody = Data()

        do {
            _ = try await sut.fetchLatestRelease()
            XCTFail("expected CheckerError.badStatus")
        } catch let AppUpdateChecker.CheckerError.badStatus(code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testFetchLatestRelease_rateLimitedThrows() async {
        mock.statusCode = 403
        do {
            _ = try await sut.fetchLatestRelease()
            XCTFail("expected CheckerError.badStatus(403)")
        } catch let AppUpdateChecker.CheckerError.badStatus(code) {
            XCTAssertEqual(code, 403)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testFetchLatestRelease_malformedJSONThrows() async {
        mock.responseBody = "not json".data(using: .utf8)!

        do {
            _ = try await sut.fetchLatestRelease()
            XCTFail("expected decode error")
        } catch AppUpdateChecker.CheckerError.decodeFailed(let underlying) {
            // Wrapped so the user-facing description can be specific (and so the
            // raw DecodingError doesn't leak into the UI). Underlying must still
            // be a DecodingError — the wrap is a labeling step, not a swap.
            XCTAssertTrue(underlying is DecodingError, "decodeFailed should wrap a DecodingError, got: \(underlying)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
