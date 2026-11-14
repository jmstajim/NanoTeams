import XCTest

@testable import NanoTeams

/// The MCP tunables carry relationships, not just values — a probe longer than the
/// connect budget, or an inactivity timeout above the absolute one, would each turn a
/// guard into a no-op silently.
final class MCPConstantsTests: XCTestCase {

    func testProtocolVersionsAreDistinctAndDated() {
        XCTAssertNotEqual(MCPConstants.modernProtocolVersion, MCPConstants.legacyProtocolVersion)
        for version in [MCPConstants.modernProtocolVersion, MCPConstants.legacyProtocolVersion] {
            XCTAssertEqual(version.count, 10, "a revision is spelled YYYY-MM-DD")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: version + "T00:00:00Z"), version)
        }
    }

    func testLegacyOfferIsItselfAccepted() {
        // The version named in `initialize` must be one the client can accept back, or
        // every well-behaved legacy server would be disconnected for echoing us.
        XCTAssertTrue(MCPConstants.acceptedLegacyProtocolVersions.contains(MCPConstants.legacyProtocolVersion))
        XCTAssertFalse(MCPConstants.acceptedLegacyProtocolVersions.contains("2024-11-05"),
                       "the HTTP+SSE revision is a different transport, not a dialect")
        XCTAssertFalse(MCPConstants.acceptedLegacyProtocolVersions.contains(MCPConstants.modernProtocolVersion))
    }

    func testTimeoutsAreOrdered() {
        XCTAssertLessThan(MCPConstants.probeTimeout, MCPConstants.connectTimeout)
        XCTAssertLessThan(MCPConstants.requestInactivityTimeout, MCPConstants.requestAbsoluteTimeout)
        // The termination delegate has ~5 s in total and the search index shares it.
        XCTAssertLessThanOrEqual(MCPConstants.shutdownBudget, 5)
        XCTAssertGreaterThan(MCPConstants.shutdownBudget, 0)
    }

    func testBackoffIsNonDecreasingAndBounded() {
        let backoff = MCPConstants.reconnectBackoff
        XCTAssertFalse(backoff.isEmpty)
        XCTAssertEqual(backoff, backoff.sorted())
        XCTAssertGreaterThan(backoff.first ?? 0, 0)
        XCTAssertLessThanOrEqual(backoff.last ?? .infinity, 60)
    }

    func testGuardsAreSaneCeilings() {
        XCTAssertGreaterThan(MCPConstants.maxFrameBytes, 1024 * 1024)
        XCTAssertGreaterThan(MCPConstants.maxToolsListPages, 1)
        XCTAssertGreaterThan(MCPConstants.maxSchemaRefDepth, 1)
        XCTAssertGreaterThanOrEqual(MCPConstants.crashLoopFailureCount, 2)
        XCTAssertGreaterThan(MCPConstants.crashLoopWindow, 0)
        XCTAssertGreaterThanOrEqual(MCPConstants.minimumCatalogueTTL, 1)
        XCTAssertGreaterThan(MCPConstants.removedPinRetention, MCPConstants.minimumCatalogueTTL)
    }

    func testKeychainServiceIsScopedAndVersioned() {
        XCTAssertTrue(MCPConstants.keychainService.hasPrefix("com.nanoteams."))
        XCTAssertTrue(MCPConstants.keychainService.hasSuffix(".v1"))
        XCTAssertNotEqual(MCPConstants.keychainService, KeychainSecureTokenStorage.defaultService,
                          "MCP secrets must not share the LM Studio service")
    }

    func testProtocolVersionHeaderSpelling() {
        XCTAssertEqual(MCPConstants.protocolVersionHeader, "MCP-Protocol-Version")
    }
}
