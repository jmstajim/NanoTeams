import XCTest

@testable import NanoTeams

/// The one place that knows where an MCP secret lives: how a save changes a server's accounts,
/// how a removal clears them, and which of them hold a value.
final class MCPSecretStoreTests: XCTestCase {

    private var storage: InMemorySecureTokenStorage!
    private var store: MCPSecretStore!

    override func setUp() {
        super.setUp()
        storage = InMemorySecureTokenStorage()
        store = MCPSecretStore(storage: storage)
    }

    override func tearDown() {
        storage = nil
        store = nil
        super.tearDown()
    }

    private func config(
        authorization: MCPAuthorizationMode = .staticBearer, secretHeaderNames: [String] = []
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")), displayName: "T",
            transport: .http(MCPHTTPConfig(
                urlString: "https://x/mcp", secretHeaderNames: secretHeaderNames,
                authorization: authorization)))
    }

    // MARK: - Per-server lifecycle

    /// A token left behind after a delete is a credential nothing in the UI can see any more.
    func testDeletingAServerClearsEveryAccountItOwns() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        try storage.setToken("bearer", forKey: config.bearerSecretKey)
        try storage.setToken("header", forKey: config.secretKey(forHeader: "X-Api-Key"))
        XCTAssertEqual(store.storedKeys(of: config).count, 2, "premise: both accounts hold a value")

        try store.clearAll(for: config)
        XCTAssertNil(try storage.loadToken(forKey: config.bearerSecretKey))
        XCTAssertNil(try storage.loadToken(forKey: config.secretKey(forHeader: "X-Api-Key")))
    }

    /// A token saved under Bearer and left behind by a switch to No authentication — which
    /// nothing cleared before 2026-09-24 — goes with the server (F28(2)).
    func testDeletingAServerAlsoClearsABearerLeftFromAnEarlierMode() throws {
        let config = try config(authorization: .none, secretHeaderNames: ["X-Api-Key"])
        try storage.setToken("left over", forKey: config.bearerSecretKey)

        try store.clearAll(for: config)
        XCTAssertNil(try storage.loadToken(forKey: config.bearerSecretKey))
    }

    /// Removal clears EVERY account under the server's prefix — a header account a rename before
    /// 2026-09-24 left behind, a bearer from an earlier mode, anything a failed Add wrote — not
    /// only the ones the config names. Another server's accounts, and an account whose name only
    /// STARTS like this server's id, are not touched: the prefix ends at the `/`.
    ///
    /// RED until the second review of group D (2026-09-24): removal cleared the accounts the
    /// config named and the bearer, and a renamed header's old account stayed for good.
    func testDeletingAServerClearsEveryAccountUnderItsPrefixAndNothingElse() throws {
        let config = try config(authorization: .none, secretHeaderNames: ["X-API-Key"])
        let other = try self.config(secretHeaderNames: ["X-API-Key"])
        let lookalike = "\(config.id.uuidString)-copy/bearer"
        storage = InMemorySecureTokenStorage(initial: [
            config.secretKey(forHeader: "X-API-Key"): "current",
            config.secretKey(forHeader: "X-Api-Key"): "renamed before the fix",
            config.bearerSecretKey: "left over",
            other.bearerSecretKey: "other server",
            other.secretKey(forHeader: "X-API-Key"): "other header",
            lookalike: "not this server's",
        ])
        let corrupt = config.secretKey(forHeader: "X-Corrupt")
        storage.storeCorruptEntry(forKey: corrupt)
        store = MCPSecretStore(storage: storage)

        try store.clearAll(for: config)

        for gone in [config.secretKey(forHeader: "X-API-Key"), config.secretKey(forHeader: "X-Api-Key"),
                     config.bearerSecretKey, corrupt] {
            XCTAssertNil(try storage.loadToken(forKey: gone), gone)
        }
        XCTAssertEqual(try storage.accountNames(withPrefix: config.secretAccountPrefix), [])
        XCTAssertEqual(try storage.loadToken(forKey: other.bearerSecretKey), "other server")
        XCTAssertEqual(try storage.loadToken(forKey: other.secretKey(forHeader: "X-API-Key")), "other header")
        XCTAssertEqual(try storage.loadToken(forKey: lookalike), "not this server's")
    }

    /// A Keychain that refuses the LISTING still loses what the config names, and the removal is
    /// reported as leaving something behind — it cannot know that it did not.
    func testARefusedListingStillClearsWhatTheConfigNamesAndIsReported() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        try storage.setToken("bearer", forKey: config.bearerSecretKey)
        try storage.setToken("header", forKey: config.secretKey(forHeader: "X-Api-Key"))
        storage.readError = .unhandled(-25308)

        XCTAssertThrowsError(try store.clearAll(for: config))
        storage.readError = nil
        XCTAssertNil(try storage.loadToken(forKey: config.bearerSecretKey))
        XCTAssertNil(try storage.loadToken(forKey: config.secretKey(forHeader: "X-Api-Key")))
    }

    /// A delete the Keychain refuses is reported, after every other account has been tried:
    /// the removal then says a credential was left behind instead of claiming it was deleted.
    func testAClearTheKeychainRefusesIsReportedAfterTryingTheRest() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        try storage.setToken("bearer", forKey: config.bearerSecretKey)
        try storage.setToken("header", forKey: config.secretKey(forHeader: "X-Api-Key"))
        let refused = config.bearerSecretKey
        storage.writeFailure = { key, _ in key == refused ? .unhandled(-25308) : nil }

        XCTAssertThrowsError(try store.clearAll(for: config))
        XCTAssertNil(try storage.loadToken(forKey: config.secretKey(forHeader: "X-Api-Key")),
                     "the account the Keychain did not refuse is cleared anyway")
    }

    /// What the editor reads to offer "leave blank to keep": which of the accounts the server
    /// READS hold a value — a blank value holds none. A bearer under No authentication is not
    /// read: the server does not send it, so nothing asks whether it is there.
    func testStoredKeysNameTheAccountsThatHoldAValue() throws {
        let config = try config(authorization: .none, secretHeaderNames: ["X-Api-Key", "X-Tenant"])
        // Seeded around the storage's own trimming: a Keychain entry written by an older build
        // can hold whitespace only, and it must read as holding nothing.
        storage = InMemorySecureTokenStorage(initial: [
            config.bearerSecretKey: "left over",
            config.secretKey(forHeader: "X-Api-Key"): "k",
            config.secretKey(forHeader: "X-Tenant"): "   ",
        ])
        store = MCPSecretStore(storage: storage)

        XCTAssertEqual(store.storedKeys(of: config), [config.secretKey(forHeader: "X-Api-Key")])
        storage.readError = .unhandled(-25308)
        XCTAssertTrue(store.storedKeys(of: config).isEmpty, "an unreadable Keychain promises nothing")
    }

    // MARK: - Applying a save

    private func plan(_ steps: [MCPSecretChangePlan.Step]) -> MCPSecretChangePlan {
        MCPSecretChangePlan(steps: steps, isRepoint: false)
    }

    /// Writes, clears, and a move that reads what the source held when the save STARTED — so
    /// two headers that swap names each keep their own value.
    func testApplyingAPlanWritesClearsAndMovesFromWhatWasThere() throws {
        try storage.setToken("a", forKey: "A")
        try storage.setToken("b", forKey: "B")
        try storage.setToken("gone", forKey: "C")

        _ = try store.apply(plan([
            .move(from: "A", to: "B"), .move(from: "B", to: "A"),
            .write(key: "D", value: "d"), .delete(key: "C"),
        ]))

        XCTAssertEqual(try storage.loadToken(forKey: "A"), "b")
        XCTAssertEqual(try storage.loadToken(forKey: "B"), "a")
        XCTAssertEqual(try storage.loadToken(forKey: "D"), "d")
        XCTAssertNil(try storage.loadToken(forKey: "C"))
    }

    /// A refused write stops the save and puts back everything it had already changed, then
    /// throws — so nothing downstream saves a server whose credential is missing (F41).
    func testARefusedWriteUndoesTheStepsBeforeItAndThrows() throws {
        try storage.setToken("old", forKey: "A")
        storage.writeFailure = { key, token in key == "B" && token != nil ? .unhandled(-25308) : nil }

        XCTAssertThrowsError(try store.apply(plan([
            .write(key: "A", value: "new"), .write(key: "B", value: "b"), .write(key: "C", value: "c"),
        ]))) { error in
            XCTAssertEqual(error as? MCPServerEditError, .keychainNotSaved(undone: true))
        }
        XCTAssertEqual(try storage.loadToken(forKey: "A"), "old", "the write before the refusal is undone")
        XCTAssertNil(try storage.loadToken(forKey: "B"))
        XCTAssertNil(try storage.loadToken(forKey: "C"), "nothing after the refusal is attempted")
    }

    /// When even the undo is refused the error says so — the person must check the token.
    func testAnUndoTheKeychainAlsoRefusesIsReported() throws {
        try storage.setToken("old", forKey: "A")
        storage.writeFailure = { key, token in
            (key == "B" && token != nil) || (key == "A" && token == "old") ? .unhandled(-25308) : nil
        }

        XCTAssertThrowsError(try store.apply(plan([.write(key: "A", value: "new"), .write(key: "B", value: "b")]))) {
            XCTAssertEqual($0 as? MCPServerEditError, .keychainNotSaved(undone: false))
        }
    }

    /// A Keychain that cannot be READ is refused before anything is written: the undo would
    /// have nothing to put back.
    func testAnUnreadableKeychainChangesNothing() throws {
        try storage.setToken("old", forKey: "A")
        storage.readError = .unhandled(-25308)

        XCTAssertThrowsError(try store.apply(plan([.write(key: "A", value: "new")]))) {
            XCTAssertEqual($0 as? MCPServerEditError, .keychainUnreadable)
        }
        storage.readError = nil
        XCTAssertEqual(try storage.loadToken(forKey: "A"), "old")
    }

    /// An entry that EXISTS but cannot be decoded — its own error says to re-enter the token to
    /// overwrite it — is overwritten: for the undo it holds nothing, since putting back bytes
    /// nobody can read restores nothing. A later refusal therefore DELETES what the save wrote
    /// there rather than restoring the corrupt entry.
    ///
    /// RED until the second review of group D (2026-09-24): the read before the write threw, the
    /// save was refused as an unreadable Keychain, and the only way out was removing the server.
    func testACorruptEntryIsOverwrittenAndItsUndoLeavesNothing() throws {
        storage.storeCorruptEntry(forKey: "A")

        let undo = try store.apply(plan([.write(key: "A", value: "pasted")]))
        XCTAssertEqual(try storage.loadToken(forKey: "A"), "pasted")

        XCTAssertTrue(store.restore(undo))
        XCTAssertNil(try storage.loadToken(forKey: "A"), "no corrupt bytes put back — nothing")
        XCTAssertEqual(try storage.accountNames(withPrefix: "A"), [])
    }

    /// A step that clears a corrupt entry clears it: holding nothing readable is not the same as
    /// holding nothing, so the "changes nothing" shortcut does not skip it.
    func testACorruptEntryAStepClearsIsCleared() throws {
        storage.storeCorruptEntry(forKey: "A")
        storage.storeCorruptEntry(forKey: "B")

        _ = try store.apply(plan([.delete(key: "A"), .move(from: "B", to: "C"), .delete(key: "B")]))

        for key in ["A", "B", "C"] { XCTAssertNil(try storage.loadToken(forKey: key), key) }
        XCTAssertEqual(try storage.accountNames(withPrefix: ""), [], "both corrupt entries are gone, C holds nothing")
    }

    /// Only a corrupt entry is read past. A Keychain that refuses the read for any other reason
    /// — locked, an ACL — still refuses the save before anything is written.
    func testOnlyACorruptEntryIsReadPast() throws {
        try storage.setToken("old", forKey: "A")
        storage.readError = .unhandled(-25308)

        XCTAssertThrowsError(try store.apply(plan([.write(key: "A", value: "new")]))) {
            XCTAssertEqual($0 as? MCPServerEditError, .keychainUnreadable)
        }
        storage.readError = nil
        XCTAssertEqual(try storage.loadToken(forKey: "A"), "old")
    }

    /// What a later failure — the server list refusing the write — uses to put the Keychain back.
    func testRestoreReturnsEveryTouchedAccountToWhatItHeld() throws {
        try storage.setToken("old", forKey: "A")
        let undo = try store.apply(plan([.write(key: "A", value: "new"), .write(key: "B", value: "b")]))

        XCTAssertTrue(store.restore(undo))
        XCTAssertEqual(try storage.loadToken(forKey: "A"), "old")
        XCTAssertNil(try storage.loadToken(forKey: "B"))
    }

    /// A value already there is not written again — reopening the sheet must not churn the
    /// Keychain, and a write that would change nothing cannot fail. Compared as the Keychain
    /// would hold it: trimmed first.
    func testAStepThatChangesNothingWritesNothing() throws {
        try storage.setToken("same", forKey: "A")
        storage.writeFailure = { _, _ in .unhandled(-25308) }

        XCTAssertNoThrow(try store.apply(plan([
            .write(key: "A", value: "same"), .write(key: "A", value: "  same  "), .delete(key: "absent"),
        ])))
    }

    /// "Needs a token" must be visible before the first 401 rather than after it — read the
    /// way the server list reads it, from which accounts hold a value, a blank one holding none.
    func testAMissingOrBlankSecretIsVisibleWithoutAskingTheServer() throws {
        let config = try config()
        XCTAssertFalse(config.hasRequiredSecrets(among: store.storedKeys(of: config)))

        store = MCPSecretStore(storage: InMemorySecureTokenStorage(initial: [config.bearerSecretKey: "   "]))
        XCTAssertFalse(config.hasRequiredSecrets(among: store.storedKeys(of: config)))

        store = MCPSecretStore(storage: InMemorySecureTokenStorage(initial: [config.bearerSecretKey: "t.SECRET"]))
        XCTAssertTrue(config.hasRequiredSecrets(among: store.storedKeys(of: config)))

        // Every account it reads, not any one of them: the token alone does not cover the key.
        let both = try self.config(secretHeaderNames: ["X-Api-Key"])
        store = MCPSecretStore(storage: InMemorySecureTokenStorage(initial: [both.bearerSecretKey: "t.SECRET"]))
        XCTAssertFalse(both.hasRequiredSecrets(among: store.storedKeys(of: both)))
        XCTAssertFalse(both.hasRequiredSecrets(among: [both.secretKey(forHeader: "X-Api-Key")]))
        XCTAssertTrue(both.hasRequiredSecrets(among: Set(both.allSecretKeys)))
    }

    func testAServerThatNeedsNoSecretsAlwaysHasThem() throws {
        let config = try config(authorization: .none)
        XCTAssertTrue(config.hasRequiredSecrets(among: store.storedKeys(of: config)))
    }

    /// One spelling of a server's Keychain accounts, and no second one — a second would
    /// strand tokens on the next rename. A save's plan writes under it, and nothing else: every
    /// account the Keychain then holds is one the config names.
    func testTheStoreUsesTheConfigsOwnKeySpelling() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        _ = try store.apply(MCPSecretChangePlan.make(
            stored: nil, saved: config,
            edit: MCPServerSecretEdit(bearer: "v", headers: [.init(name: "X-Api-Key", value: "h")])))

        XCTAssertEqual(try storage.loadToken(forKey: config.bearerSecretKey), "v")
        XCTAssertEqual(try storage.loadToken(forKey: config.secretKey(forHeader: "X-Api-Key")), "h")
        XCTAssertEqual(try storage.accountNames(withPrefix: ""), config.allSecretKeys)
        XCTAssertEqual(config.allSecretKeys.count, 2)
    }

    // MARK: - The orphaned-secret sweep (third pass of group D's review, 2026-09-24)

    private func server(
        url: String, headers: [String] = [], authorization: MCPAuthorizationMode = .none, enabled: Bool = true
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("trade_room")), displayName: "T",
            transport: .http(MCPHTTPConfig(urlString: url, secretHeaderNames: headers, authorization: authorization)),
            isEnabled: enabled)
    }

    /// What the sweep deletes: every account spelled under a server id that no configured server
    /// reads, switched on or off. A current server's own accounts stay; its account under the
    /// spelling before the account named the origin, under another origin, or a bearer its mode
    /// does not send goes, and so does every account of an id no server has. Nothing that is not
    /// spelled under a server id is touched: an LM Studio-shaped account (that token lives under
    /// another Keychain service, and would not match here if it did not), a lookalike id, a
    /// lowercase id, a bare id.
    func testTheSweepSelectsEveryServerAccountNoConfigReadsAndNothingElse() throws {
        let enabled = try server(url: "https://a.test/mcp", headers: ["X-Api-Key"], authorization: .staticBearer)
        let disabled = try server(url: "https://b.test/mcp", headers: ["X-Tenant"], enabled: false)
        var elsewhere = enabled
        elsewhere.transport = .http(MCPHTTPConfig(urlString: "https://old.test/mcp", authorization: .staticBearer))
        let gone = try server(url: "https://a.test/mcp", headers: ["X-Api-Key"], authorization: .staticBearer)
        let kept = [
            enabled.bearerSecretKey, enabled.secretKey(forHeader: "X-Api-Key"), disabled.secretKey(forHeader: "X-Tenant"),
            "http://localhost:1234", "http://127.0.0.1:1234/v1", "\(enabled.id.uuidString.lowercased())/bearer",
            "\(enabled.id.uuidString)-copy/bearer", "not-a-server/bearer", enabled.id.uuidString,
        ]
        let orphans = [
            enabled.secretAccountPrefix + "bearer", enabled.secretAccountPrefix + "header/X-Api-Key",
            elsewhere.bearerSecretKey, disabled.bearerSecretKey,
            gone.bearerSecretKey, gone.secretKey(forHeader: "X-Api-Key"),
        ]
        storage = InMemorySecureTokenStorage(initial: Dictionary(
            (kept + orphans).map { ($0, "v") }, uniquingKeysWith: { first, _ in first }))
        storage.storeCorruptEntry(forKey: gone.secretKey(forHeader: "X-Corrupt"))
        store = MCPSecretStore(storage: storage)

        let selected = try store.orphanedAccounts(readBy: [enabled, disabled])

        XCTAssertEqual(Set(selected), Set(orphans + [gone.secretKey(forHeader: "X-Corrupt")]))
        XCTAssertEqual(store.clear(selected), 0)
        XCTAssertEqual(try storage.accountNames(withPrefix: ""), kept.sorted())
    }

    /// A Keychain that will not list selects nothing, and says so: nothing is deleted from a
    /// list nobody could read.
    func testASweepTheKeychainWillNotListSelectsNothing() throws {
        let orphan = try server(url: "https://a.test/mcp", authorization: .staticBearer)
        try storage.setToken("v", forKey: orphan.bearerSecretKey)
        storage.readError = .unhandled(-25308)

        XCTAssertThrowsError(try store.orphanedAccounts(readBy: []))
        storage.readError = nil
        XCTAssertEqual(try storage.loadToken(forKey: orphan.bearerSecretKey), "v")
    }

    /// Every account is tried; the refusals are counted, not thrown — a sweep is housekeeping,
    /// and what it could not delete it tries again next launch.
    func testClearingTriesEveryAccountAndCountsWhatTheKeychainRefused() throws {
        for key in ["A/x", "B/x", "C/x"] { try storage.setToken("v", forKey: key) }
        storage.writeFailure = { key, _ in key == "B/x" ? .unhandled(-25308) : nil }

        XCTAssertEqual(store.clear(["A/x", "B/x", "C/x"]), 1)
        storage.writeFailure = nil
        XCTAssertEqual(try storage.accountNames(withPrefix: ""), ["B/x"])
    }

    /// The production storage is scoped to its own Keychain service, so a schema break on
    /// either side cannot strand the other's entries.
    func testTheDefaultStorageIsScopedToTheMCPService() throws {
        let keychain = try XCTUnwrap(MCPSecretStore().storage as? KeychainSecureTokenStorage)
        XCTAssertEqual(keychain.service, MCPConstants.keychainService)
        XCTAssertNotEqual(keychain.service, KeychainSecureTokenStorage.defaultService)
    }
}
