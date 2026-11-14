import XCTest

@testable import NanoTeams

/// Pins, their diff against a live catalogue, and the three files this state lives in. The
/// diff is the rug-pull detector, so its four outcomes are each pinned separately.
final class MCPTrustTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func pin(_ name: String, _ hash: String, alwaysAllow: Bool = false, removedAt: Date? = nil) -> MCPToolPin {
        MCPToolPin(toolName: name, hash: hash, approvedAt: epoch, alwaysAllow: alwaysAllow, removedAt: removedAt)
    }

    // MARK: - Era

    func testEveryEraNamesItself() {
        XCTAssertEqual(MCPProtocolEra.modern.displayName, MCPConstants.modernProtocolVersion)
        for era in MCPProtocolEra.allCases {
            XCTAssertFalse(era.displayName.isEmpty, era.rawValue)
        }
        XCTAssertEqual(try JSONDecoder().decode(MCPProtocolEra.self, from: Data("\"legacy\"".utf8)), .legacy)
    }

    // MARK: - Diff

    func testAMatchingHashIsApprovedAndOnlyThatReachesAPrompt() {
        let diff = MCPPinDiff.between(liveHashes: ["a": "h1"], pins: ["a": pin("a", "h1")])
        XCTAssertEqual(diff.states["a"], .approved)
        XCTAssertEqual(diff.approvedNames, ["a"])
        XCTAssertEqual(diff.newNames, [])
        XCTAssertEqual(diff.changedNames, [])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testAToolNobodyApprovedIsNew() {
        let diff = MCPPinDiff.between(liveHashes: ["a": "h1"], pins: [:])
        XCTAssertEqual(diff.states["a"], .new)
        XCTAssertEqual(diff.newNames, ["a"])
        XCTAssertEqual(diff.changedNames, [])
    }

    /// The rug pull: an honest tool is approved, then its description is swapped for one the
    /// model will obey. The diff has to carry the OLD hash so the review sheet can show what
    /// changed rather than just that something did.
    func testAToolWhoseTextChangedIsChangedAndRemembersWhatWasApproved() {
        let diff = MCPPinDiff.between(liveHashes: ["a": "h2"], pins: ["a": pin("a", "h1")])
        XCTAssertEqual(diff.states["a"], .changed(approvedHash: "h1"))
        XCTAssertEqual(diff.changedNames, ["a"])
        XCTAssertEqual(diff.approvedNames, [])
        XCTAssertFalse(diff.states["a"]?.isApproved ?? true)
    }

    func testAPinnedToolThatVanishedIsReportedSeparatelyFromTheLiveOnes() {
        let diff = MCPPinDiff.between(liveHashes: ["b": "h2"], pins: ["a": pin("a", "h1"), "b": pin("b", "h2")])
        XCTAssertEqual(diff.removed, ["a"])
        XCTAssertNil(diff.states["a"], "a vanished tool has no live state")
        XCTAssertEqual(diff.approvedNames, ["b"])
    }

    func testTheEmptyCatalogueOfAServerThatIsStartingUpLosesNothing() {
        let diff = MCPPinDiff.between(liveHashes: [:], pins: ["a": pin("a", "h1")])
        XCTAssertEqual(diff.removed, ["a"])
        XCTAssertTrue(diff.states.isEmpty)
        XCTAssertEqual(diff.newNames + diff.changedNames, [], "nothing to review — the tools are simply not there")
    }

    func testDiffNamesAreSortedSoTheReviewSheetIsStableAcrossRefreshes() {
        let diff = MCPPinDiff.between(liveHashes: ["z": "h", "a": "h", "m": "h"], pins: [:])
        XCTAssertEqual(diff.newNames, ["a", "m", "z"])
    }

    // MARK: - Retention

    /// A restarting server drops its whole catalogue for a moment. Pruning on sight would send
    /// the user back through the review sheet after every Folio relaunch.
    func testARemovedPinSurvivesItsRetentionWindow() {
        let removed = pin("a", "h1", removedAt: epoch)
        XCTAssertFalse(removed.isPrunable(now: epoch.addingTimeInterval(60)))
        XCTAssertFalse(removed.isPrunable(now: epoch.addingTimeInterval(MCPConstants.removedPinRetention)))
        XCTAssertTrue(removed.isPrunable(now: epoch.addingTimeInterval(MCPConstants.removedPinRetention + 1)))
    }

    func testAPinStillInTheCatalogueIsNeverPrunable() {
        XCTAssertFalse(pin("a", "h1").isPrunable(now: .distantFuture))
    }

    func testPinDecodesTolerantlyAroundTheTwoFieldsThatHaveNoDefault() throws {
        let decoded = try JSONDecoder().decode(
            MCPToolPin.self, from: Data(#"{"toolName":"a","hash":"h1"}"#.utf8))
        XCTAssertEqual(decoded.toolName, "a")
        XCTAssertFalse(decoded.alwaysAllow)
        XCTAssertNil(decoded.removedAt)
        XCTAssertThrowsError(try JSONDecoder().decode(MCPToolPin.self, from: Data(#"{"hash":"h"}"#.utf8)))
    }

    /// A pin written before texts were recorded decodes with no text, and one written after
    /// carries it through a round trip — both builds read both files.
    func testThePinsRecordedTextIsOptionalAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            MCPToolPin.self, from: Data(#"{"toolName":"a","hash":"h1","alwaysAllow":true}"#.utf8))
        XCTAssertNil(legacy.approvedCanonicalJSON)
        XCTAssertTrue(legacy.alwaysAllow)

        let recorded = MCPToolPin(
            toolName: "a", hash: "h1", approvedAt: epoch, approvedCanonicalJSON: #"{"name":"a"}"#)
        let decoded = try JSONDecoder().decode(MCPToolPin.self, from: JSONEncoder().encode(recorded))
        XCTAssertEqual(decoded, recorded)
    }

    /// Nothing new is written for a pin that recorded no text: a file an older build re-reads
    /// carries no key it does not know.
    func testAPinWithNoRecordedTextEncodesNoKeyForIt() throws {
        let json = String(decoding: try JSONEncoder().encode(pin("a", "h1")), as: UTF8.self)
        XCTAssertFalse(json.contains("approvedCanonicalJSON"), json)
    }

    // MARK: - Pin state

    /// One rule, per descriptor, at its own hash.
    func testThePinStateIsDerivedFromTheLiveHashAndThePin() {
        XCTAssertEqual(MCPPinState(liveHash: "h1", pin: nil), .new)
        XCTAssertEqual(MCPPinState(liveHash: "h1", pin: pin("a", "h1")), .approved)
        XCTAssertEqual(MCPPinState(liveHash: "h2", pin: pin("a", "h1")), .changed(approvedHash: "h1"))
    }

    /// A revoke is bound to the approval on record — for a rewrite that is the OLD text's hash,
    /// not the live one, which nobody approved. A new tool has nothing to revoke.
    func testTheApprovalOnRecordIsTheOneARevokeNames() {
        XCTAssertEqual(MCPPinState.approved.approvedHash(liveHash: "h1"), "h1")
        XCTAssertEqual(MCPPinState.changed(approvedHash: "h1").approvedHash(liveHash: "h2"), "h1")
        XCTAssertNil(MCPPinState.new.approvedHash(liveHash: "h1"))
    }

    // MARK: - Refusals

    /// A refusal decides nothing about a prompt — it is kept beside the pins — and it is never
    /// recorded at the approved hash: an older build ignores the refusal and would read that
    /// text as approved while this one reads it as refused.
    func testARefusalAtTheApprovedHashIsNeverKept() throws {
        var record = MCPServerTrustRecord(toolPins: ["a": pin("a", "h1")])
        XCTAssertFalse(record.reject(tool: "a", hash: "h1"))
        XCTAssertNil(record.rejectedHash(of: "a"))
        XCTAssertTrue(record.reject(tool: "a", hash: "h2"))
        XCTAssertEqual(record.rejectedHash(of: "a"), "h2")
        XCTAssertTrue(record.reject(tool: "b", hash: "h9"), "a tool with no pin can be refused")
    }

    /// A file that breaks the rule — written by hand, or by a build with a bug — is repaired on
    /// read rather than believed.
    func testADecodedRefusalAtTheApprovedHashIsDropped() throws {
        let json = #"{"toolPins":{"a":{"toolName":"a","hash":"h1"}},"rejectedHashes":{"a":"h1","b":"h2"}}"#
        let record = try JSONDecoder().decode(MCPServerTrustRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.rejectedHash(of: "a"))
        XCTAssertEqual(record.rejectedHash(of: "b"), "h2")
    }

    /// Approving the refused text withdraws the refusal of that text.
    func testPinningTheRefusedTextWithdrawsTheRefusal() {
        var record = MCPServerTrustRecord()
        record.reject(tool: "a", hash: "h2")
        record.setPin(pin("a", "h2"))
        XCTAssertNil(record.rejectedHash(of: "a"))
    }

    /// The one reading of a refusal: of exactly the text refused, by the server's own tool
    /// name — the server's next rewrite is not covered, and another tool at the same hash is not
    /// either. The connection's rows and tally and the grant catalogue all read it here.
    func testARefusalCoversExactlyTheTextRefused() {
        var record = MCPServerTrustRecord(toolPins: ["b": pin("b", "h1")])
        record.reject(tool: "a", hash: "h2")
        func descriptor(_ name: String, _ hash: String) -> MCPToolDescriptor {
            MCPToolDescriptorTests.makeDescriptor(
                originalName: name, modelFacingName: "mcp__folio__\(name)", pinHash: hash)
        }
        XCTAssertTrue(record.isRejected(descriptor("a", "h2")))
        XCTAssertFalse(record.isRejected(descriptor("a", "h3")), "a rewrite is a text nobody refused")
        XCTAssertFalse(record.isRejected(descriptor("c", "h2")), "another tool at the same hash")
        XCTAssertFalse(record.isRejected(descriptor("b", "h1")), "an approved text is never refused")
        XCTAssertFalse(MCPServerTrustRecord.empty.isRejected(descriptor("a", "h2")))
    }

    /// A record from before refusals existed decodes with none.
    func testARecordWithoutRefusalsDecodes() throws {
        let record = try JSONDecoder().decode(MCPServerTrustRecord.self, from: Data(#"{"toolPins":{}}"#.utf8))
        XCTAssertNil(record.rejectedHash(of: "a"))
    }

    // MARK: - Files

    /// A successful legacy decode that re-persists the OLD version makes the legacy branch
    /// re-fire forever (CLAUDE.md #48).
    func testEveryFileBumpsItsSchemaVersionOnRead() throws {
        let trust = try JSONDecoder().decode(MCPTrustFile.self, from: Data("{}".utf8))
        XCTAssertEqual(trust.schemaVersion, MCPTrustFile.currentSchemaVersion)
        let catalogue = try JSONDecoder().decode(MCPServerCatalogueFile.self, from: Data("{}".utf8))
        XCTAssertEqual(catalogue.schemaVersion, MCPServerCatalogueFile.currentSchemaVersion)
        let overrides = try JSONDecoder().decode(MCPFolderOverrides.self, from: Data("{}".utf8))
        XCTAssertEqual(overrides.schemaVersion, MCPFolderOverrides.currentSchemaVersion)
    }

    func testAFileFromANewerBuildKeepsItsOwnVersion() throws {
        let trust = try JSONDecoder().decode(MCPTrustFile.self, from: Data(#"{"schemaVersion":9}"#.utf8))
        XCTAssertEqual(trust.schemaVersion, 9)
    }

    func testTrustFileRoundTripsItsRecords() throws {
        let id = UUID().uuidString
        let file = MCPTrustFile(records: [id: MCPServerTrustRecord(
            approvedAt: epoch, cachedEra: .modern, toolPins: ["a": pin("a", "h1", alwaysAllow: true)])])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(MCPTrustFile.self, from: data)
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.records[id]?.toolPins["a"]?.alwaysAllow, true)
    }

    func testAnEmptyTrustRecordCarriesNoEraAndNoApproval() {
        XCTAssertNil(MCPServerTrustRecord.empty.cachedEra)
        XCTAssertNil(MCPServerTrustRecord.empty.approvedAt)
        XCTAssertTrue(MCPServerTrustRecord.empty.toolPins.isEmpty)
        XCTAssertTrue(MCPTrustFile.empty.records.isEmpty)
        XCTAssertTrue(MCPServerCatalogueFile.empty.servers.isEmpty)
    }

    /// Stored as a DISABLED list on purpose: a server added later must not be silently absent
    /// from folders that predate it.
    func testFolderOverridesDisableRatherThanEnable() {
        let known = UUID()
        let unknown = UUID()
        let overrides = MCPFolderOverrides(disabledServerIDs: [known])
        XCTAssertFalse(overrides.allows(known))
        XCTAssertTrue(overrides.allows(unknown))
        XCTAssertTrue(MCPFolderOverrides.empty.allows(known))
    }

    func testFolderOverridesRoundTrip() throws {
        let overrides = MCPFolderOverrides(disabledServerIDs: [UUID(), UUID()])
        let data = try JSONEncoder().encode(overrides)
        XCTAssertEqual(try JSONDecoder().decode(MCPFolderOverrides.self, from: data), overrides)
    }
}
