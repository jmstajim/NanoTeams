import XCTest

@testable import NanoTeams

final class URLRequestLMStudioBearerTests: XCTestCase {

    private let url = URL(string: "http://localhost:1234/api/v1/chat")!

    // MARK: - Resolver-driven path

    func testApplyBearer_withResolverHit_setsHeader() {
        var req = URLRequest(url: url)
        let resolver = StubLLMTokenResolver(["http://localhost:1234": "secret-token"])
        req.applyLMStudioBearer(baseURL: "http://localhost:1234", resolver: resolver)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testApplyBearer_withResolverMiss_doesNotSetHeader() {
        var req = URLRequest(url: url)
        let resolver = StubLLMTokenResolver(["http://other:9999": "x"])
        req.applyLMStudioBearer(baseURL: "http://localhost:1234", resolver: resolver)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testApplyBearer_resolverNormalizesURLs() {
        var req = URLRequest(url: url)
        // Stub stored under one form, lookup uses another (case + trailing slash).
        let resolver = StubLLMTokenResolver(["http://LOCALHOST:1234/": "tok"])
        req.applyLMStudioBearer(baseURL: "http://localhost:1234", resolver: resolver)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // MARK: - Literal path (used by Test Connection / Fetch Models)

    func testApplyBearer_literal_setsHeader() {
        var req = URLRequest(url: url)
        req.applyLMStudioBearer(literal: "abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func testApplyBearer_literalNil_doesNotSetHeader() {
        var req = URLRequest(url: url)
        req.applyLMStudioBearer(literal: nil)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testApplyBearer_literalEmpty_doesNotSetHeader() {
        var req = URLRequest(url: url)
        req.applyLMStudioBearer(literal: "")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testApplyBearer_literalWhitespaceOnly_doesNotSetHeader() {
        var req = URLRequest(url: url)
        req.applyLMStudioBearer(literal: "   \n\t  ")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testApplyBearer_literalTrimsWhitespace() {
        var req = URLRequest(url: url)
        req.applyLMStudioBearer(literal: "  abc  ")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }
}
