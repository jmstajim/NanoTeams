import XCTest

@testable import NanoTeams

/// Which Keychain accounts a save writes, moves and clears. Every orphan the review found
/// (F42, F28) and the re-point (F22) is a row here: a credential the list no longer names is
/// one nothing in the UI can ever reach again, and a credential kept across a change of host
/// is one sent to a server it was never entered for.
final class MCPSecretChangePlanTests: XCTestCase {

    private let id = UUID()

    private func config(
        url: String = "https://mcp.example.com/mcp",
        headers: [String] = [],
        authorization: MCPAuthorizationMode = .none
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade Room",
            transport: .http(MCPHTTPConfig(
                urlString: url, secretHeaderNames: headers, authorization: authorization)))
    }

    private func deletes(_ plan: MCPSecretChangePlan) -> Set<String> {
        Set(plan.steps.compactMap { if case .delete(let key) = $0 { return key } else { return nil } })
    }

    private func writes(_ plan: MCPSecretChangePlan) -> [String: String] {
        var out: [String: String] = [:]
        for step in plan.steps { if case .write(let key, let value) = step { out[key] = value } }
        return out
    }

    private func moves(_ plan: MCPSecretChangePlan) -> [String: String] {
        var out: [String: String] = [:]
        for step in plan.steps { if case .move(let from, let to) = step { out[from] = to } }
        return out
    }

    // MARK: - Creating

    /// A new server has nothing stored: the plan writes what was typed and clears nothing.
    func testCreatingWritesOnlyWhatWasTyped() throws {
        let saved = try config(headers: ["X-Api-Key"], authorization: .staticBearer)
        let plan = MCPSecretChangePlan.make(stored: nil, saved: saved, edit: MCPServerSecretEdit(
            bearer: "  t.SECRET  ", headers: [.init(name: "X-Api-Key", value: "k.SECRET")]))

        XCTAssertEqual(writes(plan), [
            saved.bearerSecretKey: "t.SECRET",
            saved.secretKey(forHeader: "X-Api-Key"): "k.SECRET",
        ])
        XCTAssertTrue(deletes(plan).isEmpty)
        XCTAssertTrue(moves(plan).isEmpty)
        XCTAssertFalse(plan.isRepoint)
    }

    // MARK: - What an edit drops

    /// Bearer → No authentication: the token the server no longer sends is cleared, not left
    /// in the Keychain where nothing can see it (F42 scenario 1, F28(2)).
    func testSwitchingTheBearerOffClearsTheStoredToken() throws {
        let stored = try config(authorization: .staticBearer)
        let saved = try config(authorization: .none)
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit())

        XCTAssertEqual(deletes(plan), [stored.bearerSecretKey])
        XCTAssertTrue(writes(plan).isEmpty)
    }

    /// A server that reads no secret — No authentication, no secret header — is saved without
    /// the Keychain: no step, so no account is read or written, and a locked Keychain cannot
    /// refuse the save of a server that uses none. A bearer left in its account by an earlier
    /// mode is not swept here: it is never sent (the bearer goes out only under Bearer), and a
    /// removal or a re-point clears it with everything else under the server's prefix.
    ///
    /// RED until the second review of group D (2026-09-24): every save of such a server
    /// deleted, and so first READ, its bearer account.
    func testASaveOfAServerThatReadsNoSecretTouchesNoAccount() throws {
        let stored = try config(authorization: .none)
        var saved = stored
        saved.isEnabled.toggle()
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit())

        XCTAssertTrue(plan.steps.isEmpty, "\(plan.steps)")
        XCTAssertTrue(plan.touchedKeys.isEmpty)
    }

    /// What a save clears is what the stored server READ and the saved one no longer reads —
    /// never an account neither of them reads.
    func testASaveClearsOnlyWhatTheStoredServerReadAndTheSavedOneDoesNot() throws {
        let stored = try config(headers: ["X-A", "X-B"])
        let saved = try config(headers: ["X-B"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
            headers: [.init(name: "X-B", originalName: "X-B")]))

        XCTAssertEqual(deletes(plan), [stored.secretKey(forHeader: "X-A")], "the leftover bearer is not touched")
    }

    func testARemovedHeaderRowClearsItsKey() throws {
        let stored = try config(headers: ["X-Api-Key", "X-Tenant"])
        let saved = try config(headers: ["X-Tenant"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
            headers: [.init(name: "X-Tenant", originalName: "X-Tenant")]))

        XCTAssertTrue(deletes(plan).contains(stored.secretKey(forHeader: "X-Api-Key")))
        XCTAssertFalse(deletes(plan).contains(stored.secretKey(forHeader: "X-Tenant")))
    }

    /// A header's secret is keyed by its name, so a rename left blank MOVES the stored value to
    /// the new key and clears the old one (F42 scenario 2).
    func testARenamedHeaderLeftBlankMovesItsValue() throws {
        let stored = try config(headers: ["X-Api-Key"])
        let saved = try config(headers: ["X-API-Key"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
            headers: [.init(name: "X-API-Key", originalName: "X-Api-Key")]))

        XCTAssertEqual(moves(plan), [
            stored.secretKey(forHeader: "X-Api-Key"): saved.secretKey(forHeader: "X-API-Key"),
        ])
        XCTAssertTrue(deletes(plan).contains(stored.secretKey(forHeader: "X-Api-Key")))
        XCTAssertTrue(writes(plan).isEmpty)
    }

    /// A rename with a new value typed writes the new value; the old key is cleared, never
    /// copied over it.
    func testARenamedHeaderWithAValueTypedWritesItAndMovesNothing() throws {
        let stored = try config(headers: ["X-Api-Key"])
        let saved = try config(headers: ["X-Key"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
            headers: [.init(name: "X-Key", originalName: "X-Api-Key", value: "new")]))

        XCTAssertEqual(writes(plan), [saved.secretKey(forHeader: "X-Key"): "new"])
        XCTAssertTrue(moves(plan).isEmpty)
        XCTAssertTrue(deletes(plan).contains(stored.secretKey(forHeader: "X-Api-Key")))
    }

    /// Two rows that swap names each carry their OWN value: the moves read what the save
    /// started with, and neither key is cleared, because the saved server still names both.
    func testTwoHeadersThatSwapNamesEachKeepTheirValue() throws {
        let stored = try config(headers: ["X-A", "X-B"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: stored, edit: MCPServerSecretEdit(headers: [
            .init(name: "X-B", originalName: "X-A"),
            .init(name: "X-A", originalName: "X-B"),
        ]))

        XCTAssertEqual(moves(plan), [
            stored.secretKey(forHeader: "X-A"): stored.secretKey(forHeader: "X-B"),
            stored.secretKey(forHeader: "X-B"): stored.secretKey(forHeader: "X-A"),
        ])
        XCTAssertFalse(deletes(plan).contains(stored.secretKey(forHeader: "X-A")))
        XCTAssertFalse(deletes(plan).contains(stored.secretKey(forHeader: "X-B")))
    }

    /// A row that is new to this server — or a bearer the stored server did not use — keeps
    /// nothing: whatever its account holds is left from some earlier configuration, so a blank
    /// clears it rather than sending it.
    func testANewRowOrANewBearerLeftBlankClearsWhateverItsAccountHeld() throws {
        let stored = try config(headers: ["X-Old"], authorization: .none)
        let saved = try config(headers: ["X-Old", "X-New"], authorization: .staticBearer)
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(headers: [
            .init(name: "X-Old", originalName: "X-Old"),
            .init(name: "X-New"),
        ]))

        XCTAssertEqual(deletes(plan), [saved.secretKey(forHeader: "X-New"), saved.bearerSecretKey])
        XCTAssertTrue(writes(plan).isEmpty)
        XCTAssertTrue(moves(plan).isEmpty)
    }

    /// An untouched edit writes nothing and moves nothing: reopening the sheet and pressing Save
    /// must not wipe a secret the person cannot see. Both shapes of "nothing typed" — the
    /// editor's (every row present, blank, under its own name) and the empty edit a save with
    /// no editor behind it passes (no row at all) — keep every stored secret.
    func testAnUntouchedEditWritesAndMovesNothing() throws {
        let stored = try config(headers: ["X-Api-Key", "X-Tenant"], authorization: .staticBearer)
        let editor = MCPServerSecretEdit(headers: [
            .init(name: "X-Api-Key", originalName: "X-Api-Key"),
            .init(name: "X-Tenant", originalName: "X-Tenant"),
        ])

        for edit in [editor, MCPServerSecretEdit()] {
            let plan = MCPSecretChangePlan.make(stored: stored, saved: stored, edit: edit)
            XCTAssertTrue(plan.steps.isEmpty, "\(edit) changed \(plan.steps)")
        }
    }

    // MARK: - A different server (F22)

    /// A new host is a different server: every account the server holds is cleared FIRST —
    /// every one the Keychain lists under its prefix, and every one either config reads — then
    /// what was typed is written. Nothing moves: a value entered for one host is not the other's.
    func testRepointingClearsEveryStoredKeyBeforeWritingTheNewOnes() throws {
        let stored = try config(headers: ["X-Api-Key"], authorization: .staticBearer)
        let saved = try config(url: "https://other.example.net/mcp", headers: ["X-Api-Key"], authorization: .staticBearer)
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
            bearer: "new-host-token",
            headers: [.init(name: "X-Api-Key", originalName: "X-Api-Key")]),
            held: [stored.bearerSecretKey, stored.secretKey(forHeader: "X-Api-Key")])

        XCTAssertTrue(plan.isRepoint)
        XCTAssertEqual(deletes(plan), Set(stored.allSecretKeys).union(saved.allSecretKeys))
        XCTAssertEqual(writes(plan), [saved.bearerSecretKey: "new-host-token"])
        XCTAssertTrue(moves(plan).isEmpty, "a header left blank is NOT carried to the new host")
        let lastDelete = try XCTUnwrap(plan.steps.lastIndex { if case .delete = $0 { true } else { false } })
        let firstWrite = try XCTUnwrap(plan.steps.firstIndex { if case .write = $0 { true } else { false } })
        XCTAssertLessThan(lastDelete, firstWrite, "the old values are gone before a new one is written")
    }

    /// Scheme, host and port decide; a path, a host's letter case and a spelled-out default
    /// port do not. The scheme counts on its own: the same explicit port under the other scheme
    /// is another server, not only a default port that happens to differ.
    func testOnlyAnotherSchemeHostOrPortIsARepoint() throws {
        let stored = try config(url: "https://mcp.example.com/mcp")
        for same in ["https://MCP.Example.com/other/path", "https://mcp.example.com:443/mcp", " https://mcp.example.com/mcp "] {
            XCTAssertFalse(
                MCPSecretChangePlan.make(stored: stored, saved: try config(url: same), edit: .init()).isRepoint, same)
        }
        for other in ["http://mcp.example.com/mcp", "https://mcp.example.com:8443/mcp",
                      "https://evil.example.com/mcp", "https://mcp.example.com.evil.net/mcp",
                      "http://mcp.example.com:443/mcp"] {
            XCTAssertTrue(
                MCPSecretChangePlan.make(stored: stored, saved: try config(url: other), edit: .init()).isRepoint, other)
        }
        let explicit = try config(url: "https://mcp.example.com:8443/mcp")
        XCTAssertTrue(MCPSecretChangePlan.make(
            stored: explicit, saved: try config(url: "http://mcp.example.com:8443/mcp"), edit: .init()).isRepoint,
            "the same explicit port under another scheme")
    }

    /// A re-point clears what the Keychain LISTS under the server's prefix — an account no
    /// config names any more (a header renamed before 2026-09-24, a bearer from an earlier mode)
    /// included — and every account either config reads, a header the new address adds among
    /// them, left blank. Nothing of the old address's reaches the new one.
    ///
    /// RED until the second review of group D (2026-09-24): the purge read only the accounts the
    /// two configs named, and the orphan went on to the new host.
    func testARepointClearsEveryAccountUnderThePrefixAndEveryAccountEitherConfigReads() throws {
        let stored = try config(headers: ["X-Api-Key"], authorization: .none)
        let saved = try config(url: "https://other.example.net/mcp", headers: ["X-Api-Key", "X-New"])
        let orphan = stored.secretKey(forHeader: "X-Renamed-Long-Ago")
        let plan = MCPSecretChangePlan.make(
            stored: stored, saved: saved,
            edit: MCPServerSecretEdit(headers: [
                .init(name: "X-Api-Key", originalName: "X-Api-Key", value: "new-k"), .init(name: "X-New"),
            ]),
            held: [stored.bearerSecretKey, orphan, stored.secretKey(forHeader: "X-Api-Key")])

        XCTAssertEqual(deletes(plan), [
            stored.bearerSecretKey, orphan, stored.secretKey(forHeader: "X-Api-Key"),
            saved.secretKey(forHeader: "X-Api-Key"), saved.secretKey(forHeader: "X-New"),
        ])
        XCTAssertEqual(writes(plan), [saved.secretKey(forHeader: "X-Api-Key"): "new-k"])
        let lastDelete = try XCTUnwrap(plan.steps.lastIndex { if case .delete = $0 { true } else { false } })
        let firstWrite = try XCTUnwrap(plan.steps.firstIndex { if case .write = $0 { true } else { false } })
        XCTAssertLessThan(lastDelete, firstWrite)
    }

    /// A move carries a value within ONE origin: a renamed header left blank on the same server
    /// goes from its old name's account to its new name's, both under the address it was entered
    /// for; a re-point moves nothing, and every account it writes or clears on the saved side is
    /// under the new origin — so nothing it touches for the new address is one the old address
    /// reads.
    func testAMoveNeverCrossesAnOrigin() throws {
        let pairs = [("https://a.test/mcp", "https://A.test:443/v2"), ("https://a.test/mcp", "https://b.test/mcp"),
                     ("http://[::1]:3845/mcp", "http://[::1]:3846/mcp"), ("http://[::1]:3845/mcp", "http://[::1]:3845/v2")]
        for (from, to) in pairs {
            let stored = try config(url: from, headers: ["X-A"], authorization: .staticBearer)
            let saved = try config(url: to, headers: ["X-B"], authorization: .staticBearer)
            let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(
                bearer: "t", headers: [.init(name: "X-B", originalName: "X-A")]),
                held: stored.allSecretKeys)

            XCTAssertEqual(moves(plan).isEmpty, plan.isRepoint, "\(from) → \(to)")
            for (source, target) in moves(plan) {
                XCTAssertTrue(source.hasPrefix(stored.originAccountPrefix), "\(from) → \(to): \(source)")
                XCTAssertTrue(target.hasPrefix(saved.originAccountPrefix), "\(from) → \(to): \(target)")
                XCTAssertEqual(stored.originAccountPrefix, saved.originAccountPrefix, "\(from) → \(to)")
            }
            for key in writes(plan).keys {
                XCTAssertTrue(key.hasPrefix(saved.originAccountPrefix), "\(from) → \(to): \(key)")
                if plan.isRepoint {
                    XCTAssertFalse(stored.allSecretKeys.contains(key), "\(from) → \(to): wrote an account the old address reads")
                }
            }
        }
    }

    /// An address that names no server keeps its secrets only while it is spelled exactly as
    /// before — anything looser would hand a credential to an address nobody can place.
    func testAnUnreadableAddressIsTheSameServerOnlyWhenSpelledTheSame() {
        XCTAssertTrue(MCPHTTPConfig.reachSameServer("not a url", "not a url"))
        XCTAssertFalse(MCPHTTPConfig.reachSameServer("not a url", "also not"))
        XCTAssertFalse(MCPHTTPConfig.reachSameServer("https://a.test/mcp", "a.test/mcp"))
        XCTAssertNil(URLOrigin(""))
        XCTAssertEqual(URLOrigin("http://127.0.0.1/mcp")?.port, 80)
    }

    /// Every account a step touches, once — what the undo snapshot has to hold.
    func testTouchedKeysListEachAccountOnce() throws {
        let stored = try config(headers: ["X-A"])
        let saved = try config(headers: ["X-B"])
        let plan = MCPSecretChangePlan.make(stored: stored, saved: saved, edit: MCPServerSecretEdit(headers: [
            .init(name: "X-B", originalName: "X-A"),
        ]))

        XCTAssertEqual(plan.touchedKeys.count, Set(plan.touchedKeys).count)
        XCTAssertTrue(plan.touchedKeys.contains(stored.secretKey(forHeader: "X-A")))
        XCTAssertTrue(plan.touchedKeys.contains(saved.secretKey(forHeader: "X-B")))
    }
}
