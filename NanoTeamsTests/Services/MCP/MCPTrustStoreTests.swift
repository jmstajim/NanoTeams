import XCTest

@testable import NanoTeams

/// What the user approved, across launches. Every test here is about one property: a tool
/// reaches a prompt only while its live hash equals the one a person read.
final class MCPTrustStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MCPTrustStore!
    private let serverID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    /// A tool's canonical text and the hash it pins. The store derives the second from the
    /// first, so a test names the TEXT and reads the hash back — the way a real approval works.
    private func text(_ tool: String, _ version: String = "v1") -> (form: String, hash: String) {
        let form = MCPPinHasher.canonicalForm(rawTool: .object([
            "name": .string(tool), "description": .string("Does \(tool), \(version)."),
        ]))
        return (form, MCPPinHasher.hash(canonicalForm: form))
    }

    private func approve(_ tool: String, _ version: String = "v1", on store: MCPTrustStore? = nil,
                         serverID: UUID? = nil, now: Date? = nil) throws {
        try (store ?? self.store).approve(
            serverID: serverID ?? self.serverID, tool: tool, canonicalForm: text(tool, version).form,
            now: now ?? epoch)
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-trust-\(UUID().uuidString)", isDirectory: true)
        store = MCPTrustStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Approving

    func testAnUnknownServerHasNoApprovalsAndNoEra() {
        XCTAssertTrue(store.record(for: serverID).toolPins.isEmpty)
        XCTAssertNil(store.cachedEra(serverID: serverID))
        XCTAssertNil(store.pin(serverID: serverID, tool: "x"))
    }

    func testApprovingPinsTheHashAndSurvivesAReload() throws {
        try approve("GetPortfolio")
        let reloaded = MCPTrustStore(directory: directory)
        let pin = try XCTUnwrap(reloaded.pin(serverID: serverID, tool: "GetPortfolio"))
        XCTAssertEqual(pin.hash, text("GetPortfolio").hash)
        XCTAssertEqual(pin.approvedAt, epoch)
        XCTAssertFalse(pin.alwaysAllow)
        XCTAssertEqual(reloaded.record(for: serverID).approvedAt, epoch)
    }

    /// The first approval stamps the server; later ones must not move it, or "since when has
    /// this server been trusted" becomes unanswerable.
    func testTheServersOwnApprovalStampIsSetOnceOnly() throws {
        try approve("a")
        try approve("b", now: epoch.addingTimeInterval(1000))
        XCTAssertEqual(store.record(for: serverID).approvedAt, epoch)
    }

    func testApproveAllTakesAWholePageAtOnce() throws {
        try store.approveAll(
            serverID: serverID, canonicalFormsByTool: ["a": text("a").form, "b": text("b").form], now: epoch)
        XCTAssertEqual(Set(store.record(for: serverID).toolPins.keys), ["a", "b"])
        XCTAssertEqual(store.pin(serverID: serverID, tool: "b")?.hash, text("b").hash)
        XCTAssertEqual(store.pin(serverID: serverID, tool: "b")?.approvedCanonicalJSON, text("b").form,
                       "a bulk approval records each tool's own text, as a single one does")
    }

    /// The pin carries the bytes its hash was taken over, so a later rewrite can be shown as a
    /// diff against what was read — and the stored text provably IS that text.
    func testApprovingRecordsTheTextItsHashCovers() throws {
        try approve("a")
        let pin = try XCTUnwrap(MCPTrustStore(directory: directory).pin(serverID: serverID, tool: "a"))
        XCTAssertEqual(pin.approvedCanonicalJSON, text("a").form)
        XCTAssertEqual(pin.hash, MCPPinHasher.hash(canonicalForm: try XCTUnwrap(pin.approvedCanonicalJSON)))
    }

    func testRevokingDropsOneToolAndLeavesTheRest() throws {
        try approve("a")
        try approve("b")
        XCTAssertTrue(try store.revoke(serverID: serverID, tool: "a", expectedHash: text("a").hash))
        XCTAssertNil(store.pin(serverID: serverID, tool: "a"))
        XCTAssertNotNil(store.pin(serverID: serverID, tool: "b"))
    }

    /// A revoke is bound to the approval the person was looking at: one that has since been
    /// replaced by an approval of another text is not theirs to delete from a stale screen.
    func testRevokingIsBoundToTheHashOnScreen() throws {
        try approve("a", "v1")
        XCTAssertFalse(try store.revoke(serverID: serverID, tool: "a", expectedHash: text("a", "v2").hash))
        XCTAssertEqual(store.pin(serverID: serverID, tool: "a")?.hash, text("a", "v1").hash)
        XCTAssertTrue(try store.revoke(serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash))
        XCTAssertNil(store.pin(serverID: serverID, tool: "a"))
        XCTAssertTrue(try store.revoke(serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash),
                      "nothing approved is nothing to revoke — the second press is not an error")
    }

    // MARK: - Rejecting

    /// Refusing a rewrite keeps the approval of the old text exactly as it was — hash and
    /// recorded text — so the tool stays "changed" against what was read, and the grant goes.
    func testRejectingARewriteKeepsTheApprovalAndDropsTheGrant() throws {
        try approve("a", "v1")
        XCTAssertTrue(try store.setAlwaysAllow(
            serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash, allowed: true))

        XCTAssertTrue(try store.reject(serverID: serverID, tool: "a", hash: text("a", "v2").hash))

        let reloaded = MCPTrustStore(directory: directory)
        let pin = try XCTUnwrap(reloaded.pin(serverID: serverID, tool: "a"))
        XCTAssertEqual(pin.hash, text("a", "v1").hash)
        XCTAssertEqual(pin.approvedCanonicalJSON, text("a", "v1").form)
        XCTAssertFalse(pin.alwaysAllow)
        XCTAssertEqual(reloaded.record(for: serverID).rejectedHash(of: "a"), text("a", "v2").hash)
    }

    /// A tool nobody approved can be refused too — the refusal is what keeps it out of a bulk
    /// approval — and refusing it writes no pin: an old build must still read it as new.
    func testRejectingANewToolWritesARefusalAndNoPin() throws {
        XCTAssertTrue(try store.reject(serverID: serverID, tool: "a", hash: text("a").hash))
        XCTAssertNil(store.pin(serverID: serverID, tool: "a"))
        XCTAssertEqual(store.record(for: serverID).rejectedHash(of: "a"), text("a").hash)
    }

    /// The invariant: a refusal is never recorded AT the approved hash. An older build ignores
    /// the refusal and would read that text as approved — one text, two answers.
    func testTheApprovedTextCannotBeRejected() throws {
        try approve("a", "v1")
        XCTAssertFalse(try store.reject(serverID: serverID, tool: "a", hash: text("a", "v1").hash))
        XCTAssertNil(store.record(for: serverID).rejectedHash(of: "a"))
        XCTAssertEqual(store.pin(serverID: serverID, tool: "a")?.hash, text("a", "v1").hash)
    }

    /// Approving a text the person had refused earlier withdraws the refusal of THAT text.
    func testApprovingARefusedTextWithdrawsTheRefusal() throws {
        try store.reject(serverID: serverID, tool: "a", hash: text("a", "v2").hash)
        try approve("a", "v2")
        XCTAssertNil(store.record(for: serverID).rejectedHash(of: "a"))
    }

    // MARK: - The diff

    func testTheDiffSeparatesApprovedNewChangedAndRemoved() throws {
        try approve("same")
        try approve("moved")
        try approve("gone")
        let diff = store.pinDiff(serverID: serverID, liveHashes: [
            "same": text("same").hash, "moved": text("moved", "v9").hash, "fresh": text("fresh").hash,
        ])
        XCTAssertEqual(diff.approvedNames, ["same"])
        XCTAssertEqual(diff.changedNames, ["moved"])
        XCTAssertEqual(diff.newNames, ["fresh"])
        XCTAssertEqual(diff.removed, ["gone"])
    }

    // MARK: - Always allow

    /// The grant is only ever recorded against the hash the user was looking at, so a tool
    /// that moved between the card being shown and the tap landing gets no grant at all.
    func testAlwaysAllowIsRefusedWhenTheHashMovedUnderneath() throws {
        try approve("a", "v1")
        XCTAssertFalse(try store.setAlwaysAllow(
            serverID: serverID, tool: "a", expectedHash: text("a", "v2").hash, allowed: true))
        XCTAssertFalse(try XCTUnwrap(store.pin(serverID: serverID, tool: "a")).alwaysAllow)

        XCTAssertTrue(try store.setAlwaysAllow(
            serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash, allowed: true))
        XCTAssertTrue(try XCTUnwrap(store.pin(serverID: serverID, tool: "a")).alwaysAllow)
    }

    func testAlwaysAllowCanBeWithdrawn() throws {
        try approve("a")
        _ = try store.setAlwaysAllow(serverID: serverID, tool: "a", expectedHash: text("a").hash, allowed: true)
        _ = try store.setAlwaysAllow(serverID: serverID, tool: "a", expectedHash: text("a").hash, allowed: false)
        XCTAssertFalse(try XCTUnwrap(store.pin(serverID: serverID, tool: "a")).alwaysAllow)
    }

    /// Withdrawing is never refused, whatever hash the screen held: it fails closed, and a
    /// stale switch that could not turn a grant OFF would be the unsafe direction.
    func testWithdrawingAGrantIsNeverRefused() throws {
        try approve("a", "v1")
        _ = try store.setAlwaysAllow(serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash, allowed: true)
        XCTAssertTrue(try store.setAlwaysAllow(
            serverID: serverID, tool: "a", expectedHash: text("a", "v2").hash, allowed: false))
        XCTAssertFalse(try XCTUnwrap(store.pin(serverID: serverID, tool: "a")).alwaysAllow)
    }

    /// A grant given for one text is not a grant for another — carrying it across a change is
    /// exactly the rug pull the pin exists to catch.
    func testReapprovingAfterAChangeStartsWithoutTheGrant() throws {
        try approve("a", "v1")
        _ = try store.setAlwaysAllow(serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash, allowed: true)
        try approve("a", "v2")
        XCTAssertFalse(try XCTUnwrap(store.pin(serverID: serverID, tool: "a")).alwaysAllow)
    }

    func testAlwaysAllowOnAToolNobodyApprovedIsRefused() throws {
        XCTAssertFalse(try store.setAlwaysAllow(
            serverID: serverID, tool: "a", expectedHash: text("a").hash, allowed: true))
    }

    // MARK: - Catalogue drift

    /// A restarting server shows an empty catalogue for a moment; pruning on sight would send
    /// the user back through the review sheet after every Folio relaunch.
    func testAVanishedToolIsMarkedRatherThanDropped() throws {
        try approve("a")
        try approve("b")
        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a").hash], now: epoch)
        XCTAssertNotNil(store.pin(serverID: serverID, tool: "b"))
        XCTAssertEqual(store.pin(serverID: serverID, tool: "b")?.removedAt, epoch)
        XCTAssertNil(store.pin(serverID: serverID, tool: "a")?.removedAt)
    }

    func testAToolThatComesBackHasItsMarkCleared() throws {
        try approve("a")
        try store.reconcile(serverID: serverID, liveHashes: [:], now: epoch)
        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a").hash], now: epoch.addingTimeInterval(10))
        XCTAssertNil(store.pin(serverID: serverID, tool: "a")?.removedAt)
    }

    /// Marking is idempotent: a second reconcile while the tool is still gone must not move
    /// the clock forward and restart the retention window.
    func testASecondReconcileDoesNotRestartTheRetentionWindow() throws {
        try approve("a")
        try store.reconcile(serverID: serverID, liveHashes: [:], now: epoch)
        try store.reconcile(serverID: serverID, liveHashes: [:], now: epoch.addingTimeInterval(1000))
        XCTAssertEqual(store.pin(serverID: serverID, tool: "a")?.removedAt, epoch)
    }

    /// A rewrite drops the standing grant, on disk, the moment a refresh sees it — and a server
    /// that later restores the approved text does not get the grant back with it.
    func testAChangedHashClearsAlwaysAllowAndARevertDoesNotRestoreIt() throws {
        try approve("a", "v1")
        _ = try store.setAlwaysAllow(serverID: serverID, tool: "a", expectedHash: text("a", "v1").hash, allowed: true)

        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a", "v2").hash], now: epoch)
        XCTAssertFalse(try XCTUnwrap(MCPTrustStore(directory: directory).pin(serverID: serverID, tool: "a")).alwaysAllow,
                       "the clearing is persisted, not just held in memory")

        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a", "v1").hash], now: epoch)
        let pin = try XCTUnwrap(store.pin(serverID: serverID, tool: "a"))
        XCTAssertEqual(pin.hash, text("a", "v1").hash, "the approval of the old text is kept")
        XCTAssertFalse(pin.alwaysAllow)
    }

    /// A refresh that finds the catalogue exactly as recorded writes nothing: reconciling runs
    /// on every list, and a write per list is a trust-file rewrite per `list_changed`.
    func testAReconcileThatChangesNothingWritesNothing() throws {
        try approve("a")
        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a").hash], now: epoch)
        let before = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        try store.reconcile(serverID: serverID, liveHashes: ["a": text("a").hash], now: epoch)
        let after = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testPruningTakesOnlyThePinsPastTheirWindow() throws {
        try approve("old")
        try approve("recent")
        try approve("live")
        let live = ["live": text("live").hash]
        try store.reconcile(serverID: serverID, liveHashes: live, now: epoch)
        // Move only `recent` forward, so the two removed pins age differently.
        try store.reconcile(serverID: serverID, liveHashes: live.merging(["recent": text("recent").hash]) { a, _ in a },
                            now: epoch)
        try store.reconcile(serverID: serverID, liveHashes: live,
                            now: epoch.addingTimeInterval(MCPConstants.removedPinRetention))

        let pruned = try store.pruneRemoved(now: epoch.addingTimeInterval(MCPConstants.removedPinRetention + 1))
        XCTAssertEqual(pruned, 1)
        XCTAssertNil(store.pin(serverID: serverID, tool: "old"))
        XCTAssertNotNil(store.pin(serverID: serverID, tool: "recent"))
        XCTAssertNotNil(store.pin(serverID: serverID, tool: "live"))
    }

    func testASweepThatFindsNothingWritesNothing() throws {
        try approve("a")
        let before = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(try store.pruneRemoved(now: epoch), 0)
        let after = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: - Era cache

    func testTheEraIsCachedAndCanBeReplaced() throws {
        try store.cacheEra(serverID: serverID, era: .legacy)
        XCTAssertEqual(MCPTrustStore(directory: directory).cachedEra(serverID: serverID), .legacy)
        try store.cacheEra(serverID: serverID, era: .modern)
        XCTAssertEqual(store.cachedEra(serverID: serverID), .modern)
    }

    // MARK: - Forgetting

    /// A later server reusing the id would otherwise inherit a stranger's approvals.
    func testForgettingAServerTakesItsApprovalsWithIt() throws {
        let other = UUID()
        try approve("a")
        try approve("a", serverID: other)
        try store.forget(serverID: serverID)
        XCTAssertTrue(store.record(for: serverID).toolPins.isEmpty)
        XCTAssertFalse(store.record(for: other).toolPins.isEmpty)
    }

    // MARK: - Corruption

    /// The consequence is deliberate and is the safe direction: every tool becomes unreviewed
    /// and the user is asked again.
    ///
    /// Read by a store that has not loaded yet: a store holds the file it read or wrote, and the
    /// damage here is done behind its back — as it would be by anything but this app.
    func testAnUnreadableTrustFileMakesEverythingUnreviewedAgain() throws {
        try approve("a")
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertTrue(MCPTrustStore(directory: directory).load().records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    func testTheTrustFileIsOwnerOnly() throws {
        try approve("a")
        let mode = try FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: - Held in memory

    /// The file is read once and then answered from memory: every snapshot rebuild, every row
    /// and every approval card asks it, all on the main actor, and each one used to be a full
    /// read and decode of the file.
    func testReadsAreServedFromMemoryAfterTheFirstLoad() throws {
        try approve("a")
        let counting = CountingFileManager(watching: store.fileURL.path)
        let cold = MCPTrustStore(directory: directory, fileManager: counting)
        for _ in 0..<50 {
            _ = cold.pin(serverID: serverID, tool: "a")
            _ = cold.record(for: serverID)
        }
        XCTAssertEqual(counting.lookups, 1, "one read of the file, then memory")
        XCTAssertEqual(cold.pin(serverID: serverID, tool: "a")?.hash, text("a").hash)
    }

    /// A write replaces what is held, so the next read needs no disk and sees the write.
    func testAWriteIsVisibleWithoutRereadingTheFile() throws {
        let counting = CountingFileManager(watching: store.fileURL.path)
        let counted = MCPTrustStore(directory: directory, fileManager: counting)
        try approve("a", on: counted)
        let afterFirstWrite = counting.lookups
        try approve("b", on: counted)
        XCTAssertEqual(counted.pin(serverID: serverID, tool: "b")?.hash, text("b").hash)
        XCTAssertEqual(counting.lookups, afterFirstWrite, "the second write and the read after it touch no file")
    }

    /// A write that fails leaves memory where the disk is: the person is told the change was
    /// not saved, and the next read must not claim otherwise.
    func testAFailedWriteLeavesMemoryMatchingTheDisk() throws {
        try approve("a")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try approve("b"))
        XCTAssertNil(store.pin(serverID: serverID, tool: "b"))
        XCTAssertNotNil(store.pin(serverID: serverID, tool: "a"))
    }
}

/// Counts how often the trust file is looked for — which is how often it is read, since every
/// read starts with that check.
private final class CountingFileManager: FileManager {
    private let watched: String
    private let lock = NSLock()
    private var count = 0

    init(watching path: String) {
        self.watched = path
        super.init()
    }

    var lookups: Int { lock.withLock { count } }

    override func fileExists(atPath path: String) -> Bool {
        if path == watched { lock.withLock { count += 1 } }
        return super.fileExists(atPath: path)
    }
}
