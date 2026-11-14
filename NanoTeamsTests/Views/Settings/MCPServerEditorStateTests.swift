import XCTest
@testable import NanoTeams

/// The Add/Edit-server sheet's rules. Two of them are the client's first line of defence — a
/// colliding slug merges two servers' namespaces silently, and an address off loopback over
/// plain HTTP puts a credential on the wire — so they are pinned here rather than trusted to
/// a view.
final class MCPServerEditorStateTests: XCTestCase {

    private func existing(slug: String, id: UUID = UUID()) throws -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            slug: try XCTUnwrap(MCPServerSlug(slug)),
            displayName: slug,
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp")))
    }

    private func valid() -> MCPServerEditorState {
        var state = MCPServerEditorState()
        state.slugText = "folio"
        state.urlString = "http://127.0.0.1:3845/mcp"
        return state
    }

    // MARK: - Starting points

    /// A new server starts switched ON, untrusted and asking on every call. On, because
    /// connecting is what lists its tools for review, and a listed tool still reaches no prompt
    /// until a person approves it — the review is the admission gate, not the switch (decision
    /// of 2026-09-23). A blank draft is not something to save as-is.
    func testABlankDraftIsANewServerSwitchedOn() {
        let state = MCPServerEditorState()

        XCTAssertNil(state.serverID, "a blank draft is a NEW server")
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.isTrusted)
        XCTAssertEqual(state.approvalMode, .manual)
        XCTAssertEqual(state.authorization, .none)
        XCTAssertTrue(state.headers.isEmpty)
        XCTAssertEqual(state.problems(existing: []).first, .slugMissing)
        XCTAssertNil(state.makeConfig(existing: []))
    }

    /// The switch the draft opens with is the one the saved server carries: a valid blank draft
    /// is saved switched ON — the NEW-server branch of `makeConfig`, not only the draft's field.
    func testANewServerIsSavedSwitchedOn() throws {
        XCTAssertEqual(try XCTUnwrap(valid().makeConfig(existing: [])).isEnabled, true)
    }

    /// A new server's id is minted ONCE, with the draft: a Save the Keychain refused and a
    /// second press write under the same id, so the retry overwrites whatever the first attempt
    /// left instead of stranding it under an id no server will ever have. Two drafts are two
    /// servers.
    ///
    /// RED until the second review of group D (2026-09-24): every `makeConfig` minted a new id.
    func testANewServerKeepsOneIDAcrossSaveAttempts() throws {
        let draft = valid()
        let first = try XCTUnwrap(draft.makeConfig(existing: []))
        let second = try XCTUnwrap(draft.makeConfig(existing: []))

        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(try XCTUnwrap(valid().makeConfig(existing: [])).id, first.id)
        XCTAssertNil(draft.serverID, "still a NEW server — nothing is stored under the id yet")
    }

    func testEditingAServerKeepsItsIDAndItsHeaderNames() throws {
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            displayName: "Folio",
            transport: .http(MCPHTTPConfig(
                urlString: "http://127.0.0.1:3845/mcp",
                secretHeaderNames: ["X-Tenant"],
                authorization: .staticBearer)),
            isEnabled: true,
            isTrusted: true,
            approvalMode: .semiAutomatic)
        let state = MCPServerEditorState.from(config: config)

        XCTAssertEqual(state.serverID, config.id)
        XCTAssertEqual(state.headers.map(\.name), ["X-Tenant"])
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.isTrusted)
        XCTAssertEqual(state.approvalMode, .semiAutomatic)
    }

    /// The type never reads the Keychain, so an edited server's secret fields open empty.
    func testEditingAServerNeverCarriesASecret() throws {
        let state = MCPServerEditorState.from(config: try existing(slug: "folio"))

        XCTAssertEqual(state.bearerToken, "")
        XCTAssertTrue(state.headers.allSatisfy { $0.value.isEmpty })
    }

    // MARK: - The slug

    func testAMissingSlugIsNamedSeparatelyFromAMalformedOne() {
        var state = valid()
        state.slugText = "  "
        XCTAssertEqual(state.problems(existing: []), [.slugMissing])

        state.slugText = "Folio-Desktop"
        XCTAssertEqual(state.problems(existing: []), [.slugMalformed])
    }

    func testASlugAnotherServerHoldsIsRefused() throws {
        let state = valid()

        XCTAssertEqual(
            state.problems(existing: [try existing(slug: "folio")]),
            [.slugTaken("folio")])
    }

    /// Re-saving an unchanged server must not collide with itself.
    func testAServerDoesNotCollideWithItsOwnStoredSlug() throws {
        let stored = try existing(slug: "folio")
        let state = MCPServerEditorState.from(config: stored)

        XCTAssertTrue(state.problems(existing: [stored]).isEmpty)
    }

    // MARK: - The address

    func testTheAddressGoesThroughTheEndpointPolicy() {
        var state = valid()
        for rejected in ["http://example.com/mcp", "http://192.168.1.2/mcp", "https://u:p@x/mcp", "nonsense"] {
            state.urlString = rejected
            let problems = state.problems(existing: [])
            XCTAssertTrue(
                problems.contains { if case .urlRejected = $0 { return true } else { return false } },
                rejected)
        }
    }

    func testLoopbackOverPlainHTTPIsAccepted() {
        var state = valid()
        for accepted in ["http://127.0.0.1:3845/mcp", "http://localhost:3845/mcp", "https://example.com/mcp"] {
            state.urlString = accepted
            XCTAssertTrue(state.problems(existing: []).isEmpty, accepted)
        }
    }

    /// The rejection carries the policy's own sentence, which names the rule that fired —
    /// "invalid URL" would leave the person guessing which of six rules they broke.
    func testTheRejectionCarriesThePolicysOwnWording() {
        var state = valid()
        state.urlString = "http://example.com/mcp"

        guard case .urlRejected(let message)? = state.problems(existing: []).first else {
            return XCTFail("expected a URL problem")
        }
        XCTAssertEqual(message, MCPEndpointPolicy.Failure.plainHTTPOffLoopback(host: "example.com").message)
    }

    // MARK: - Headers

    func testAHeaderTheClientOwnsIsRefused() {
        var state = valid()
        state.headers = [.init(name: "Authorization", value: "x")]

        XCTAssertEqual(state.problems(existing: []), [.headerNameReserved("Authorization")])
    }

    func testAHeaderNameWithASpaceIsRefused() {
        var state = valid()
        state.headers = [.init(name: "X Tenant", value: "x")]

        XCTAssertEqual(state.problems(existing: []), [.headerNameMalformed("X Tenant")])
    }

    /// Case-insensitively, because HTTP is — two rows differing only in case would race to
    /// own one Keychain account.
    func testTheSameHeaderTwiceIsRefusedRegardlessOfCase() {
        var state = valid()
        state.headers = [.init(name: "X-Tenant", value: "a"), .init(name: "x-tenant", value: "b")]

        XCTAssertEqual(state.problems(existing: []), [.headerNameRepeated("x-tenant")])
    }

    /// A blank row is what an empty "add header" looks like mid-edit, not a mistake.
    func testABlankHeaderRowIsIgnored() {
        var state = valid()
        state.headers = [.init(name: "  ", value: "")]

        XCTAssertTrue(state.problems(existing: []).isEmpty)
        XCTAssertEqual(state.makeConfig(existing: [])?.transport.http.secretHeaderNames, [])
    }

    // MARK: - The token

    func testBearerAuthenticationWithNoTokenIsRefusedWhenOneIsRequired() {
        var state = valid()
        state.authorization = .staticBearer

        XCTAssertEqual(state.problems(existing: []), [.bearerMissing])
    }

    /// On an EDIT the field opens blank because the type never reads the Keychain, so a blank
    /// must mean "leave the stored token alone" rather than block the save.
    func testAnEditMaySaveWithTheTokenFieldLeftBlank() throws {
        let stored = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp", authorization: .staticBearer)))
        let state = MCPServerEditorState.from(config: stored, storedSecretKeys: [stored.bearerSecretKey])

        XCTAssertTrue(state.problems(existing: [stored]).isEmpty)
    }

    // MARK: - What gets written

    func testTheConfigCarriesHeaderNamesAndNoValues() throws {
        var state = valid()
        state.headers = [.init(name: "X-Tenant", value: "super-secret")]
        let config = try XCTUnwrap(state.makeConfig(existing: []))

        XCTAssertEqual(config.transport.http.secretHeaderNames, ["X-Tenant"])
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(encoded.contains("super-secret"), encoded)
    }

    func testAnInvalidDraftProducesNoConfig() {
        var state = valid()
        state.slugText = "NOPE"

        XCTAssertNil(state.makeConfig(existing: []))
    }

    /// The edit carries what was typed, per row and trimmed, and each row's original name —
    /// the plan keys the Keychain from it the way `MCPServerConfig` spells its accounts.
    func testTheSecretEditCarriesWhatWasTyped() throws {
        var state = valid()
        state.authorization = .staticBearer
        state.bearerToken = "  t  "
        state.headers = [.init(name: " X-Tenant ", value: "v"), .init(name: "  ", value: "ignored")]
        let config = try XCTUnwrap(state.makeConfig(existing: []))

        XCTAssertEqual(state.secretEdit, MCPServerSecretEdit(
            bearer: "t", headers: [.init(name: "X-Tenant", value: "v")]))
        XCTAssertEqual(MCPSecretChangePlan.make(stored: nil, saved: config, edit: state.secretEdit).steps, [
            .write(key: config.bearerSecretKey, value: "t"),
            .write(key: config.secretKey(forHeader: "X-Tenant"), value: "v"),
        ])
    }

    /// A field left blank writes nothing, so reopening a sheet and pressing Save cannot wipe
    /// a token the user cannot see.
    func testABlankSecretIsNotWritten() throws {
        let stored = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: "https://example.com/mcp", authorization: .staticBearer)))
        let state = MCPServerEditorState.from(config: stored, storedSecretKeys: [stored.bearerSecretKey])
        let config = try XCTUnwrap(state.makeConfig(existing: [stored]))

        XCTAssertTrue(MCPSecretChangePlan.make(stored: stored, saved: config, edit: state.secretEdit).steps.isEmpty)
    }

    /// Switching authentication back to None must not write the bearer that is still sitting
    /// in the field — the saved server does not send one.
    func testSwitchingAuthenticationOffStopsWritingTheBearer() throws {
        var state = valid()
        state.authorization = .none
        state.bearerToken = "left over"
        let config = try XCTUnwrap(state.makeConfig(existing: []))

        XCTAssertTrue(MCPSecretChangePlan.make(stored: nil, saved: config, edit: state.secretEdit).steps.isEmpty)
    }

    // MARK: - An edit keeps what the sheet does not show (F43)

    /// The sheet owns the name, the address, the authentication, the switches and the mode.
    /// Everything else on the config — the per-server timeouts, the plain headers — is carried
    /// through an edit untouched rather than reset to defaults.
    func testEditRoundTripPreservesTimeoutsAndPlainHeaders() throws {
        let slow = MCPTimeouts(connect: 30, requestInactivity: 600, requestAbsolute: 1800)
        let stored = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")),
            displayName: "Folio",
            transport: .http(MCPHTTPConfig(
                urlString: "https://example.com/mcp",
                headers: ["X-Tenant": "acme"],
                secretHeaderNames: ["X-Api-Key"])),
            timeouts: slow)
        var state = MCPServerEditorState.from(
            config: stored, storedSecretKeys: [stored.secretKey(forHeader: "X-Api-Key")])
        state.displayName = "Folio (renamed)"
        state.isEnabled = true

        let saved = try XCTUnwrap(state.makeConfig(existing: [stored]))
        XCTAssertEqual(saved.timeouts, slow)
        XCTAssertEqual(saved.transport.http.headers, ["X-Tenant": "acme"])
        XCTAssertEqual(saved.displayName, "Folio (renamed)")
        XCTAssertEqual(saved.id, stored.id)
        XCTAssertTrue(saved.isEnabled)
    }

    // MARK: - Problems show once there is something to show them about (F49, F56)

    /// A blank Add sheet does not greet the person with errors for fields they have not
    /// touched, and neither does an Edit sheet on open. Editing any field, or pressing Save,
    /// reveals them.
    func testProblemsStayHiddenUntilAnEditOrASaveAttempt() throws {
        var blank = MCPServerEditorState()
        XCTAssertFalse(blank.problems(existing: []).isEmpty, "the draft does have problems")
        XCTAssertFalse(blank.revealsProblems)
        blank.slugText = ""
        blank.headers = []
        XCTAssertFalse(blank.revealsProblems, "a field written back unchanged — a focus leaving it — is not an edit")
        blank.slugText = "f"
        XCTAssertTrue(blank.revealsProblems, "an edited field reveals them")

        var untouched = MCPServerEditorState()
        untouched.noteSaveAttempt()
        XCTAssertTrue(untouched.revealsProblems, "a Save press reveals them")

        var opened = MCPServerEditorState.from(config: try existing(slug: "folio"))
        XCTAssertFalse(opened.revealsProblems, "opening an existing server is not an edit")
        opened.headers.append(.init())
        XCTAssertTrue(opened.revealsProblems, "adding a row is")
    }

    /// A repeated problem keeps its FIRST place: the banner reads in the order a person fixes
    /// the rows, so a problem found again later does not move down the list.
    func testAProblemFoundAgainKeepsItsFirstPlace() {
        var state = valid()
        state.headers = [
            .init(name: "Accept", value: "a"), .init(name: "X-T", value: "v"),
            .init(name: "X-T", value: "v"), .init(name: "Accept", value: "b"),
        ]

        XCTAssertEqual(state.problems(existing: []), [.headerNameReserved("Accept"), .headerNameRepeated("X-T")])
    }

    /// Three rows with one name are one problem, listed once, in the order found — equal
    /// values would give the banner's rows duplicate identities (#22).
    func testProblemsAreUnique() {
        var state = valid()
        state.headers = [
            .init(name: "X-Tenant", value: "a"), .init(name: "X-Tenant", value: "b"),
            .init(name: "X-Tenant", value: "c"), .init(name: "Accept", value: "d"),
            .init(name: "Accept", value: "e"),
        ]

        let problems = state.problems(existing: [])
        XCTAssertEqual(problems, [.headerNameRepeated("X-Tenant"), .headerNameReserved("Accept")])
        XCTAssertEqual(problems.count, Set(problems).count)
    }

    // MARK: - Which secrets an edit must be given (F42, F22)

    private func stored(
        url: String = "https://example.com/mcp",
        headers: [String] = [],
        authorization: MCPAuthorizationMode = .none
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "Folio",
            transport: .http(MCPHTTPConfig(urlString: url, secretHeaderNames: headers, authorization: authorization)))
    }

    /// A stored header whose Keychain value is MISSING has nothing to keep, so a blank value is
    /// refused — the placeholder already said "Value", and the requirement now says the same
    /// thing: one predicate decides both (`keepsStoredValue`).
    ///
    /// RED until the second review of group D (2026-09-24): a row the stored server had could
    /// always be saved blank, and the server went on sending no header and reading 401.
    func testAStoredHeaderWhoseValueIsMissingNeedsOne() throws {
        let config = try stored(headers: ["X-Api-Key", "X-Tenant"])
        var state = MCPServerEditorState.from(config: config, storedSecretKeys: [config.secretKey(forHeader: "X-Tenant")])

        XCTAssertEqual(state.problems(existing: [config]), [.headerValueMissing("X-Api-Key")])
        for header in state.headers {
            let refused = state.problems(existing: [config]).contains(.headerValueMissing(header.name))
            XCTAssertEqual(state.valuePlaceholder(for: header) == "Leave blank to keep", !refused, header.name)
        }
        state.headers[0].value = "k.SECRET"
        XCTAssertTrue(state.problems(existing: [config]).isEmpty)
    }

    /// The same for the token: a Bearer server whose Keychain entry is missing (deleted, or
    /// unreadable) must be given one — "Leave blank to keep" is never offered for nothing.
    ///
    /// RED until the second review of group D (2026-09-24).
    func testAStoredTokenThatIsMissingIsRequired() throws {
        let config = try stored(authorization: .staticBearer)
        var state = MCPServerEditorState.from(config: config)

        XCTAssertEqual(state.bearerPlaceholder, "Paste the token")
        XCTAssertEqual(state.problems(existing: [config]), [.bearerMissing])
        state.bearerToken = "t.SECRET"
        XCTAssertTrue(state.problems(existing: [config]).isEmpty)
    }

    /// A stored header whose field holds only spaces is left blank: it keeps the stored value
    /// — the edit carries an EMPTY value and the plan changes nothing — rather than writing
    /// whitespace the Keychain reads as a delete.
    func testAStoredHeaderLeftAsSpacesKeepsItsValue() throws {
        let config = try stored(headers: ["X-Api-Key"])
        var state = MCPServerEditorState.from(config: config, storedSecretKeys: [config.secretKey(forHeader: "X-Api-Key")])
        state.headers[0].value = "   "
        let saved = try XCTUnwrap(state.makeConfig(existing: [config]))

        XCTAssertEqual(state.secretEdit.headers.map(\.value), [""])
        XCTAssertTrue(MCPSecretChangePlan.make(stored: config, saved: saved, edit: state.secretEdit).steps.isEmpty)
    }

    /// A row added in this edit has nothing stored to keep, so it needs a value.
    func testANewHeaderRowNeedsAValue() throws {
        let config = try stored(headers: ["X-Api-Key"])
        var state = MCPServerEditorState.from(config: config, storedSecretKeys: [config.secretKey(forHeader: "X-Api-Key")])
        state.headers.append(.init(name: "X-Tenant"))

        XCTAssertEqual(state.problems(existing: [config]), [.headerValueMissing("X-Tenant")])
        state.headers[1].value = "acme"
        XCTAssertTrue(state.problems(existing: [config]).isEmpty)
    }

    func testANewServersHeaderNeedsAValue() {
        var state = valid()
        state.headers = [.init(name: "X-Api-Key")]

        XCTAssertEqual(state.problems(existing: []), [.headerValueMissing("X-Api-Key")])
    }

    /// No authentication → Bearer on an edit: there is no stored token to keep, so a blank
    /// field is refused rather than saved as "Needs a token" under a "leave blank" promise.
    func testTheTokenIsRequiredWhenTheStoredServerDidNotUseOne() throws {
        let config = try stored(authorization: .none)
        var state = MCPServerEditorState.from(config: config)
        state.authorization = .staticBearer

        XCTAssertEqual(state.problems(existing: [config]), [.bearerMissing])
        XCTAssertEqual(state.bearerPlaceholder, "Paste the token")
    }

    /// "Leave blank to keep" is offered only where there is something stored to keep.
    func testLeaveBlankToKeepIsOfferedOnlyForAStoredValue() throws {
        let config = try stored(headers: ["X-Api-Key", "X-Tenant"], authorization: .staticBearer)
        let state = MCPServerEditorState.from(config: config, storedSecretKeys: [
            config.bearerSecretKey, config.secretKey(forHeader: "X-Api-Key"),
        ])

        XCTAssertEqual(state.bearerPlaceholder, "Leave blank to keep the stored token")
        XCTAssertEqual(state.valuePlaceholder(for: state.headers[0]), "Leave blank to keep")
        XCTAssertEqual(state.valuePlaceholder(for: state.headers[1]), "Value", "nothing stored under X-Tenant")

        let empty = MCPServerEditorState.from(config: config)
        XCTAssertEqual(empty.bearerPlaceholder, "Paste the token")
    }

    /// A renamed row keeps the value stored under its ORIGINAL name — the save moves it.
    func testARenamedRowStillOffersToKeepItsValue() throws {
        let config = try stored(headers: ["X-Api-Key"])
        var state = MCPServerEditorState.from(config: config, storedSecretKeys: [config.secretKey(forHeader: "X-Api-Key")])
        state.headers[0].name = "X-API-Key"

        XCTAssertEqual(state.valuePlaceholder(for: state.headers[0]), "Leave blank to keep")
        XCTAssertTrue(state.problems(existing: [config]).isEmpty)
        XCTAssertEqual(state.secretEdit.headers, [.init(name: "X-API-Key", originalName: "X-Api-Key")])
    }

    /// A new host is a different server: the token and every header value must be typed again,
    /// and nothing offers to keep what the old host was given.
    func testRepointingRequiresTheTokenAndEveryHeaderValueAgain() throws {
        let config = try stored(headers: ["X-Api-Key"], authorization: .staticBearer)
        var state = MCPServerEditorState.from(config: config, storedSecretKeys: Set(config.allSecretKeys))
        XCTAssertFalse(state.isRepointing)

        state.urlString = "https://mcp.other.example/mcp"
        XCTAssertTrue(state.isRepointing)
        XCTAssertEqual(state.problems(existing: [config]), [.headerValueMissing("X-Api-Key"), .bearerMissing])
        XCTAssertEqual(state.bearerPlaceholder, "Paste the token")
        XCTAssertEqual(state.valuePlaceholder(for: state.headers[0]), "Value")

        state.urlString = "https://example.com/other/path"
        XCTAssertFalse(state.isRepointing, "a new path on the same host is the same server")
        XCTAssertTrue(state.problems(existing: [config]).isEmpty)
    }

    // MARK: - A secret too short to scrub (from group B)

    /// A tool's result is scrubbed of this server's secrets only when a value is long enough to
    /// be one (`MCPRedaction.Credentials.Literals.minimumBytes`); the editor says so under a
    /// shorter one. Counted in UTF-8 bytes, after trimming, as the scrub counts them.
    func testAValueTooShortToBeScrubbedIsFlagged() {
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact(""), "nothing typed, nothing to warn about")
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact("   "))
        XCTAssertTrue(MCPServerEditorState.isTooShortToRedact("1234567"))
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact("12345678"))
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact("  12345678  "))
        XCTAssertTrue(MCPServerEditorState.isTooShortToRedact(" 1234567 "), "trimmed first")
        XCTAssertTrue(MCPServerEditorState.isTooShortToRedact("ééé"), "six bytes")
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact("éééé"), "eight bytes")
        let boundary = String(repeating: "a", count: MCPRedaction.Credentials.Literals.minimumBytes)
        XCTAssertFalse(MCPServerEditorState.isTooShortToRedact(boundary))
        XCTAssertTrue(MCPServerEditorState.isTooShortToRedact(String(boundary.dropLast())))
    }

    /// Which fields carry the warning is the state's answer, read one-to-one by the sheet: the
    /// token only while it is on screen (Bearer), each header row on its own value.
    func testTheShortSecretWarningShowsUnderEachShortFieldAndNoOther() {
        var state = valid()
        state.bearerToken = "short"
        XCTAssertFalse(state.showsShortTokenWarning, "no token field under No authentication")
        state.authorization = .staticBearer
        XCTAssertTrue(state.showsShortTokenWarning)
        state.bearerToken = "long-enough-token"
        XCTAssertFalse(state.showsShortTokenWarning)

        state.headers = [.init(name: "X-Short", value: "abc"), .init(name: "X-Long", value: "abcdefghij"),
                         .init(name: "X-Blank", value: "")]
        XCTAssertEqual(state.headers.map(state.showsShortValueWarning(for:)), [true, false, false])
    }

    /// The trust switch is greyed out — not cleared — under a mode that ignores the mark, and
    /// the caption under it names the modes that read it; neither shows under one that does.
    func testTheTrustSwitchIsEditableOnlyUnderAModeThatReadsIt() {
        var state = valid()
        state.isTrusted = true
        for mode in MCPApprovalMode.allCases {
            state.approvalMode = mode
            XCTAssertEqual(state.isTrustMarkEditable, mode.readsTrustMark, "\(mode)")
            XCTAssertEqual(state.trustMarkCaption, mode.readsTrustMark ? nil : MCPApprovalMode.trustMarkCaption, "\(mode)")
            XCTAssertTrue(state.isTrusted, "the stored mark is kept under every mode")
        }
        state.approvalMode = .manual
        XCTAssertFalse(state.isTrustMarkEditable)
        XCTAssertNotNil(state.trustMarkCaption)
    }

    /// The warning states the consequence, not the constant — "8" means nothing to a person
    /// who pasted a key.
    func testTheShortSecretWarningStatesTheConsequence() {
        let warning = MCPServerEditorState.shortSecretWarning
        XCTAssertTrue(warning.contains("tool results"), warning)
        XCTAssertFalse(warning.contains("\(MCPRedaction.Credentials.Literals.minimumBytes)"), warning)
    }

    /// Judge strictness defaults to `.standard`, round-trips through `from(config:)` and
    /// `makeConfig(existing:)`, and `showsJudgeControls` is true only when `approvalMode == .auto`.
    func testJudgeStrictnessDefaultsToStandardRoundTripsAndShowsControlsOnlyUnderAuto() throws {
        var state = valid()
        XCTAssertEqual(state.judgeStrictness, .standard)
        for mode in MCPApprovalMode.allCases {
            state.approvalMode = mode
            XCTAssertEqual(state.showsJudgeControls, mode == .auto, "\(mode)")
        }

        for strictness in MCPJudgeStrictness.allCases {
            state.approvalMode = .auto
            state.judgeStrictness = strictness
            let saved = try XCTUnwrap(state.makeConfig(existing: []))
            XCTAssertEqual(saved.approvalMode, .auto)
            XCTAssertEqual(saved.judgeStrictness, strictness)

            let reloaded = MCPServerEditorState.from(config: saved)
            XCTAssertEqual(reloaded.approvalMode, .auto)
            XCTAssertEqual(reloaded.judgeStrictness, strictness)
            XCTAssertTrue(reloaded.showsJudgeControls)
        }
    }
}
