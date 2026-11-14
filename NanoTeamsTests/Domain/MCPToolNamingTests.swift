import XCTest

@testable import NanoTeams

/// The namespace that keeps two servers' `search` tools apart, and the parse that reads a
/// name back. Both halves matter: a name the renderer prints has to satisfy the prompt
/// format pin, and a name the resolver reads has to say unambiguously which server it
/// belongs to.
final class MCPToolNamingTests: XCTestCase {

    // MARK: - Slugs

    func testAcceptsWellFormedSlugs() {
        for slug in ["folio", "trade_room", "a", "server1", "0abc", String(repeating: "a", count: 32)] {
            XCTAssertTrue(MCPToolNaming.isValidSlug(slug), slug)
            XCTAssertNil(MCPToolNaming.rejection(forSlug: slug), slug)
        }
    }

    func testRefusesSlugsAndNamesTheRepair() {
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: ""), .empty)
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: String(repeating: "a", count: 33)), .tooLong(max: 32))
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "_folio"), .badFirstCharacter)
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "Folio"), .badFirstCharacter)
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "fol-io"), .badCharacters)
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "сервер"), .badFirstCharacter)
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "fol io"), .badCharacters)
        for rejection in [MCPToolNaming.SlugRejection.empty, .tooLong(max: 32), .badFirstCharacter,
                          .badCharacters, .doubleUnderscore] {
            XCTAssertFalse(rejection.message.isEmpty)
        }
    }

    /// A slug spelling the separator would make `mcp__a__b__c` ambiguous between server `a`
    /// with tool `b__c` and server `a__b` with tool `c`.
    func testRefusesDoubleUnderscoreInSlug() {
        XCTAssertEqual(MCPToolNaming.rejection(forSlug: "trade__room"), .doubleUnderscore)
        XCTAssertFalse(MCPToolNaming.isValidSlug("trade__room"))
    }

    func testSuggestedSlugFoldsADisplayName() {
        XCTAssertEqual(MCPToolNaming.suggestedSlug(from: "Folio Desktop"), "folio_desktop")
        XCTAssertEqual(MCPToolNaming.suggestedSlug(from: "Trade-Room"), "trade_room")
        XCTAssertEqual(MCPToolNaming.suggestedSlug(from: "  ***  "), "")
        XCTAssertTrue(MCPToolNaming.isValidSlug(MCPToolNaming.suggestedSlug(from: "My Server!!")))
        XCTAssertLessThanOrEqual(MCPToolNaming.suggestedSlug(from: String(repeating: "x", count: 80)).count, 32)
    }

    // MARK: - Tool names

    func testBuildsTheModelFacingName() {
        XCTAssertEqual(MCPToolNaming.modelFacingName(slug: "folio", toolName: "get_design_context"),
                       "mcp__folio__get_design_context")
    }

    func testFoldsForeignCharactersInToolNames() {
        XCTAssertEqual(MCPToolNaming.modelFacingName(slug: "s", toolName: "Get-Design Context"),
                       "mcp__s__get_design_context")
        XCTAssertEqual(MCPToolNaming.modelFacingName(slug: "s", toolName: "tools.list"), "mcp__s__tools_list")
        XCTAssertEqual(MCPToolNaming.modelFacingName(slug: "s", toolName: "__weird__"), "mcp__s__weird")
    }

    func testRefusesANameThatFoldsToNothing() {
        XCTAssertNil(MCPToolNaming.modelFacingName(slug: "s", toolName: "***"))
        XCTAssertNil(MCPToolNaming.modelFacingName(slug: "s", toolName: ""))
        XCTAssertNil(MCPToolNaming.modelFacingName(slug: "BAD", toolName: "ok"))
    }

    /// Every name the renderer prints must satisfy the prompt-format pin's alphabet.
    func testRenderedNamesUseOnlyTheAllowedAlphabet() throws {
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: "trade_room", toolName: "GetOrders/v2"))
        XCTAssertEqual(name, "mcp__trade_room__getorders_v2")
        XCTAssertTrue(name.allSatisfy { $0.isNumber || ($0.isLetter && $0.isLowercase && $0.isASCII) || $0 == "_" })
    }

    // MARK: - Reading a name back

    func testRecognisesTheFamily() {
        XCTAssertTrue(MCPToolNaming.isMCPName("mcp__folio__get_metadata"))
        XCTAssertTrue(MCPToolNaming.isMCPName("mcp__folio"))
        XCTAssertFalse(MCPToolNaming.isMCPName("mcp__"))
        XCTAssertFalse(MCPToolNaming.isMCPName("read_file"))
        XCTAssertFalse(MCPToolNaming.isMCPName("mcp_folio_x"))
    }

    func testReadsSlugAndToolBack() {
        XCTAssertEqual(MCPToolNaming.slug(ofName: "mcp__folio__get_metadata"), "folio")
        XCTAssertEqual(MCPToolNaming.foldedToolName(ofName: "mcp__folio__get_metadata"), "get_metadata")
        // A tool name that itself contains the separator still belongs to the first slug.
        XCTAssertEqual(MCPToolNaming.slug(ofName: "mcp__folio__a__b"), "folio")
        XCTAssertEqual(MCPToolNaming.foldedToolName(ofName: "mcp__folio__a__b"), "a__b")
    }

    func testWholeServerGrant() {
        XCTAssertEqual(MCPToolNaming.serverGrant(slug: "folio"), "mcp__folio")
        XCTAssertTrue(MCPToolNaming.isServerGrant("mcp__folio"))
        XCTAssertFalse(MCPToolNaming.isServerGrant("mcp__folio__get_metadata"))
        XCTAssertFalse(MCPToolNaming.isServerGrant("read_file"))
        XCTAssertEqual(MCPToolNaming.slug(ofName: "mcp__folio"), "folio")
        XCTAssertNil(MCPToolNaming.foldedToolName(ofName: "mcp__folio"))
    }

    func testReadsNothingOffAMalformedName() {
        XCTAssertNil(MCPToolNaming.slug(ofName: "read_file"))
        XCTAssertNil(MCPToolNaming.slug(ofName: "mcp__BAD__tool"))
        XCTAssertNil(MCPToolNaming.slug(ofName: "mcp____tool"))
        XCTAssertNil(MCPToolNaming.foldedToolName(ofName: "read_file"))
    }

    func testRoundTripsEveryBuiltName() throws {
        for (slug, tool) in [("folio", "get_screenshot"), ("trade_room", "GetPortfolio"), ("a0", "x")] {
            let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: slug, toolName: tool))
            XCTAssertEqual(MCPToolNaming.slug(ofName: name), slug)
            XCTAssertEqual(MCPToolNaming.foldedToolName(ofName: name), MCPToolNaming.foldToolName(tool))
        }
    }
}
