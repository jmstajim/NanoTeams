import XCTest

@testable import NanoTeams

/// Pin the exact wire format of `Authorization: Bearer <token>`. LM Studio
/// (and every OAuth-style server) parses the header strictly; an extra space,
/// missing capital, or stray `\n` is a hard 401. These tests freeze the
/// format so a future refactor can't accidentally change it.
final class LMStudioBearerHeaderFormatTests: XCTestCase {

    private func header(for token: String) -> String? {
        var req = URLRequest(url: URL(string: "http://x:1")!)
        req.applyLMStudioBearer(literal: token)
        return req.value(forHTTPHeaderField: "Authorization")
    }

    func testFormat_isExactlyBearerSpaceToken() {
        XCTAssertEqual(header(for: "tok"), "Bearer tok")
    }

    func testFormat_doesNotDoubleBearer() {
        // Defense against a future "smart" path that prefixes "Bearer " twice.
        let result = header(for: "tok")
        XCTAssertEqual(result?.prefix(7), "Bearer ")
        XCTAssertFalse(result?.contains("Bearer Bearer") ?? false)
    }

    func testFormat_preservesSpecialCharacters() {
        // LM Studio tokens have no documented format constraints. Real-world
        // tokens have observed: alphanumerics, hyphens, dots, underscores,
        // colons, slashes, plus signs, equals (Base64), and tildes.
        let weirdButValid = "lm-tok_v2.abc-DEF/123+xyz=="
        XCTAssertEqual(header(for: weirdButValid), "Bearer \(weirdButValid)")
    }

    func testFormat_preservesUnicodeSafely() {
        // No documented Unicode tokens exist, but if a server emits one, we
        // must not crash or silently drop bytes. Round-trip the value verbatim.
        let unicode = "tök-€-α"
        XCTAssertEqual(header(for: unicode), "Bearer \(unicode)")
    }

    func testFormat_innerWhitespace_preserved() {
        // We trim leading/trailing whitespace (defensive against pasted-with-
        // trailing-newline tokens), but inner whitespace is part of the value
        // and must round-trip verbatim. Tokens with internal spaces are
        // pathological but not our problem to canonicalize.
        XCTAssertEqual(header(for: "  abc  "), "Bearer abc")
        XCTAssertEqual(header(for: "ab cd"), "Bearer ab cd")
    }

    func testFormat_emptyAndWhitespace_omitsHeader() {
        XCTAssertNil(header(for: ""))
        XCTAssertNil(header(for: "   "))
        XCTAssertNil(header(for: "\n"))
        XCTAssertNil(header(for: "\t \n"))
    }

    func testHeader_caseInsensitiveLookup() {
        // URLRequest header keys are case-insensitive per RFC 7230. Sanity
        // check that no future change starts setting "authorization" lowercase
        // and breaks "Authorization" lookups in test assertions.
        var req = URLRequest(url: URL(string: "http://x:1")!)
        req.applyLMStudioBearer(literal: "tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "AUTHORIZATION"), "Bearer tok")
    }
}
