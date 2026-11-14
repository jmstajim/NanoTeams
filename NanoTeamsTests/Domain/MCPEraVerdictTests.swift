import XCTest

@testable import NanoTeams

/// The probe's one decision, row by row — every answer `server/discover` can give, against the
/// revision it asked for. Revisions and codes are the spec's literals (2026-07-28 basic/index
/// "Error Codes", basic/versioning, server/discover), so a constant moved off its number cannot
/// move these rows with it. The client's own reading of the same answers, through a scripted
/// server, is `MCPClientEraProbeTests`.
final class MCPEraVerdictTests: XCTestCase {

    private let asked = "2026-07-28"

    private func verdict(_ answer: MCPEraVerdict.ProbeAnswer, retried: Bool = false) -> MCPEraVerdict {
        MCPEraVerdict.of(answer, asked: asked, retried: retried)
    }

    private func discoverResult(_ supported: [String]?, protocolVersion: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["resultType": .string("complete"), "capabilities": .object([:])]
        if let supported { object["supportedVersions"] = .array(supported.map { .string($0) }) }
        if let protocolVersion { object["protocolVersion"] = .string(protocolVersion) }
        return .object(object)
    }

    private func versionRefusal(_ supported: [String]?) -> MCPEraVerdict.ProbeAnswer {
        .refused(code: -32022, message: "Unsupported protocol version",
                 data: supported.map { .object(["supported": .array($0.map { .string($0) }), "requested": .string("2026-07-28")]) })
    }

    // MARK: - A result

    /// Adopted by the revisions it names, the asked one first; a handshake revision in common is
    /// a dual-era server's advertisement; nothing in common — an empty list too — is refused.
    func testADiscoverResultIsAdoptedByItsSupportedVersions() {
        let rows: [([String], MCPEraVerdict)] = [
            (["2026-07-28"], .modern(version: "2026-07-28", result: discoverResult(["2026-07-28"]))),
            (["2025-11-25", "2026-07-28"], .modern(version: "2026-07-28", result: discoverResult(["2025-11-25", "2026-07-28"]))),
            (["2025-11-25"], .legacy),
            (["2025-03-26", "2099-01-01"], .legacy),
            (["2099-01-01"], .fail(.unsupported(serverSupports: ["2099-01-01"]))),
            (["2024-11-05"], .fail(.unsupported(serverSupports: ["2024-11-05"]))),
            ([], .fail(.unsupported(serverSupports: []))),
        ]
        for (supported, expected) in rows {
            XCTAssertEqual(verdict(.result(discoverResult(supported))), expected, "\(supported)")
        }
    }

    /// The list is the spec's field and outranks an `initialize`-era `protocolVersion` beside it.
    func testTheListOutranksAProtocolVersionBesideIt() {
        let result = discoverResult(["2025-11-25"], protocolVersion: "2026-07-28")
        XCTAssertEqual(verdict(.result(result)), .legacy)
    }

    /// A result naming no list is the asked revision — the server answered a request made at it —
    /// unless it names another, which must be one this client speaks: a server's capped `…` is
    /// not a header byte, and a handshake revision is not a modern one. A `supportedVersions`
    /// that is not a list names no list.
    func testAResultNamingNoListIsTheAskedRevisionUnlessItNamesAnother() {
        let bare = discoverResult(nil)
        XCTAssertEqual(verdict(.result(bare)), .modern(version: "2026-07-28", result: bare))
        let named = discoverResult(nil, protocolVersion: "2026-07-28")
        XCTAssertEqual(verdict(.result(named)), .modern(version: "2026-07-28", result: named))
        XCTAssertEqual(verdict(.result(discoverResult(nil, protocolVersion: "2099-01-01"))),
                       .fail(.unsupported(serverSupports: ["2099-01-01"])))
        XCTAssertEqual(verdict(.result(discoverResult(nil, protocolVersion: "2025-11-25"))),
                       .fail(.unsupported(serverSupports: ["2025-11-25"])))
        let notAList: JSONValue = .object(["supportedVersions": .string("2025-11-25")])
        XCTAssertEqual(verdict(.result(notAList)), .modern(version: "2026-07-28", result: notAList))
        XCTAssertEqual(verdict(.result(.object([:]))), .modern(version: "2026-07-28", result: .object([:])))
    }

    /// The list is server text on its way to the status row: each entry cleaned to one visible
    /// line and capped, an entry that is not a string or cleans to nothing dropped — and the
    /// cleaned entries are what is compared.
    func testTheListIsCleanedBeforeItIsRead() {
        let result: JSONValue = .object(["supportedVersions": .array([
            .int(7), .string("\u{200B}"), .string("2025-11-25\u{202E}\n"),
        ])])
        XCTAssertEqual(MCPWire.supportedVersions(fromDiscoverResult: result), ["2025-11-25"])
        XCTAssertEqual(verdict(.result(result)), .legacy)
        XCTAssertNil(MCPWire.supportedVersions(fromDiscoverResult: .object([:])))
        XCTAssertNil(MCPWire.supportedVersions(fromDiscoverResult: .string("2026-07-28")))
    }

    /// A second modern revision this client spoke would be chosen from the list too — the rule
    /// is "a modern revision in common", not "the one asked for".
    func testAnotherModernRevisionInCommonIsTheOneAdopted() {
        let result = discoverResult(["2027-01-01"])
        XCTAssertEqual(
            MCPEraVerdict.of(.result(result), asked: asked, retried: false,
                             modernRevisions: ["2026-07-28", "2027-01-01"]),
            .modern(version: "2027-01-01", result: result))
    }

