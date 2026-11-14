import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// The Settings → MCP Servers surface: the row's one-line summary, the shared status styling,
/// and that each of the four views composes with real values.
///
/// The summary is the load-bearing part — it is the only place a person learns that a server
/// is off, or off in THIS folder, or missing the token it says it needs, before they click.
@MainActor
final class MCPServersSettingsViewTests: XCTestCase {

    private var banner: BannerRecorder!
    private var directory: URL?
    private var manager: MCPServerManager?
    private var window: NSWindow?
    private var cardWidth: WidthProbe!

    override func setUp() async throws {
        try await super.setUp()
        banner = BannerRecorder()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        cardWidth = nil
        rowProbe = nil
        recorder = nil
        LayoutProbe.record = nil
        await manager?.shutdown(budget: 0)
        manager = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        banner = nil
        try await super.tearDown()
    }

    private func config(
        slug: String = "folio",
        enabled: Bool = true,
        authorization: MCPAuthorizationMode = .none,
        trusted: Bool = false,
        mode: MCPApprovalMode = .manual
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug(slug)),
            displayName: "Folio Desktop",
            transport: .http(MCPHTTPConfig(
                urlString: "http://127.0.0.1:3845/mcp", authorization: authorization)),
            isEnabled: enabled,
            isTrusted: trusted,
            approvalMode: mode)
    }

    private func row(
        enabled: Bool = true,
        allowedHere: Bool = true,
        hasSecrets: Bool = true,
        status: MCPServerStatus = .connected(era: .modern),
        rereading: Bool = false,
        tools: MCPToolTally = MCPToolTally(approved: 2, new: 0, changed: 0, rejected: 0),
        nothingOffered: Bool = false,
        authorization: MCPAuthorizationMode = .none,
        trusted: Bool = false,
        mode: MCPApprovalMode = .manual
    ) throws -> MCPServerRow {
        MCPServerRow(
            config: try config(enabled: enabled, authorization: authorization, trusted: trusted, mode: mode),
            status: status,
            isAllowedInThisFolder: allowedHere,
            hasRequiredSecrets: hasSecrets,
            catalogueUnverified: rereading,
            tools: tools,
            nothingItPublishesCanBeOffered: nothingOffered)
    }

    // MARK: - The one line under the name

    /// The line a person scans the list with says what they have to act on: how many tools
    /// wait to be read — a rewrite of an approved tool among them — and how many are approved.
    /// The review count leads, because the one-line row truncates at its tail. The protocol
    /// revision is not in it: it read as a date, and it pushed the counts out of the row.
    ///
    /// RED until 2026-09-24: "Connected — 2026-07-28, 0 tools" for a server with five tools
    /// waiting to be read (F47).
    func testTheSubtitleNamesToolsAwaitingReview() throws {
        XCTAssertEqual(
            try row(tools: MCPToolTally(approved: 2, new: 2, changed: 1, rejected: 0)).subtitle,
            "Connected · 3 to review · 2 approved")
        XCTAssertEqual(
            try row(tools: MCPToolTally(approved: 0, new: 5, changed: 0, rejected: 0)).subtitle,
            "Connected · 5 to review · 0 approved")
    }

    /// Nothing to review says nothing about reviewing; a refused text is decided, not waiting;
    /// a server that publishes nothing says so.
    func testAQuietServerSaysOnlyWhatIsApproved() throws {
        XCTAssertEqual(try row().subtitle, "Connected · 2 approved")
        XCTAssertEqual(
            try row(tools: MCPToolTally(approved: 1, new: 0, changed: 0, rejected: 2)).subtitle,
            "Connected · 1 approved")
        XCTAssertEqual(try row(tools: .none).subtitle, "Connected · no tools")
        for era in MCPProtocolEra.allCases {
            XCTAssertFalse(try row(status: .connected(era: era)).subtitle.contains(era.displayName))
        }
    }

    /// A server that is not connected counts nothing: its tally describes no catalogue it
    /// serves.
    func testAServerThatIsNotConnectedClaimsNoCount() throws {
        let waiting = MCPToolTally(approved: 2, new: 3, changed: 0, rejected: 0)
        XCTAssertEqual(try row(status: .connecting, tools: waiting).subtitle, "Connecting…")
        XCTAssertEqual(try row(status: .failed(reason: "x"), tools: waiting).subtitle, "Not connected — retrying")
    }

    /// A rewrite of an approved tool waiting for a person is the one thing the list must not
    /// let pass unseen: the row's dot and the page's badge turn to the warning ink.
    func testARewriteWaitingForReviewTintsTheDotAndTheBadge() throws {
        let rewritten = try row(tools: MCPToolTally(approved: 1, new: 0, changed: 1, rejected: 0))
        XCTAssertEqual(MCPServerStatusStyle.dotColor(for: rewritten), Colors.warning)
        XCTAssertEqual(MCPServerStatusStyle.color(for: rewritten), Colors.warning)

        let onlyNew = try row(tools: MCPToolTally(approved: 1, new: 3, changed: 0, rejected: 0))
        XCTAssertEqual(MCPServerStatusStyle.color(for: onlyNew), Colors.success, "new tools are routine")
        let refusedRewrite = try row(tools: MCPToolTally(approved: 1, new: 0, changed: 0, rejected: 1))
        XCTAssertEqual(MCPServerStatusStyle.color(for: refusedRewrite), Colors.success, "a refused rewrite is decided")
        let off = try row(enabled: false, tools: MCPToolTally(approved: 1, new: 0, changed: 1, rejected: 0))
        XCTAssertEqual(MCPServerStatusStyle.dotColor(for: off), Colors.textTertiary, "nothing is attempted")
        let failing = try row(status: .failed(reason: "x"), tools: MCPToolTally(approved: 1, new: 0, changed: 1, rejected: 0))
        XCTAssertEqual(MCPServerStatusStyle.color(for: failing), Colors.error, "the connection speaks first")
        // A server re-reading its tool list claims no count in its subtitle, so its ink claims
        // no rewrite either: the status's own.
        let rereading = try row(rereading: true, tools: MCPToolTally(approved: 1, new: 0, changed: 1, rejected: 0))
        XCTAssertFalse(rereading.subtitle.contains("review"), "premise: the subtitle claims no count")
        XCTAssertEqual(MCPServerStatusStyle.color(for: rereading), Colors.success, "the ink agrees with the subtitle")
        XCTAssertEqual(MCPServerStatusStyle.dotColor(for: rereading), Colors.success)
    }

    /// The four reasons are ordered by what the person can act on first: a server switched off
    /// globally is not "not connected", and saying so would send them to the address field.
    /// Missing credentials block only a server that is not connected: a server that connected
    /// without its declared token ships its tools, so the subtitle and the grant catalogue agree.
    func testTheSubtitleNamesTheFirstThingToFix() throws {
        XCTAssertEqual(try row(enabled: false).subtitle, "Off")
        XCTAssertEqual(try row(allowedHere: false).subtitle, "Off in this folder")
        XCTAssertEqual(try row(hasSecrets: false, status: .connecting).subtitle, "Needs a token")
        XCTAssertEqual(
            try row(hasSecrets: false, status: .connected(era: .modern)).subtitle,
            "Connected · 2 approved",
            "a server that connected without its declared token reads as connected")
        XCTAssertEqual(
            MCPServerStanding.of(
                isSwitchedOn: true, isAllowedInThisFolder: true, hasRequiredSecrets: false,
                isShutDown: false, status: .connected(era: .modern)),
            .running(.connected(era: .modern)))
    }

    /// A connected server whose tool list is being read again after a listing failed: the
    /// line says so, and claims no count of approved tools — none of them ships until the read
    /// succeeds. The role editor's badge says the same, so the two surfaces agree.
    ///
    /// RED until 2026-09-24 (group C): the row said "Connected — …, 2 tools" while the badge
    /// said the server was not connected.
    func testAConnectedServerRereadingItsToolsSaysSoAndClaimsNoCount() throws {
        XCTAssertEqual(try row(rereading: true).subtitle, "Connected · re-reading its tool list")
        XCTAssertFalse(try row(rereading: true).subtitle.contains("approved"))
        // The switch and the token still come first; a row that is not connected says that.
        XCTAssertEqual(try row(enabled: false, rereading: true).subtitle, "Off")
        XCTAssertEqual(try row(hasSecrets: false, status: .connecting, rereading: true).subtitle, "Needs a token")
        XCTAssertEqual(try row(status: .connecting, rereading: true).subtitle, "Connecting…")
    }

    /// Globally off outranks folder-off: turning the folder switch on would change nothing.
    func testGloballyOffOutranksFolderOff() throws {
        XCTAssertEqual(try row(enabled: false, allowedHere: false).subtitle, "Off")
    }

    /// A shut-down manager — no work folder opened, or one that failed to open — reads every
    /// server `.disabled`. A server switched on and allowed then reads "Not running", as the
    /// page's own line says, never "Off" beside a power switch that is on. A server a person
    /// switched off still reads Off.
    ///
    /// RED until 2026-10-28: the badge said "‖ OFF" beside "Connect to this server [x]".
    func testAShutDownManagerReadsNotRunningBesideASwitchThatIsOn() throws {
        let idle = try row(status: .disabled, tools: .none)
        XCTAssertTrue(idle.isRunnable, "premise: switched on and allowed")
        XCTAssertEqual(idle.subtitle, "Not running")
        XCTAssertEqual(try row(enabled: false, status: .disabled).subtitle, "Off")
        XCTAssertEqual(try row(allowedHere: false, status: .disabled).subtitle, "Off in this folder")
        XCTAssertEqual(try row(hasSecrets: false, status: .disabled).subtitle, "Needs a token",
                       "the token still comes first")
        XCTAssertEqual(
            presentation(try row(status: .disabled), hasConnection: false).emptyToolsText,
            "Not running — it starts when a work folder opens.",
            "the page's own line says the same")
    }

    /// A server that published tools of which roles can be offered none — its listing collided,
    /// or the app could not read one entry of it — is not a server that publishes nothing:
    /// the list says "none offered", the page's empty line points down at the reason. A server
    /// that really publishes nothing still says so. `MCPServerManagerTests` drives both causes
    /// through a real connection.
    ///
    /// RED until 2026-10-28: "Connected · no tools", and "The server publishes no tools." under
    /// the red collision message.
    func testAServerWhoseToolsCannotBeOfferedSaysSoRatherThanNoTools() throws {
        let unofferable = try row(tools: .none, nothingOffered: true)
        XCTAssertEqual(unofferable.subtitle, "Connected · none offered")
        XCTAssertEqual(presentation(unofferable).emptyToolsText, "None of what it publishes can be offered — see below.")

        let empty = try row(tools: .none)
        XCTAssertEqual(empty.subtitle, "Connected · no tools")
        XCTAssertEqual(presentation(empty).emptyToolsText, "The server publishes no tools.")

        // What comes first still comes first: the switches, the token, a re-read, a status.
        XCTAssertEqual(try row(enabled: false, tools: .none, nothingOffered: true).subtitle, "Off")
        XCTAssertEqual(try row(rereading: true, tools: .none, nothingOffered: true).subtitle,
                       "Connected · re-reading its tool list")
        XCTAssertEqual(
            presentation(try row(enabled: false, status: .disabled, tools: .none, nothingOffered: true)).emptyToolsText,
            "Turn on Connect to this server to see what it offers.")
    }

    func testRunnableMeansOnEverywhereNotConnected() throws {
        XCTAssertTrue(try row(status: .failed(reason: "refused")).isRunnable)
        XCTAssertFalse(try row(enabled: false).isRunnable)
        XCTAssertFalse(try row(allowedHere: false).isRunnable)
    }

    // MARK: - Status styling

    /// One switch, two readers. A list that says "connected" beside a detail pane that says
    /// "refused" is worse than either, so the mapping lives in one place.
    func testEveryStatusHasItsOwnGlyphAndInk() {
        XCTAssertEqual(
            MCPServerStatusStyle.glyph(for: .connected(era: .legacy)),
            TerminalGlyph.done)
        XCTAssertEqual(MCPServerStatusStyle.glyph(for: .connecting), TerminalGlyph.working)
        XCTAssertEqual(MCPServerStatusStyle.glyph(for: .disabled), TerminalGlyph.paused)
        XCTAssertEqual(
            MCPServerStatusStyle.glyph(for: .failed(reason: "x")), TerminalGlyph.failed)

        XCTAssertEqual(MCPServerStatusStyle.color(for: .failed(reason: "x")), Colors.error)
        XCTAssertEqual(MCPServerStatusStyle.color(for: .needsAuth(reason: "401")), Colors.warning)
        XCTAssertEqual(
            MCPServerStatusStyle.color(for: .unsupportedTransport(reason: "plain http")),
            Colors.warning,
            "an address this client refuses never reached the server — not the server's failure")
    }

    /// A server nothing is attempting reads dim, whatever its last status was.
    func testTheDotIsDimWheneverNothingIsBeingAttempted() throws {
        XCTAssertEqual(
            MCPServerStatusStyle.dotColor(for: try row(enabled: false)), Colors.textTertiary)
        XCTAssertEqual(
            MCPServerStatusStyle.dotColor(for: try row(allowedHere: false)), Colors.textTertiary)
        XCTAssertEqual(MCPServerStatusStyle.dotColor(for: try row()), Colors.success)
    }

    // MARK: - The views compose

    func testTheTabIsNamedExactlyAsEveryHintSpellsIt() {
        XCTAssertEqual(SettingsView.SettingsTab.mcpServers.rawValue, "MCP Servers")
        XCTAssertTrue(
            ToolAvailabilityRequirement.mcpToolLive.unmetHint
                .contains(SettingsView.SettingsTab.mcpServers.rawValue),
            "the badge points at this tab by name — the two must agree")
    }

    /// The Edit sheet's FIRST frame already holds the stored server: the draft is seeded in
    /// the sheet's init (#26), not in a `.task` that runs after a blank frame with a red
    /// banner has been drawn (F49).
    func testEditOpensWithTheStoredValues() throws {
        let stored = try config(authorization: .staticBearer)
        let sheet = MCPServerEditorSheet(
            editing: stored, storedSecretKeys: [stored.bearerSecretKey], existing: [stored], onSave: { _, _ in })

        let seeded = try XCTUnwrap(
            Mirror(reflecting: sheet).descendant("_state") as? State<MCPServerEditorState>).wrappedValue
        XCTAssertEqual(seeded.serverID, stored.id)
        XCTAssertEqual(seeded.slugText, "folio")
        XCTAssertEqual(seeded.urlString, stored.transport.http.urlString)
        XCTAssertEqual(seeded.authorization, .staticBearer)
        XCTAssertEqual(seeded.bearerPlaceholder, "Leave blank to keep the stored token",
                       "the Keychain's answer reaches the first frame too")
        XCTAssertFalse(seeded.revealsProblems)
    }

    /// The sheet closes only on a save that RETURNED. Until 2026-09-24 it dismissed after every
    /// press, and `saveError` was declared, rendered and never assigned (F41).
    func testTheSheetClosesOnlyOnASaveThatReturned() async throws {
        let config = try config()
        var calls = 0

        let saved = await MCPServerEditorSheet.save(config, .init(), through: { _, _ in calls += 1 })
        XCTAssertEqual(saved, .saved)

        let refused = await MCPServerEditorSheet.save(config, .init(), through: { _, _ in
            calls += 1
            throw MCPServerEditError.keychainNotSaved(undone: true)
        })
        XCTAssertEqual(refused, .failed(MCPServerEditError.keychainNotSaved(undone: true).message))

        let blocked = await MCPServerEditorSheet.save(nil, .init(), through: { _, _ in calls += 1 })
        XCTAssertEqual(blocked, .blocked, "a draft with problems asks nothing of the manager")
        XCTAssertEqual(calls, 2)
    }

    /// What the sheet DOES with each outcome, read one-to-one by its `save()`: it closes on a
    /// save that returned and on nothing else, and it shows a failure's message and nothing
    /// else — a refused save stays on screen with everything typed still in it (F41).
    func testEachOutcomeSaysWhetherTheSheetClosesAndWhatItShows() {
        typealias Outcome = MCPServerEditorSheet.SaveOutcome
        let message = MCPServerEditError.keychainNotSaved(undone: true).message

        XCTAssertTrue(Outcome.saved.dismissesSheet)
        XCTAssertFalse(Outcome.failed(message).dismissesSheet, "a refused save keeps the sheet open")
        XCTAssertFalse(Outcome.blocked.dismissesSheet)
        XCTAssertEqual(Outcome.failed(message).saveError, message)
        XCTAssertNil(Outcome.saved.saveError)
        XCTAssertNil(Outcome.blocked.saveError, "the problems banner speaks for a blocked draft")
    }

    /// The server screen's banner holds the last failed action. A success clears only a
    /// failure of its OWN kind: a folder switch that saved says nothing about an approval the
    /// trust store refused a moment ago (review of group D, 2026-09-24 — until then any
    /// success cleared the banner, and the row went on showing a decision never recorded).
    func testASuccessClearsOnlyAFailureOfItsOwnKind() {
        typealias Failure = MCPServerDetailView.ActionFailure
        let refusedApproval = Failure(action: .review, message: "That change could not be saved.")

        XCTAssertEqual(Failure.after(success: .folderRule, over: refusedApproval), refusedApproval)
        XCTAssertEqual(Failure.after(success: .refresh, over: refusedApproval), refusedApproval)
        XCTAssertNil(Failure.after(success: .review, over: refusedApproval))
        XCTAssertNil(Failure.after(success: .folderRule, over: nil))
    }

    // MARK: - The server page's banner (review of group D, 2026-09-24)

    /// A failed folder switch puts ITS error on the banner — the edit error's own message, or
    /// the generic one for anything else — and a failure of this kind is what its next success
    /// clears; a review failure on screen is left alone.
    func testTheFolderSwitchReportsItsFailureAndClearsOnlyItsOwn() async {
        typealias Failure = MCPServerDetailView.ActionFailure
        await Failure.attempt(.folderRule, banner: banner.binding) { throw MCPServerEditError.folderRuleNotSaved }
        XCTAssertEqual(banner.value, Failure(action: .folderRule, message: MCPServerEditError.folderRuleNotSaved.message))

        struct Unexpected: Error {}
        await Failure.attempt(.folderRule, banner: banner.binding) { throw Unexpected() }
        XCTAssertEqual(banner.value?.message, MCPToolReviewChrome.failureMessage(for: Unexpected()))

        await Failure.attempt(.folderRule, banner: banner.binding) {}
        XCTAssertNil(banner.value, "its own success clears it")

        let refusedApproval = Failure(action: .review, message: "That change could not be saved.")
        banner.value = refusedApproval
        await Failure.attempt(.folderRule, banner: banner.binding) {}
        XCTAssertEqual(banner.value, refusedApproval, "a folder switch that saved says nothing about an approval")
    }

    /// The same two rules for the other two kinds: a review decision (run in place) and a
    /// refresh each report their own failure in their own words and clear only their own.
    func testReviewAndRefreshReportTheirOwnFailureAndClearOnlyTheirOwn() async {
        typealias Failure = MCPServerDetailView.ActionFailure
        Failure.attemptInPlace(.review, banner: banner.binding) { throw MCPReviewError.withdrawn }
        XCTAssertEqual(banner.value, Failure(action: .review, message: MCPReviewError.withdrawn.message))

        await Failure.attempt(.refresh, banner: banner.binding) {}
        XCTAssertEqual(banner.value?.action, .review, "a refresh that answered says nothing about an approval")
        Failure.attemptInPlace(.review, banner: banner.binding) {}
        XCTAssertNil(banner.value)

        await Failure.attempt(.refresh, banner: banner.binding) { throw MCPServerEditError.folderRuleNotSaved }
        XCTAssertEqual(banner.value, Failure(
            action: .refresh, message: "The tool list could not be refreshed — the server did not answer."))
        Failure.attemptInPlace(.review, banner: banner.binding) {}
        XCTAssertEqual(banner.value?.action, .refresh)
    }

    /// A folder switch that fails AGAIN, the same way, still moves the banner: cleared before
    /// the write is awaited, set again when it fails. The switch reads the disk, and a failed
    /// attempt that only wrote a failure EQUAL to the one on screen moved no state — SwiftUI
    /// skipped the redraw and the switch stayed flipped over a rule that was never saved.
    ///
    /// RED until the second review of group D (2026-09-24): one write per attempt.
    func testARetriedFolderSwitchThatFailsAgainMovesTheBannerTwice() async {
        typealias Failure = MCPServerDetailView.ActionFailure
        let refused = Failure.after(failure: MCPServerEditError.folderRuleNotSaved, of: .folderRule)
        banner.value = refused
        banner.writes = []

        await Failure.attempt(.folderRule, banner: banner.binding) { throw MCPServerEditError.folderRuleNotSaved }

        XCTAssertEqual(banner.writes, [nil, refused])
        XCTAssertEqual(banner.value, refused)
    }

    /// Only the folder switch clears ahead: a review or a refresh leaves the banner as it is
    /// until it has an answer, so it does not flicker.
    func testOnlyTheFolderSwitchClearsBeforeItRuns() async {
        typealias Failure = MCPServerDetailView.ActionFailure
        let refresh = Failure.after(failure: MCPServerEditError.folderRuleNotSaved, of: .refresh)
        banner.value = refresh
        banner.writes = []
        await Failure.attempt(.refresh, banner: banner.binding) { throw MCPServerEditError.folderRuleNotSaved }
        XCTAssertEqual(banner.writes, [refresh])
    }

    // MARK: - What the list hands the page and the sheet

    /// The detail pane carries the SELECTED server's identity: a different selection is a
    /// different page, so a banner, a review sheet or a bulk-approval prompt one server left
    /// open does not appear on the next.
    ///
    /// RED until the second review of group D (2026-09-24): the pane kept one identity for every
    /// server, and server A's folder-rule error sat on server B's page.
    func testTheDetailPaneTakesTheSelectedServersIdentity() throws {
        let first = try row()
        let second = MCPServerRow(
            config: try config(slug: "other"), status: .connecting,
            isAllowedInThisFolder: true, hasRequiredSecrets: true, catalogueUnverified: false)
        XCTAssertNotEqual(first.id, second.id)

        for row in [first, second] {
            let pane = MCPServersSettingsView.detail(
                for: row, manager: nil,
                onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
            XCTAssertEqual(Mirror(reflecting: pane).descendant("id") as? UUID, row.id)
            XCTAssertEqual((Mirror(reflecting: pane).descendant("content") as? MCPServerDetailView)?.row.id, row.id)
        }
    }

    /// The Edit sheet is seeded with what the manager last read of the Keychain — so it offers
    /// "leave blank to keep" exactly where a value is stored — and with every configured
    /// server, for the slug check.
    func testTheEditSheetIsSeededWithWhatTheKeychainHolds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = InMemorySecureTokenStorage()
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in NeverConnectingTransport() }, secretStorage: storage,
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config(enabled: false, authorization: .staticBearer)
        try catalogue.upsert(stored)
        try storage.setToken("t.SECRET", forKey: stored.bearerSecretKey)
        await loaded.reload()

        let sheet = MCPServersSettingsView.editorSheet(editing: stored, manager: loaded, onSaved: { _ in })

        let seeded = try XCTUnwrap(
            Mirror(reflecting: sheet).descendant("_state") as? State<MCPServerEditorState>).wrappedValue
        XCTAssertEqual(seeded.storedSecretKeys, [stored.bearerSecretKey])
        XCTAssertEqual(seeded.bearerPlaceholder, "Leave blank to keep the stored token")
        XCTAssertEqual(Mirror(reflecting: sheet).descendant("existing") as? [MCPServerConfig], [stored])

        let adding = MCPServersSettingsView.editorSheet(editing: nil, manager: loaded, onSaved: { _ in })
        let blank = try XCTUnwrap(
            Mirror(reflecting: adding).descendant("_state") as? State<MCPServerEditorState>).wrappedValue
        XCTAssertTrue(blank.storedSecretKeys.isEmpty)
        XCTAssertNil(blank.serverID)
    }

    // MARK: - The server page's decisions (F40, F48, F50, F47)

    private func presentation(
        _ row: MCPServerRow, hasConnection: Bool = true, serverInfo: String? = nil,
        folderRuleAvailable: Bool = true, isRefreshing: Bool = false,
        rejections: [MCPToolDescriptorFactory.Rejection] = []
    ) -> MCPServerDetailPresentation {
        MCPServerDetailPresentation(
            row: row, hasConnection: hasConnection, serverInfoLabel: serverInfo,
            folderRuleAvailable: folderRuleAvailable, isRefreshing: isRefreshing, rejections: rejections)
    }

    /// Refreshing lists the tools over the live session, so it is offered only while there is
    /// one — under "Not connected" it listed on a client that never finished its handshake.
    ///
    /// RED until 2026-09-24: enabled whenever a connection object existed, whatever its status
    /// (F48).
    func testRefreshToolsIsOfferedOnlyWhileConnected() throws {
        XCTAssertTrue(presentation(try row()).refreshEnabled)
        for status: MCPServerStatus in [
            .connecting, .failed(reason: "x"), .needsAuth(reason: "401"),
            .unsupportedTransport(reason: "http"), .incompatible(reason: "v"),
        ] {
            XCTAssertFalse(presentation(try row(status: status)).refreshEnabled, "\(status)")
        }
        XCTAssertFalse(presentation(try row(), isRefreshing: true).refreshEnabled, "one refresh at a time")
        XCTAssertFalse(presentation(try row(), hasConnection: false).refreshEnabled)
    }

    /// Reconnecting is what a person does to a server that is not answering, so it is offered
    /// for any server that is switched on and has a connection — and for none that is off.
    func testReconnectIsOfferedForAnyServerThatIsOn() throws {
        for status: MCPServerStatus in [.connected(era: .modern), .connecting, .failed(reason: "x"), .needsAuth(reason: "401")] {
            XCTAssertTrue(presentation(try row(status: status)).reconnectEnabled, "\(status)")
        }
        XCTAssertFalse(presentation(try row(enabled: false, status: .disabled)).reconnectEnabled)
        XCTAssertFalse(presentation(try row(allowedHere: false, status: .disabled)).reconnectEnabled)
        XCTAssertFalse(presentation(try row(), hasConnection: false).reconnectEnabled)
    }

    /// With no work folder open there is no folder rule to change — every server is allowed,
    /// and the switch could only fail — so the row is not on the page. Under a server that is
    /// switched off it is shown waiting for the power switch.
    func testTheFolderRuleShowsOnlyWithAFolderAndWaitsForThePowerSwitch() throws {
        typealias Kind = MCPServerDetailPresentation.SwitchRow.Kind
        XCTAssertEqual(presentation(try row(), folderRuleAvailable: false).switchRows.map(\.kind), [Kind.power])
        XCTAssertEqual(presentation(try row(), folderRuleAvailable: true).switchRows.map(\.kind), [Kind.power, .folderRule])

        let folder = try XCTUnwrap(presentation(try row()).switchRows.last)
        XCTAssertNil(folder.waitingNote)
        XCTAssertTrue(folder.isNested, "drawn under the switch it depends on")
        let waiting = try XCTUnwrap(presentation(try row(enabled: false, status: .disabled)).switchRows.last)
        XCTAssertEqual(waiting.kind, .folderRule)
        XCTAssertEqual(waiting.waitingNote, "Takes effect once Connect to this server is on.")
        let power = try XCTUnwrap(presentation(try row(enabled: false, status: .disabled)).switchRows.first)
        XCTAssertNil(power.waitingNote, "the power switch waits for nothing")
        XCTAssertFalse(power.isNested)
    }

    /// The Status card's switches are a value the page draws as given: the power switch first —
    /// it decides whether anything below happens at all — then the folder rule under it. Each
    /// reads what the disk holds and attempts its OWN action: a flip of the power switch is a
    /// `.power` attempt, whose failure is worded and cleared as the power switch's, and a flip
    /// of the folder rule a `.folderRule` one.
    ///
    /// RED until 2026-10-28: the rows were two literals in the view's `body`, and the power
    /// switch attempting `.folderRule` or the folder rule drawn above it passed
    /// every test.
    func testEachSwitchReadsItsOwnValueAndAttemptsItsOwnAction() throws {
        let rows = presentation(try row(enabled: true, allowedHere: false, status: .disabled)).switchRows
        XCTAssertEqual(rows.map(\.kind), [.power, .folderRule])
        let power = try XCTUnwrap(rows.first), folder = try XCTUnwrap(rows.last)

        XCTAssertEqual(power.action, .power)
        XCTAssertEqual(power.title, "Connect to this server")
        XCTAssertTrue(power.isOn)
        XCTAssertEqual(folder.action, .folderRule)
        XCTAssertEqual(folder.title, "Allowed in this work folder")
        XCTAssertFalse(folder.isOn)

        let flipped = presentation(try row(enabled: false, allowedHere: true, status: .disabled)).switchRows
        XCTAssertEqual(flipped.map(\.isOn), [false, true], "each reads its own value, not the other's")
        XCTAssertEqual(flipped.map(\.action), [.power, .folderRule])

        // The empty tools card names these switches by the titles they are drawn with.
        XCTAssertTrue(presentation(try row(enabled: false, status: .disabled)).emptyToolsText.contains(power.title))
        XCTAssertTrue(presentation(try row(allowedHere: false, status: .disabled)).emptyToolsText.contains(folder.title))
    }

    /// The empty tools card names the switch that would fill it — the one on this page — rather
    /// than "switch the server on", which sent a person looking for it in Edit (F40).
    func testTheEmptyToolsTextNamesTheSwitchThatWouldFillIt() throws {
        XCTAssertEqual(
            presentation(try row(enabled: false, status: .disabled), hasConnection: false).emptyToolsText,
            "Turn on Connect to this server to see what it offers.")
        XCTAssertEqual(
            presentation(try row(allowedHere: false, status: .disabled), hasConnection: false).emptyToolsText,
            "Turn on Allowed in this work folder to see what it offers.")
        XCTAssertEqual(
            presentation(try row(status: .connecting)).emptyToolsText,
            "Nothing yet — tools appear once the server answers.")
        XCTAssertEqual(presentation(try row()).emptyToolsText, "The server publishes no tools.",
                       "a server that answered with nothing is not still being waited for")
    }

    /// The empty tools card never promises an answer from a server that cannot give one. Each
    /// state no retry repairs gets its own line, naming what a person can do about it — the
    /// waiting line is for a server that is still trying.
    ///
    /// RED until 2026-09-24: all of them fell through to "Nothing yet — tools appear once the
    /// server answers.", which none of them would ever do.
    func testTheEmptyToolsTextNamesWhatAServerThatCannotAnswerNeeds() throws {
        XCTAssertEqual(
            presentation(try row(hasSecrets: false, status: .connecting)).emptyToolsText,
            "Add its token in Edit to see what it offers.")
        XCTAssertEqual(
            presentation(try row(status: .needsAuth(reason: "401"), authorization: .staticBearer)).emptyToolsText,
            "The server turned down its credentials — replace them in Edit to see what it offers.")
        XCTAssertEqual(
            presentation(try row(status: .needsAuth(reason: "401"))).emptyToolsText,
            "The server asks for credentials — add a token in Edit to see what it offers.")
        XCTAssertEqual(
            presentation(try row(status: .unsupportedTransport(reason: "http"))).emptyToolsText,
            "This address cannot be used — change it in Edit to see what it offers.")
        XCTAssertEqual(
            presentation(try row(status: .incompatible(reason: "v"))).emptyToolsText,
            "This app cannot read what the server sends — use Reconnect once the server is updated.")
        XCTAssertEqual(
            presentation(try row(status: .disabled), hasConnection: false).emptyToolsText,
            "Not running — it starts when a work folder opens.",
            "switched on and allowed, and nothing runs it: the manager is shut down")
    }

    /// Only a server that is still trying is waited for.
    func testTheWaitingLineIsForAServerThatIsStillTrying() throws {
        for status: MCPServerStatus in [.connecting, .failed(reason: "refused")] {
            XCTAssertEqual(
                presentation(try row(status: status)).emptyToolsText,
                "Nothing yet — tools appear once the server answers.", "\(status)")
        }
    }

    /// The same order the list's subtitle reads (`MCPServerRow.subtitle`): the power switch,
    /// then the folder rule, then the token, then the status — each line names the first thing
    /// in the way, and a repair further down would not help until it is made.
    func testTheEmptyToolsTextNamesTheFirstThingInTheWay() throws {
        XCTAssertEqual(
            presentation(try row(enabled: false, hasSecrets: false, status: .disabled)).emptyToolsText,
            "Turn on Connect to this server to see what it offers.")
        XCTAssertEqual(
            presentation(try row(allowedHere: false, hasSecrets: false, status: .disabled)).emptyToolsText,
            "Turn on Allowed in this work folder to see what it offers.")
        XCTAssertEqual(
            presentation(try row(hasSecrets: false, status: .needsAuth(reason: "401"), authorization: .staticBearer))
                .emptyToolsText,
            "Add its token in Edit to see what it offers.",
            "a token that is missing is the repair, not the refusal it caused")
        XCTAssertEqual(
            presentation(try row(hasSecrets: false, status: .connecting)).emptyToolsText,
            "Add its token in Edit to see what it offers.")
        XCTAssertEqual(
            presentation(try row(hasSecrets: false, status: .connected(era: .modern), tools: .none)).emptyToolsText,
            "The server publishes no tools.")
        // Both switches off: the power switch is the one to turn on first — the folder rule
        // changes nothing until it is.
        XCTAssertEqual(
            presentation(try row(enabled: false, allowedHere: false, status: .disabled)).emptyToolsText,
            "Turn on Connect to this server to see what it offers.")
    }

    /// The "Not offered to roles" lines are the page presentation's, each built through the
    /// rejection's own `displayLine`: a hidden character in a server's tool name or in a reason
    /// quoting it is spelled out, never printed. The page draws these strings and nothing else,
    /// so the escaping group B requires of server text rests on one tested read.
    ///
    /// RED until 2026-10-28: the view printed each rejection itself, and a copy printing
    /// "\(toolName) — \(reason)" raw passed every test.
    func testTheRejectionLinesSpellOutWhatTheServerHid() throws {
        let hidden = MCPToolDescriptorFactory.Rejection(
            toolName: "note\u{200B}s\u{202E}", reason: "Refers to \u{E0041}#/defs")
        let plain = MCPToolDescriptorFactory.Rejection(toolName: "(unnamed)", reason: "The entry has no name.")
        let page = presentation(try row(), rejections: [hidden, plain])

        XCTAssertEqual(page.rejectionLines.map(\.text), [hidden.displayLine, plain.displayLine])
        XCTAssertEqual(page.rejectionLines.map(\.id), [hidden, plain], "keyed by the refusal, in listing order")
        let line = try XCTUnwrap(page.rejectionLines.first?.text)
        XCTAssertTrue(line.hasPrefix("note\\u{200B}s\\u{202E} — "), line)
        XCTAssertTrue(line.contains("\\u{E0041}"), line)
        XCTAssertFalse(MCPTextSanitizer.containsStrippedCharacters(line), line)
        XCTAssertTrue(presentation(try row()).rejectionLines.isEmpty)
    }

    /// What the server says about itself is marked unverified once, not twice, and the protocol
    /// revision is its own line — not a date inside the status.
    func testTheServersOwnWordsAndItsProtocolAreLinesOfTheirOwn() throws {
        let page = presentation(try row(status: .connected(era: .legacy)), serverInfo: "nanoteams-telegram 1.0.0")
        XCTAssertEqual(page.selfReport, "Server says it is nanoteams-telegram 1.0.0 (not verified).")
        XCTAssertEqual(page.protocolLine, "Protocol: legacy (2025-11-25 or earlier)")
        XCTAssertEqual(
            presentation(try row(status: .connected(era: .modern))).protocolLine,
            "Protocol: modern (\(MCPConstants.modernProtocolVersion))")
        XCTAssertNil(presentation(try row()).selfReport, "a server that said nothing is not quoted")
        XCTAssertNil(presentation(try row(status: .connecting)).protocolLine, "no session, no protocol")
    }

    /// The power switch is a switch like the folder rule: a failure says why in the edit
    /// error's own words, a retry that fails the same way still moves the banner, and its
    /// success clears only its own failure.
    func testThePowerSwitchReportsItsFailureAndClearsOnlyItsOwn() async {
        typealias Failure = MCPServerDetailView.ActionFailure
        let refused = MCPServerEditError.catalogueNotSaved(undone: true, approvalsCleared: false)
        await Failure.attempt(.power, banner: banner.binding) { throw refused }
        XCTAssertEqual(banner.value, Failure(action: .power, message: refused.message))

        banner.writes = []
        await Failure.attempt(.power, banner: banner.binding) { throw refused }
        XCTAssertEqual(banner.writes, [nil, Failure(action: .power, message: refused.message)])

        struct Unexpected: Error {}
        await Failure.attempt(.power, banner: banner.binding) { throw Unexpected() }
        XCTAssertEqual(banner.value?.message, MCPToolReviewChrome.failureMessage(for: Unexpected()))

        let folderRule = Failure(action: .folderRule, message: "x")
        banner.value = folderRule
        await Failure.attempt(.power, banner: banner.binding) {}
        XCTAssertEqual(banner.value, folderRule, "a power switch that saved says nothing about the folder rule")
        banner.value = Failure(action: .power, message: "x")
        await Failure.attempt(.power, banner: banner.binding) {}
        XCTAssertNil(banner.value)
    }

    /// The page the list builds carries the power switch it was handed.
    func testTheDetailPaneCarriesThePowerSwitch() async throws {
        var switched: [Bool] = []
        let pane = MCPServersSettingsView.detail(
            for: try row(), manager: nil,
            onEdit: {}, onDelete: {}, onSetEnabled: { switched.append($0) }, onSetEnabledHere: { _ in })
        let detail = try XCTUnwrap(Mirror(reflecting: pane).descendant("content") as? MCPServerDetailView)
        XCTAssertFalse(detail.folderRuleAvailable, "without a manager there is no work folder")
        XCTAssertNil(detail.connection)
        try await detail.onSetEnabled(false)
        XCTAssertEqual(switched, [false])
    }

    /// The pane reads whether a work folder is open from the manager it is handed — and the
    /// server's connection from the same manager — rather than from a flag the list's `body`
    /// fills: a folder open shows the folder rule, none hides it.
    ///
    /// RED until 2026-10-28: `detail(for:)` took the flag as a parameter, and a hard-coded
    /// `false` there or a `true` in the body passed every test.
    func testTheDetailPaneReadsWhetherAWorkFolderIsOpenFromTheManager() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in NeverConnectingTransport() }, secretStorage: InMemorySecureTokenStorage(),
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config()
        try catalogue.upsert(stored)
        let row = MCPServerRow(
            config: stored, status: .connecting, isAllowedInThisFolder: true, hasRequiredSecrets: true)
        func pane() throws -> MCPServerDetailView {
            let pane = MCPServersSettingsView.detail(
                for: row, manager: loaded,
                onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
            return try XCTUnwrap(Mirror(reflecting: pane).descendant("content") as? MCPServerDetailView)
        }

        await loaded.setWorkFolder(paths: nil)
        XCTAssertFalse(loaded.hasWorkFolder, "premise")
        XCTAssertFalse(try pane().folderRuleAvailable)
        let connection = try XCTUnwrap(loaded.connection(for: stored.id), "premise: the server runs")
        XCTAssertTrue(try pane().connection === connection, "the server's own connection, from the same manager")

        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await loaded.setWorkFolder(paths: NTMSPaths(workFolderRoot: folder))
        XCTAssertTrue(loaded.hasWorkFolder, "premise")
        XCTAssertTrue(try pane().folderRuleAvailable)
    }

    /// After a shutdown with no folder opened since — a folder switch whose open failed — the
    /// page says "Not running — it starts when a work folder opens." and offers no folder rule
    /// beside it: the manager serves no folder, so there is no rule to show or change.
    ///
    /// RED until 2026-10-28: the manager kept the folder it had left, and the page showed
    /// "Allowed in this work folder" under "Not running".
    func testAShutDownManagersPageOffersNoFolderRule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in NeverConnectingTransport() }, secretStorage: InMemorySecureTokenStorage(),
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config()
        try catalogue.upsert(stored)
        func pane() throws -> MCPServerDetailView {
            let row = try XCTUnwrap(loaded.serverRows.first)
            let pane = MCPServersSettingsView.detail(
                for: row, manager: loaded,
                onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
            return try XCTUnwrap(Mirror(reflecting: pane).descendant("content") as? MCPServerDetailView)
        }

        await loaded.setWorkFolder(paths: NTMSPaths(workFolderRoot: folder))
        XCTAssertTrue(try pane().folderRuleAvailable, "premise: a folder is open")
        // The folder the app is about to leave BLOCKS the server: a shut-down manager must not go
        // on reading that folder's rule.
        try await loaded.setServerEnabledInThisFolder(stored.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(loaded.serverRows.first).isAllowedInThisFolder, "premise: blocked here")

        await loaded.shutdown(budget: 0)
        let page = try pane()
        XCTAssertFalse(loaded.hasWorkFolder)
        XCTAssertFalse(page.folderRuleAvailable, "a shut-down manager serves no folder")
        XCTAssertEqual(page.row.status, .disabled)
        XCTAssertTrue(page.row.isAllowedInThisFolder, "no folder is served, so no folder's rule blocks it")
        XCTAssertEqual(page.row.subtitle, "Not running", "not \"Off in this folder\"")
        let shown = page.presentation(isRefreshing: false)
        XCTAssertEqual(shown.switchRows.map(\.kind), [.power], "only the power switch — there is no folder rule")
        XCTAssertEqual(shown.emptyToolsText, "Not running — it starts when a work folder opens.",
                       "not the folder rule's \"Turn on Allowed in this work folder…\"")
    }

    /// One server, one standing: the list's subtitle and the role editor's section header say the
    /// same thing of it, and a grant the role holds of it names the repair that standing needs.
    /// Driven through a REAL manager over the four states that run nothing or not yet — connecting,
    /// off in this folder, not running (the manager shut down, as it is between a folder's teardown
    /// and its re-arm while the old teams stay on screen), switched off.
    ///
    /// RED until 2026-10-28: the picker read only the runtime status, which folds a person's
    /// switch, the folder's rule and a shut-down manager into one `.disabled`, so it said "Off"
    /// beside a list saying "Off in this folder" or "Not running" — and the held grant said
    /// "switched off — turn it on" of a server whose power switch was on.
    func testThePickerAndTheListSayOneThingOfAServer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in NeverConnectingTransport() }, secretStorage: InMemorySecureTokenStorage(),
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config()
        try catalogue.upsert(stored)
        let grant = "mcp__folio__get_metadata"

        func check(_ label: String, says expected: String, heldGrantSays repair: String) throws {
            let row = try XCTUnwrap(loaded.serverRows.first, label)
            let section = try XCTUnwrap(MCPToolSectionBuilder.sections(
                catalogue: loaded.grantCatalogue, selected: [grant], searchText: "", approval: .available).first, label)
            XCTAssertEqual(row.subtitle, expected, "\(label): premise")
            XCTAssertEqual(section.statusNote, row.subtitle, "\(label): the picker and the list disagree")
            let held = try XCTUnwrap(section.rows.first { $0.name == grant }, "\(label): the held grant is listed")
            let note = try XCTUnwrap(held.trailingNote, label)
            XCTAssertTrue(note.contains(repair), "\(label): \(note)")
        }

        await loaded.setWorkFolder(paths: NTMSPaths(workFolderRoot: folder))
        try check("connecting", says: "Connecting…", heldGrantSays: "not connected")

        try await loaded.setServerEnabledInThisFolder(stored.id, enabled: false)
        try check("off in this folder", says: "Off in this folder", heldGrantSays: "off in this work folder")
        try await loaded.setServerEnabledInThisFolder(stored.id, enabled: true)

        await loaded.shutdown(budget: 0)
        try check("not running", says: "Not running", heldGrantSays: "starts when a work folder opens")

        await loaded.setWorkFolder(paths: NTMSPaths(workFolderRoot: folder))
        try await loaded.setServerEnabled(id: stored.id, enabled: false)
        try check("switched off", says: "Off", heldGrantSays: "switched off — turn it on")
    }

    // MARK: - What the page reads, and what a flip writes (2026-10-28)

    /// A flip of a Status-card switch makes the ONE write its row names — the power switch the
    /// app-wide switch, the folder rule the folder's — and never the other; a failure is filed
    /// under the flipped row's own action, so it is worded and cleared as that switch's.
    ///
    /// RED until 2026-10-28: the power switch writing the folder rule or every flip
    /// filed as the folder rule's passed every test because both decisions lived inside the view.
    func testAFlipMakesOnlyItsOwnSwitchsWriteAndFilesItsFailureUnderItsOwnAction() async throws {
        let rows = presentation(try row(enabled: true, allowedHere: true)).switchRows
        XCTAssertEqual(rows.map(\.kind), [.power, .folderRule], "premise")
        let power = try XCTUnwrap(rows.first), folder = try XCTUnwrap(rows.last)
        var writes: [String] = []
        func flip(_ row: MCPServerDetailPresentation.SwitchRow, to on: Bool, failing: Bool) async {
            await MCPServerDetailView.flip(
                row, to: on, banner: banner.binding,
                setEnabled: {
                    writes.append("power \($0)")
                    if failing { throw MCPServerEditError.serverNotFound }
                },
                setEnabledHere: {
                    writes.append("folder \($0)")
                    if failing { throw MCPServerEditError.folderRuleNotSaved }
                })
        }

        await flip(power, to: false, failing: false)
        XCTAssertEqual(writes, ["power false"], "the power switch writes the app-wide switch only")
        await flip(folder, to: true, failing: false)
        XCTAssertEqual(writes, ["power false", "folder true"], "the folder rule writes the folder's rule only")
        XCTAssertNil(banner.value)

        await flip(power, to: true, failing: true)
        XCTAssertEqual(banner.value, .init(action: .power, message: MCPServerEditError.serverNotFound.message))
        await flip(folder, to: false, failing: true)
        XCTAssertEqual(banner.value, .init(action: .folderRule, message: MCPServerEditError.folderRuleNotSaved.message))
        XCTAssertEqual(writes, ["power false", "folder true", "power true", "folder false"])
    }

    /// The "Not offered to roles" lines on the page the list builds are read off the server's OWN
    /// connection: a server that published an entry the app could not read has that line on its
    /// page value, from the connection the manager holds.
    ///
    /// RED until 2026-10-28: the rejections were handed to the presentation
    /// inside `body`, and a page with no lines passed every test.
    func testThePageReadsItsRejectionLinesOffTheServersOwnConnection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        transport.script(MCPWire.toolsListMethod, [.result(.object(["tools": .array([
            .object(["name": .string("get_quote"), "inputSchema": .object(["type": .string("object")])]),
            .object(["name": .string("get_chart"), "inputSchema": .object(["type": .string("string")])]),
        ])]))])
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in transport }, secretStorage: InMemorySecureTokenStorage(),
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config()
        try catalogue.upsert(stored)
        await loaded.setWorkFolder(paths: nil)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, loaded.connection(for: stored.id)?.descriptors.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let connection = try XCTUnwrap(loaded.connection(for: stored.id))
        XCTAssertEqual(connection.rejections.map(\.toolName), ["get_chart"], "premise: one entry refused")

        let pane = MCPServersSettingsView.detail(
            for: try XCTUnwrap(loaded.serverRows.first), manager: loaded,
            onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
        let page = try XCTUnwrap(Mirror(reflecting: pane).descendant("content") as? MCPServerDetailView)
        let lines = page.presentation(isRefreshing: false).rejectionLines
        XCTAssertEqual(lines.map(\.id), connection.rejections)
        XCTAssertEqual(lines.map(\.text), connection.rejections.map(\.displayLine))
        XCTAssertTrue(page.presentation(isRefreshing: true).refreshEnabled == false, "the refresh state is the page's")
    }

    /// The tool row at the Settings pane's minimum and default widths, for a long tool name
    /// beside the widest controls — an approved tool of a Semi-automatic server: the chip and the
    /// pill. The row fits the card — no badge or control cut off — and the name keeps ONE line:
    /// the controls go up beside the badge rather than breaking the identifier.
    ///
    /// RED until 2026-10-28: the fallback was pinned by renders only, and
    /// removing it passed every test.
    func testAToolRowFitsThePaneAndKeepsItsNameOnOneLine() async throws {
        let descriptor = MCPToolDescriptorTests.makeDescriptor(
            originalName: "get_design_context_for_node", modelFacingName: "mcp__folio__get_design_context_for_node",
            description: "Reads the design context of a node.")
        let oneLine = try await toolRowGeometry(descriptor, inAPaneOf: 4000)
        for pane in [Self.minimumPaneWidth, Self.defaultPaneWidth] {
            let laidOut = try await toolRowGeometry(descriptor, inAPaneOf: pane)
            let content = pane - 2 * MCPServerDetailView.pageGutter - 2 * Spacing.standard
            XCTAssertLessThanOrEqual(laidOut.row.width, content + 0.5, "the row is \(laidOut.row.width) pt in \(content)")
            XCTAssertEqual(laidOut.name.height, oneLine.name.height, accuracy: 0.5,
                           "at \(pane) the name column is \(laidOut.name.height) pt tall — the identifier broke")
            XCTAssertGreaterThan(laidOut.row.height, oneLine.row.height + 0.5,
                                 "premise: at \(pane) the controls moved up beside the badge")
        }
    }

    // MARK: - The page's own composition, and where it offers a standing grant (2026-10-28)

    private var recorder: LayoutProbeRecorder!

    /// "Always allow" is offered on a tool row exactly where a standing grant may be written: an
    /// approved tool of a server whose mode allows one — never under Manual, never for a tool
    /// awaiting review. The page reads this value, and so do the gate and the write
    /// (`MCPApprovalMode.allowsStandingGrants`).
    ///
    /// Pins that the page does not decide this inline without the mode.
    func testAToolRowOffersAlwaysAllowOnlyWhereAStandingGrantMayBeWritten() {
        for mode in MCPApprovalMode.allCases {
            XCTAssertEqual(MCPToolRowStatus.offersAlwaysAllow(pinState: .approved, approvalMode: mode),
                           mode.allowsStandingGrants, "\(mode)")
            XCTAssertFalse(MCPToolRowStatus.offersAlwaysAllow(pinState: .new, approvalMode: mode), "\(mode): new")
            XCTAssertFalse(MCPToolRowStatus.offersAlwaysAllow(pinState: .changed(approvedHash: "h"), approvalMode: mode),
                           "\(mode): changed")
        }
        XCTAssertTrue(MCPToolRowStatus.offersAlwaysAllow(pinState: .approved, approvalMode: .semiAutomatic))
        XCTAssertFalse(MCPToolRowStatus.offersAlwaysAllow(pinState: .approved, approvalMode: .manual))
    }

    /// The page as the list builds it (`detail(for:manager:)`, the server's own connection), for
    /// a Semi-automatic server with a long approved tool — the widest row it draws: the chip and
    /// the pill. At the Settings pane's minimum and default widths the tool row fits the card and
    /// the tool's name keeps one line.
    ///
    /// Pins that `MCPServerDetailView` uses the row layout type (`testAToolRowFitsThePaneAndKeepsItsNameOnOneLine` composes
    /// the layout type itself, so a page that stopped using it passed).
    func testThePagesOwnToolRowFitsThePaneAndKeepsItsNameOnOneLine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = ScriptedTransport()
        transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
        transport.script(MCPWire.toolsListMethod, [.result(.object(["tools": .array([
            .object([
                "name": .string("get_design_context_for_node"),
                "description": .string("Reads the design context of a node."),
                "inputSchema": .object(["type": .string("object")]),
            ]),
        ])]))])
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in transport }, secretStorage: InMemorySecureTokenStorage(),
                trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config(mode: .semiAutomatic)
        try catalogue.upsert(stored)
        await loaded.setWorkFolder(paths: nil)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, loaded.connection(for: stored.id)?.descriptors.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let connection = try XCTUnwrap(loaded.connection(for: stored.id))
        try connection.approveNewTools(connection.newTools)
        let tool = try XCTUnwrap(connection.descriptors.first)
        XCTAssertEqual(connection.pinState(of: tool), .approved, "premise: the tool is approved")
        let rowID = "tool-row:\(tool.modelFacingName)", nameID = "tool-row-name:\(tool.modelFacingName)"

        func laidOut(inAPaneOf pane: CGFloat) async throws -> (row: CGRect, name: CGRect) {
            let page = MCPServersSettingsView.detail(
                for: try XCTUnwrap(loaded.serverRows.first), manager: loaded,
                onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
            recorder = LayoutProbeRecorder()
            let frames = await recorder.layOut(page, windowWidth: pane, height: 1200, awaiting: [rowID, nameID])
            return (try XCTUnwrap(frames[rowID], "the page drew the tool row at \(pane)"),
                    try XCTUnwrap(frames[nameID], "the page drew the name column at \(pane)"))
        }

        let oneLine = try await laidOut(inAPaneOf: 4000)
        for pane in [Self.minimumPaneWidth, Self.defaultPaneWidth] {
            let shown = try await laidOut(inAPaneOf: pane)
            let content = pane - 2 * MCPServerDetailView.pageGutter - 2 * Spacing.standard
            XCTAssertLessThanOrEqual(shown.row.width, content + 0.5, "at \(pane) the row is \(shown.row.width) pt in \(content)")
            XCTAssertEqual(shown.name.height, oneLine.name.height, accuracy: 0.5,
                           "at \(pane) the name column is \(shown.name.height) pt tall — the identifier broke")
        }
    }

    // MARK: - The page's own reading of the standing-grant rule, and why a grant was refused (2026-10-28)

    /// A manager with one server in `mode`, connected, its one tool approved — the page's own
    /// fixture (`detail(for:manager:)` over a real connection).
    private func loadedServerWithApprovedTool(
        mode: MCPApprovalMode
    ) async throws -> (manager: MCPServerManager, config: MCPServerConfig, connection: MCPServerConnection,
                       tool: MCPToolDescriptor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-settings-view-\(UUID().uuidString)", isDirectory: true)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogue = MCPServerCatalogueStore(directory: root)
        let loaded = MCPServerManager(
            catalogueStore: catalogue,
            environment: MCPEnvironment(
                makeTransport: { _, _, _ in
                    let transport = ScriptedTransport()
                    transport.script(MCPWire.discoverMethod, [.result(.object([:]))])
                    transport.script(MCPWire.toolsListMethod, [.result(.object(["tools": .array([
                        .object([
                            "name": .string("get_metadata"),
                            "description": .string("Reads metadata."),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ])]))])
                    return transport
                },
                secretStorage: InMemorySecureTokenStorage(), trustDirectory: root, writesRPCLog: false),
            trustStore: MCPTrustStore(directory: root))
        manager = loaded
        let stored = try config(mode: mode)
        try catalogue.upsert(stored)
        await loaded.setWorkFolder(paths: nil)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, loaded.connection(for: stored.id)?.descriptors.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let connection = try XCTUnwrap(loaded.connection(for: stored.id))
        try connection.approveNewTools(connection.newTools)
        let tool = try XCTUnwrap(connection.descriptors.first)
        XCTAssertEqual(connection.pinState(of: tool), .approved, "premise: the tool is approved")
        return (loaded, stored, connection, tool)
    }

    /// The PAGE reads the standing-grant rule: hosted as the list builds it, a Manual server's
    /// approved tool row draws no "Always allow" switch, and a Semi-automatic one's does.
    ///
    /// Pins the standing-grant rule at the page's own site — the page passing
    /// `offersAlwaysAllow: state.isApproved` — which the rule's own test could not see.
    func testTheServerPageDrawsAlwaysAllowOnlyWhereTheModeAllowsAGrant() async throws {
        for (mode, drawn) in [(MCPApprovalMode.manual, false), (.semiAutomatic, true), (.auto, true)] {
            let fixture = try await loadedServerWithApprovedTool(mode: mode)
            let rowID = "tool-row:\(fixture.tool.modelFacingName)"
            let page = MCPServersSettingsView.detail(
                for: try XCTUnwrap(fixture.manager.serverRows.first), manager: fixture.manager,
                onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
            recorder = LayoutProbeRecorder()
            let frames = await recorder.layOut(
                page, windowWidth: Self.defaultPaneWidth, height: 1200,
                awaiting: drawn ? [rowID, "always-allow"] : [rowID])
            XCTAssertNotNil(frames[rowID], "\(mode): premise — the page drew the tool row")
            XCTAssertEqual(frames["always-allow"] != nil, drawn, "\(mode): the switch drawn = \(frames["always-allow"] != nil)")
            await fixture.manager.shutdown(budget: 0)
        }
    }

    /// A refused grant says WHY, on the page's banner: the text moved, the server's mode allows
    /// none, or its connection was stopped — each the connection's own reason
    /// (`MCPServerConnection.setAlwaysAllow`), never one reason for all three. A grant that lands
    /// clears nothing it should not and shows no banner.
    ///
    /// RED until 2026-10-28: the page read every refusal as "The tool changed while you were
    /// reading. Review it again."
    func testARefusedGrantSaysWhyOnTheBanner() async throws {
        let fixture = try await loadedServerWithApprovedTool(mode: .semiAutomatic)
        let flip = { (descriptor: MCPToolDescriptor, connection: MCPServerConnection?) in
            MCPServerDetailView.setAlwaysAllow(true, of: descriptor, through: connection, banner: self.banner.binding)
        }
        flip(fixture.tool, fixture.connection)
        XCTAssertNil(banner.value, "a grant that lands shows no banner")
        XCTAssertTrue(fixture.connection.isAlwaysAllowed(tool: fixture.tool.originalName))

        let moved = MCPToolDescriptorTests.makeDescriptor(
            originalName: fixture.tool.originalName, modelFacingName: fixture.tool.modelFacingName, pinHash: "another")
        flip(moved, fixture.connection)
        XCTAssertEqual(banner.value?.message, MCPReviewError.changedWhileReviewing.message, "the text moved")

        var manual = fixture.config
        manual.approvalMode = .manual
        try await fixture.manager.save(manual, secrets: MCPServerSecretEdit())
        XCTAssertTrue(fixture.manager.connection(for: manual.id) === fixture.connection, "premise: taken in place")
        flip(fixture.tool, fixture.connection)
        XCTAssertEqual(banner.value?.message, MCPReviewError.standingGrantsNotAllowed.message, "the mode allows none")

        await fixture.connection.stop(budget: 0)
        flip(fixture.tool, fixture.connection)
        XCTAssertEqual(banner.value?.message, MCPReviewError.connectionStopped.message, "the connection was stopped")

        flip(fixture.tool, nil)
        XCTAssertEqual(banner.value?.message, MCPReviewError.withdrawn.message, "no connection at all")
        XCTAssertEqual(Set([MCPReviewError.changedWhileReviewing, .standingGrantsNotAllowed, .connectionStopped,
                            .withdrawn].map(\.message)).count, 4, "four reasons, four sentences")
    }

    /// Each refusal says what is TRUE of its own case — read by its content, not only told apart
    /// from the others: a stopped connection says the connection was stopped (and to try again
    /// once it has reconnected), Manual says it is the approval mode and names the mode that
    /// allows a grant, a moved text says the tool changed while it was read. None claims another's
    /// cause, and each of the two write refusals says nothing was recorded.
    ///
    /// Pins literal banner copy: the banner test compared each banner with its case's
    /// own `message`, so a sentence reworded into a false one still passed.
    func testEachRefusalOfAGrantSaysItsOwnCause() {
        let stopped = MCPReviewError.connectionStopped.message
        XCTAssertTrue(stopped.contains("connection was stopped"), stopped)
        XCTAssertTrue(stopped.contains("nothing was recorded"), stopped)
        XCTAssertTrue(stopped.contains("reconnected"), stopped)
        XCTAssertFalse(stopped.contains("Manual") || stopped.contains("approval mode"), stopped)

        let manual = MCPReviewError.standingGrantsNotAllowed.message
        XCTAssertTrue(manual.contains("approval mode is Manual"), manual)
        XCTAssertTrue(manual.contains("nothing was recorded"), manual)
        XCTAssertTrue(manual.contains("Semi-automatic"), manual)
        XCTAssertFalse(manual.contains("stopped") || manual.contains("changed"), manual)

        let moved = MCPReviewError.changedWhileReviewing.message
        XCTAssertTrue(moved.contains("changed while you were reading"), moved)
        XCTAssertFalse(moved.contains("Manual") || moved.contains("stopped"), moved)
    }

    // MARK: - The review sheet states the header fact by era (2026-10-28)

    /// The review sheet's line about a tool's header parameters is worded from the era of the
    /// server's session, as the approval card's arguments box is: a modern session also sends the
    /// values as request headers (the body carries them too); with no session known, a line true
    /// either way. A legacy session sends no header — since 2026-10-28 a legacy listing admits no header
    /// parameter at all, `x-mcp-header` not being a keyword of its revision — so there is no
    /// line, as there is none for a tool with no header parameter.
    ///
    /// RED until 2026-10-28: "Sent as headers: Mcp-Param-…" whatever the era.
    func testTheReviewSheetStatesTheHeaderFactByEra() throws {
        let params = [try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account"),
                      try MCPHeaderParam.make(argumentPath: ["target", "region"], rawName: "Region")]
        XCTAssertNil(MCPHeaderParamsNote.of([], era: .modern))
        XCTAssertEqual(MCPHeaderParamsNote.of(params, era: .modern), MCPHeaderParamsNote(
            title: "Request headers",
            value: "Also sent as request headers: Mcp-Param-Account (account), Mcp-Param-Region (target.region). "
                + "The body carries the same values."))
        XCTAssertNil(MCPHeaderParamsNote.of(params, era: .legacy),
                     "a legacy session sends no header, so the sheet draws no header line")
        XCTAssertEqual(MCPHeaderParamsNote.of(params, era: nil), MCPHeaderParamsNote(
            title: "Request headers",
            value: "account, target.region always travel in the body; on a server speaking 2026-07-28 they are "
                + "also sent as request headers Mcp-Param-Account, Mcp-Param-Region."))
    }

    private var rowProbe: ToolRowProbe!

    /// The tool row's size and its name column's, laid out in the page's own Tools card in an
    /// offscreen window as wide as the pane.
    private func toolRowGeometry(
        _ descriptor: MCPToolDescriptor, inAPaneOf paneWidth: CGFloat
    ) async throws -> (row: CGSize, name: CGSize) {
        rowProbe = ToolRowProbe()
        let probe = try XCTUnwrap(rowProbe)
        let status = MCPToolRowStatus(pinState: .approved, isRejected: false)
        let page = MCPServerDetailView.page {
            SettingsCard(header: "Tools") {
                MCPServerToolRowLayout(
                    badge: TerminalStatusBadge(glyph: status.glyph, label: status.label, color: status.color),
                    name: MCPServerDetailView.toolNameColumn(descriptor)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.name = $0 },
                    controls: MCPServerToolControls(
                        isApproved: true, offersAlwaysAllow: true, alwaysAllowed: false,
                        onAlwaysAllow: { _ in }, onReview: {}))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.row = $0 }
            }
        }
        let host = NSHostingView(rootView: page)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<20 where probe.row == nil || probe.name == nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.close()
        self.window = nil
        return (try XCTUnwrap(probe.row, "the row was laid out"), try XCTUnwrap(probe.name, "the name was laid out"))
    }

    // MARK: - The Status card at the Settings window's real widths

    /// The Settings window's detail pane: the window (`NanoTeamsApp`'s `defaultSize` 1000, and
    /// `SettingsView`'s `minWidth` 900) less the 230-point settings sidebar, the server list
    /// (`SettingsLayout.listWidth`) and the list's 1-point divider.
    private static let defaultPaneWidth: CGFloat = 1000 - 230 - SettingsLayout.listWidth - 1
    private static let minimumPaneWidth: CGFloat = 900 - 230 - SettingsLayout.listWidth - 1

    /// The Status card's laid-out width on the server page, in an offscreen window as wide as
    /// the pane.
    private func statusCardWidth(of row: MCPServerRow, inAPaneOf paneWidth: CGFloat) async throws -> CGFloat {
        cardWidth = WidthProbe()
        let probe = try XCTUnwrap(cardWidth)
        let page = MCPServerDetailView.page {
            MCPServerStatusCard(
                row: row,
                presentation: presentation(row, serverInfo: "nanoteams-telegram 1.0.0"),
                isRefreshing: false,
                onFlip: { _, _ in }, onEdit: {}, onReconnect: {}, onRefresh: {}, onDelete: {})
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { probe.width = $0 }
        }
        let host = NSHostingView(rootView: page)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        for _ in 0..<20 where probe.width == nil {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.close()
        self.window = nil
        return try XCTUnwrap(probe.width, "the card was laid out")
    }

    /// At the Settings window's default and minimum widths the Status card keeps the page's
    /// margins, for the widest row it draws — connected with tools to review, trusted,
    /// Semi-automatic, a work folder open: the pills wrap Remove onto a line of its own, and
    /// the tags drop under the status badge.
    ///
    /// RED until 2026-10-28: the action row (four fixed-size pills, ≈ 444 pt) and the badge
    /// row (≈ 476 pt) could not shrink; at the default pane the right margin disappeared, and
    /// at the minimum "Remove server" and the mode tag were cut off.
    func testTheStatusCardKeepsThePagesMarginsAtTheWindowsDefaultAndMinimumWidths() async throws {
        let widest = try row(
            tools: MCPToolTally(approved: 1, new: 2, changed: 1, rejected: 0), trusted: true, mode: .semiAutomatic)
        XCTAssertEqual(widest.subtitle, "Connected · 3 to review · 1 approved", "premise: the widest badge")
        XCTAssertEqual(presentation(widest).switchRows.count, 2, "premise: a work folder is open")
        XCTAssertEqual(Self.defaultPaneWidth, 509)
        XCTAssertEqual(Self.minimumPaneWidth, 409)

        for pane in [Self.defaultPaneWidth, Self.minimumPaneWidth] {
            let width = try await statusCardWidth(of: widest, inAPaneOf: pane)
            XCTAssertGreaterThan(width, 0, "premise: the card was laid out at \(pane)")
            XCTAssertLessThanOrEqual(
                width, pane - 2 * MCPServerDetailView.pageGutter + 0.5,
                "the Status card is \(width) pt wide in a \(pane)-point pane")

            var autoCfg = try config(trusted: true, mode: .auto)
            autoCfg.judgeStrictness = .permissive
            let autoWidest = MCPServerRow(
                config: autoCfg, status: .connected(era: .modern),
                isAllowedInThisFolder: true, hasRequiredSecrets: true,
                tools: MCPToolTally(approved: 1, new: 2, changed: 1, rejected: 0))
            let autoWidth = try await statusCardWidth(of: autoWidest, inAPaneOf: pane)
            XCTAssertLessThanOrEqual(
                autoWidth, pane - 2 * MCPServerDetailView.pageGutter + 0.5,
                "the Status card under Auto · Permissive is \(autoWidth) pt wide in a \(pane)-point pane")
        }
    }

    // MARK: - Where the Status card and the editor draw what (F50, F40)

    /// The coordinate space of a render's root — the bitmap's own, rows from its top edge. Not
    /// `.global`: in a titled window that also counts the title bar.
    private static let renderRoot = "mcp-render-root"

    /// The Status card as the server page draws it, `row` against `presentation`, `pane` points
    /// wide — and the card's frame in the render, through a frame probe.
    private func renderStatusCard(
        _ row: MCPServerRow, _ presentation: MCPServerDetailPresentation, isRefreshing: Bool = false,
        pane: CGFloat
    ) throws -> (render: PixelDiff.Render, card: CGRect) {
        let frame = FrameProbe()
        let page = MCPServerDetailView.page {
            MCPServerStatusCard(
                row: row, presentation: presentation, isRefreshing: isRefreshing,
                onFlip: { _, _ in }, onEdit: {}, onReconnect: {}, onRefresh: {}, onDelete: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.renderRoot)) } action: { frame.rect = $0 }
        }
        .coordinateSpace(.named(Self.renderRoot))
        let render = try XCTUnwrap(PixelDiff.render(page, width: pane, height: 900), "the page was drawn")
        return (render, try XCTUnwrap(frame.rect, "the card was laid out"))
    }

    /// The rows, in points, that two renders differ in — where the one input they differ in is
    /// drawn.
    private func drawn(_ a: PixelDiff.Render, _ b: PixelDiff.Render, _ label: String) throws -> ClosedRange<CGFloat> {
        try XCTUnwrap(PixelDiff.changedPoints(a, b), "\(label): the two renders are identical — nothing was drawn for it")
    }

    private func row(displayName: String, enabled: Bool = true) throws -> MCPServerRow {
        MCPServerRow(
            config: MCPServerConfig(
                slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: displayName,
                transport: .http(MCPHTTPConfig(urlString: "http://127.0.0.1:3845/mcp")),
                isEnabled: enabled, approvalMode: .semiAutomatic),
            status: .connected(era: .modern), isAllowedInThisFolder: true, hasRequiredSecrets: true,
            tools: MCPToolTally(approved: 1, new: 2, changed: 0, rejected: 0))
    }

    private func presentation(of row: MCPServerRow, hasConnection: Bool) -> MCPServerDetailPresentation {
        MCPServerDetailPresentation(
            row: row, hasConnection: hasConnection, serverInfoLabel: "nanoteams-telegram 1.0.0",
            folderRuleAvailable: false, isRefreshing: false, rejections: [])
    }

    /// The Status card draws, top to bottom, the server it is — its name and address — then the
    /// power switch, then what can be done to it, all inside the card, at the Settings window's
    /// default and minimum widths. Each landmark is where a render CHANGES when one input does:
    /// the identity row, the server's name "Folio" against "Folio Desktop"; the power switch, the
    /// same row with a presentation built from it switched on against off — the card takes the
    /// two apart, so only the switch moves; the actions, the Refresh pill's loader. A frame probe
    /// cannot do this: the `┤ STATUS ├` chip is an overlay that takes no layout space, so the
    /// pills drawn into it (F50, its first form) left the card's laid-out width as it was while
    /// they sat on its border above the first row.
    func testTheStatusCardDrawsItsServerThenItsPowerSwitchThenItsActions() async throws {
        for pane in [Self.defaultPaneWidth, Self.minimumPaneWidth] {
            let named = try row(displayName: "Folio Desktop")
            let shortName = try row(displayName: "Folio")
            let off = try row(displayName: "Folio Desktop", enabled: false)

            let base = try renderStatusCard(named, presentation(of: named, hasConnection: false), pane: pane)
            let renamed = try renderStatusCard(shortName, presentation(of: shortName, hasConnection: false), pane: pane)
            let switchedOff = try renderStatusCard(named, presentation(of: off, hasConnection: false), pane: pane)
            let connected = try renderStatusCard(named, presentation(of: named, hasConnection: true), pane: pane)
            let refreshing = try renderStatusCard(
                named, presentation(of: named, hasConnection: true), isRefreshing: true, pane: pane)

            let identity = try drawn(base.render, renamed.render, "\(pane): the server's name")
            let power = try drawn(base.render, switchedOff.render, "\(pane): the power switch")
            let actions = try drawn(connected.render, refreshing.render, "\(pane): the Refresh pill")
            let card = base.card

            XCTAssertLessThan(identity.upperBound, power.lowerBound,
                              "\(pane): the power switch is not under the server's name — \(identity) vs \(power)")
            XCTAssertLessThan(power.upperBound, actions.lowerBound,
                              "\(pane): the actions are not under the power switch — \(power) vs \(actions)")
            for (label, range) in [("the name", identity), ("the switch", power), ("the actions", actions)] {
                XCTAssertGreaterThanOrEqual(range.lowerBound, card.minY - 0.5, "\(pane): \(label) is drawn above the card")
                XCTAssertLessThanOrEqual(range.upperBound, card.maxY + 0.5, "\(pane): \(label) is drawn below the card")
            }
        }
    }

    /// A missing token adds no line of its own to the Server card: the badge says "Needs a
    /// token", the list row says it, and the Tools card says where to paste it. Until the design
    /// review of 2026-11-07 a fourth sentence said it in warning ink under the badge — so the
    /// card with a token and the card without one must be the same height, the only difference
    /// drawn being the badge's own words.
    func testAMissingTokenIsSaidByTheBadgeAndNotAgainUnderIt() async throws {
        func row(hasSecrets: Bool) throws -> MCPServerRow {
            MCPServerRow(
                config: MCPServerConfig(
                    slug: try XCTUnwrap(MCPServerSlug("telegram")), displayName: "Telegram",
                    transport: .http(MCPHTTPConfig(
                        urlString: "http://127.0.0.1:8765/mcp", authorization: .staticBearer)),
                    isEnabled: true),
                status: .failed(reason: "Could not reach the server: the connection was refused"),
                isAllowedInThisFolder: true, hasRequiredSecrets: hasSecrets,
                tools: MCPToolTally(approved: 0, new: 0, changed: 0, rejected: 0))
        }
        let withToken = try row(hasSecrets: true)
        let withoutToken = try row(hasSecrets: false)
        XCTAssertNotEqual(withToken.subtitle, withoutToken.subtitle, "premise: the badge itself says it")
        XCTAssertEqual(withoutToken.subtitle, "Needs a token")

        for pane in [Self.defaultPaneWidth, Self.minimumPaneWidth] {
            let a = try renderStatusCard(withToken, presentation(of: withToken, hasConnection: false), pane: pane)
            let b = try renderStatusCard(withoutToken, presentation(of: withoutToken, hasConnection: false), pane: pane)
            XCTAssertEqual(a.card.height, b.card.height, accuracy: 0.5,
                           "\(pane): the card grew \(b.card.height - a.card.height) pt for a sentence the badge already says")
        }
    }

    /// The editor's Server card opens with "Connect to this server": the switch is drawn above
    /// every field of the card — the short name, the display name, the address — found as the
    /// status card's landmarks are, each by the one input that moves it. If the switch slid down
    /// the card, or back into the Approval card where F40 found it, it would be drawn below them.
    func testTheEditorDrawsItsConnectSwitchAboveEveryField() async throws {
        func sheet(enabled: Bool = true, slug: String = "orders", name: String = "Orders",
                   url: String = "https://orders.test/mcp") throws -> PixelDiff.Render {
            let stored = MCPServerConfig(
                slug: try XCTUnwrap(MCPServerSlug(slug)), displayName: name,
                transport: .http(MCPHTTPConfig(urlString: url)), isEnabled: enabled)
            return try XCTUnwrap(PixelDiff.render(
                MCPServerEditorSheet(editing: stored, existing: [], onSave: { _, _ in }), width: 620, height: 900),
            "the sheet was drawn")
        }
        let base = try sheet()
        let toggle = try drawn(base, try sheet(enabled: false), "the Connect switch")
        let fields = [
            ("the short name", try drawn(base, try sheet(slug: "orders2"), "the short name")),
            ("the display name", try drawn(base, try sheet(name: "Orders Desk"), "the display name")),
            ("the address", try drawn(base, try sheet(url: "https://ledger.test/mcp"), "the address")),
        ]
        for (label, field) in fields {
            XCTAssertLessThan(toggle.upperBound, field.lowerBound,
                              "the Connect switch is not above \(label) — \(toggle) vs \(field)")
        }
    }

    func testTheMasterDetailAndItsSheetsCompose() throws {
        _ = MCPServersSettingsView()
        _ = MCPServerEditorSheet(editing: nil, existing: [], onSave: { _, _ in })
        _ = MCPServerDetailView(
            row: try row(), connection: nil, folderRuleAvailable: false,
            onEdit: {}, onDelete: {}, onSetEnabled: { _ in }, onSetEnabledHere: { _ in })
        for (pinState, approvedPin) in [
            (MCPPinState.new, nil),
            (.approved, MCPToolPin(toolName: "get_screenshot", hash: "hash", approvedAt: Date())),
            (.changed(approvedHash: "old"), MCPToolPin(toolName: "get_screenshot", hash: "old", approvedAt: Date())),
        ] {
            _ = MCPToolReviewSheet(
                serverName: "Folio Desktop",
                descriptor: MCPToolDescriptorTests.makeDescriptor(
                    originalName: "get_screenshot", modelFacingName: "mcp__folio__get_screenshot"),
                pinState: pinState,
                isRejected: false,
                approvedPin: approvedPin,
                era: .modern,
                onApprove: {}, onReject: {}, onRevoke: { _ in })
        }
    }

    // MARK: - Auto mode UI: status badge, judge prompt preview, Auto judge model card (D-M14)

    func testStatusCardShowsJudgeStrictnessInAutoModeTagLabel() throws {
        let manual = try config(mode: .manual)
        XCTAssertEqual(MCPServerStatusCard.approvalModeTagLabel(for: manual), "Manual")

        let semi = try config(mode: .semiAutomatic)
        XCTAssertEqual(MCPServerStatusCard.approvalModeTagLabel(for: semi), "Semi-automatic")

        for (strictness, expected) in [
            (MCPJudgeStrictness.strict, "Auto · Strict"),
            (.standard, "Auto · Standard"),
            (.permissive, "Auto · Permissive"),
        ] {
            var autoConfig = try config(mode: .auto)
            autoConfig.judgeStrictness = strictness
            XCTAssertEqual(MCPServerStatusCard.approvalModeTagLabel(for: autoConfig), expected)
        }
    }

    func testMCPJudgePreviewSheetRendersSystemPromptAndTemplateForStrictness() {
        for strictness in MCPJudgeStrictness.allCases {
            let prompt = MCPJudgePreviewSheet.systemPrompt(strictness: strictness)
            XCTAssertEqual(prompt, MCPJudgeService.systemPrompt(strictness: strictness))
            XCTAssertFalse(prompt.isEmpty)
        }
        let template = MCPJudgePreviewSheet.userMessageTemplate
        XCTAssertTrue(template.contains("Server:"))
        XCTAssertTrue(template.contains("Tool:"))
        XCTAssertTrue(template.contains("Arguments sent to the server:"))
    }

    /// A rewrite of an approved tool leads the Tools card, then new tools, then what is decided —
    /// each group in the server's own order.
    func testTheToolListPutsWhatWaitsForAPersonFirst() {
        let items: [(String, MCPToolRowStatus)] = [
            ("a", .approved), ("b", .new), ("c", .rejected), ("d", .changed), ("e", .new), ("f", .approved),
        ]
        let ordered = MCPToolRowStatus.reviewOrdered(items, status: \.1).map(\.0)
        XCTAssertEqual(ordered, ["d", "b", "e", "a", "f", "c"])
    }

    func testMCPAutoJudgeModelCardHasHeaderAndFooter() {
        XCTAssertEqual(MCPAutoJudgeModelCard.headerTitle, "Auto judge model")
        XCTAssertTrue(MCPAutoJudgeModelCard.footerText.contains("Ask AI"))
        XCTAssertTrue(MCPAutoJudgeModelCard.footerText.contains("calling role's configuration"))
        XCTAssertTrue(MCPAutoJudgeModelCard.footerText.contains("global LLM configuration"))
    }
}

/// A hosted tool row's size, and its name column's.
@MainActor
private final class ToolRowProbe {
    var row: CGSize?
    var name: CGSize?
}

/// The width a hosted view last reported.
@MainActor
private final class WidthProbe {
    var width: CGFloat?
}

/// The frame a hosted view last reported, in the window.
@MainActor
private final class FrameProbe {
    var rect: CGRect?
}

/// A banner a test can watch: every value written through its binding, in order.
@MainActor
private final class BannerRecorder {
    var value: MCPServerDetailView.ActionFailure?
    var writes: [MCPServerDetailView.ActionFailure?] = []

    var binding: Binding<MCPServerDetailView.ActionFailure?> {
        Binding(get: { self.value }, set: { self.value = $0; self.writes.append($0) })
    }
}
