import XCTest

@testable import NanoTeams

final class LLMConnectionCheckerTests: XCTestCase {

    // MARK: - MockNetworkSession

    private final class MockNetworkSession: NetworkSession, @unchecked Sendable {
        var capturedURL: URL?
        var statusCode: Int = 200

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedURL = request.url
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("Not used in these tests")
        }
    }

    // MARK: - Tests

    func testCheck_usesCorrectEndpointPath() async {
        let mock = MockNetworkSession()
        mock.statusCode = 200

        _ = await LLMConnectionChecker.check(
            baseURL: "http://localhost:1234",
            session: mock
        )

        XCTAssertNotNil(mock.capturedURL)
        XCTAssertEqual(mock.capturedURL?.path, "/api/v1/models",
                       "Should use /api/v1/models endpoint path")
    }

    func testCheck_returnsTrueOn200() async {
        let mock = MockNetworkSession()
        mock.statusCode = 200

        let result = await LLMConnectionChecker.check(
            baseURL: "http://localhost:1234",
            session: mock
        )

        XCTAssertTrue(result)
    }

    func testCheck_returnsFalseOn500() async {
        let mock = MockNetworkSession()
        mock.statusCode = 500

        let result = await LLMConnectionChecker.check(
            baseURL: "http://localhost:1234",
            session: mock
        )

        XCTAssertFalse(result)
    }
}