    /// Membership is checked against the full cleaned list, while an unsupported refusal caps
    /// the displayed list at `MCPWire.maxListedVersions` (16). A server listing 17 revisions
    /// where the matching one is 17th is adopted rather than refused as incompatible.
    func testASeventeenthSupportedRevisionIsAdoptedWhileAnUnsupportedListIsCappedAtSixteen() {
        let sixteenUnknown = (1...16).map { String(format: "2099-01-%02d", $0) }
        let seventeenWithModernLast = sixteenUnknown + ["2026-07-28"]
        let modernResult = discoverResult(seventeenWithModernLast)
        XCTAssertEqual(verdict(.result(modernResult)), .modern(version: "2026-07-28", result: modernResult))
        XCTAssertEqual(verdict(versionRefusal(seventeenWithModernLast)), .retry(version: "2026-07-28"))

        let seventeenWithLegacyLast = sixteenUnknown + ["2025-11-25"]
        XCTAssertEqual(verdict(.result(discoverResult(seventeenWithLegacyLast))), .legacy)
        XCTAssertEqual(verdict(versionRefusal(seventeenWithLegacyLast)), .legacy)

        let seventeenUnknown = sixteenUnknown + ["2099-01-17"]
        XCTAssertEqual(verdict(.result(discoverResult(seventeenUnknown))),
                       .fail(.unsupported(serverSupports: sixteenUnknown)))
        XCTAssertEqual(verdict(versionRefusal(seventeenUnknown)),
                       .fail(.unsupported(serverSupports: sixteenUnknown)))
    }

    // MARK: - A version refusal

    /// `-32022` naming the asked revision is a server contradicting itself: asked once more, and
    /// a second refusal fails — unless a handshake revision is also in common, which the second
    /// refusal leaves as the mutual one.
    func testAVersionRefusalNamingTheAskedRevisionRetriesOnce() {
        XCTAssertEqual(verdict(versionRefusal(["2026-07-28"])), .retry(version: "2026-07-28"))
        XCTAssertEqual(verdict(versionRefusal(["2026-07-28"]), retried: true),
                       .fail(.unsupported(serverSupports: ["2026-07-28"])))
        XCTAssertEqual(verdict(versionRefusal(["2026-07-28", "2025-11-25"]), retried: true), .legacy)
        XCTAssertEqual(
            MCPEraVerdict.of(versionRefusal(["2027-01-01"]), asked: asked, retried: false,
                             modernRevisions: ["2026-07-28", "2027-01-01"]),
            .retry(version: "2027-01-01"))
    }

    /// No modern revision in common: a handshake one takes the handshake, nothing takes nothing.
    func testAVersionRefusalWithNoModernRevisionInCommonTakesTheHandshakeOrFails() {
        XCTAssertEqual(verdict(versionRefusal(["2025-11-25"])), .legacy)
        XCTAssertEqual(verdict(versionRefusal(["2099-01-01", "2025-06-18"])), .legacy)
        XCTAssertEqual(verdict(versionRefusal(["2099-01-01"])), .fail(.unsupported(serverSupports: ["2099-01-01"])))
        XCTAssertEqual(verdict(versionRefusal(["2024-11-05"])), .fail(.unsupported(serverSupports: ["2024-11-05"])))
        XCTAssertEqual(verdict(versionRefusal(nil)), .fail(.unsupported(serverSupports: [])))
    }

    // MARK: - Other refusals

    /// The revision's other two codes are a modern server's refusal of a probe nothing here can
    /// correct: they fail, in its words, retried or not — never a fallback.
    func testHeaderMismatchAndAMissingCapabilityFailInTheServersWords() {
        for code in [-32020, -32021] {
            for retried in [false, true] {
                XCTAssertEqual(
                    verdict(.refused(code: code, message: "its words", data: nil), retried: retried),
                    .fail(.refused(code: code, message: "its words")), "\(code), retried \(retried)")
            }
        }
    }

    /// Everything else identifies a legacy server: a method it has never heard of, a malformed
    /// probe, an internal error, an implementation's own code, a code 2025-11-25 alone defined,
    /// an undefined one inside the reserved range — and no answer at all.
    func testEveryOtherAnswerTakesTheHandshake() {
        for code in [-32601, -32602, -32603, -32600, -32700, -32000, -32019, -32042, -32050] {
            XCTAssertEqual(verdict(.refused(code: code, message: "no", data: nil)), .legacy, "\(code)")
        }
        XCTAssertEqual(verdict(.noAnswer), .legacy)
        XCTAssertEqual(verdict(.noAnswer, retried: true), .legacy)
    }

    /// A `server/discover` result whose `resultType` is `input_required` or unrecognized
    /// identifies a modern server and fails as incompatible rather than falling back to
    /// `initialize`.
    func testAnUnfinishedDiscoverResultFailsRatherThanFallingBackToLegacy() {
        let inputReq: JSONValue = .object([
            "resultType": .string("input_required"),
            "supportedVersions": .array([.string("2026-07-28")]),
        ])
        XCTAssertEqual(verdict(.result(inputReq)), .fail(.inputRequired))

        let streaming: JSONValue = .object([
            "resultType": .string("streaming"),
            "supportedVersions": .array([.string("2026-07-28")]),
        ])
        XCTAssertEqual(verdict(.result(streaming)), .fail(.unknownResultType("streaming")))
    }
}
