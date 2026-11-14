import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// RED-first unit and view-state tests for the External Agents tab:
/// - `ExternalAgentsConnectionFacts` (Appendix C — the fields a client needs, the `127.0.0.1`
///   invariant, no token and no environment channel anywhere)
/// - `ExternalAgentSheet` (the hand-over, what must be copied, the connection stage)
/// - `ExternalAgentsSetupPrompt` (#385)
/// - `ExternalAgentsSettingsPresentation` (listener status, D11 portInUse rotation recommendation,
///   agent rows with presence/open task counts, A8 `BashSecurityWarning`, concealed pasteboard copy)
/// - `AutovisorSettingsPresentation` (C7 driver-mode visibility rules for `.builtInModel` vs `.externalAgent`)
@MainActor
final class ExternalAgentsSettingsTests: XCTestCase {
    typealias Facts = ExternalAgentsConnectionFacts

    // MARK: - Appendix C: the connection facts & the 127.0.0.1 invariant

    /// A home folder that is nobody's, for the paths the facts name. Computed, not stored:
    /// XCTest builds every test instance up front.
    private var home: URL { URL(fileURLWithPath: "/Users/you", isDirectory: true) }
    private var token: String { "ntm_a4c36525_0f3c9b1e7d2a4c6e8b0f1a3c5e7d9b2f4a6c8e0b" }

    private func fields(port: UInt16 = 47_321, executablePath: String = "/x/NanoTeams.app/Contents/MacOS/NanoTeams",
                        shortID: String = "a4c36525") -> [Facts.Field] {
        Facts.fields(port: port, executablePath: executablePath, home: home, shortID: shortID)
    }

    private func field(_ kind: Facts.Field.Kind, port: UInt16 = 47_321) throws -> Facts.Field {
        try XCTUnwrap(fields(port: port).first { $0.kind == kind })
    }

    /// Four facts, the bridge's first — the route that leaves no token in the client's
    /// configuration — each with a title and the words under it; the endpoint at the port the
    /// server actually listens on, and never `localhost` (Appendix C). Until 2026-11-12 there
    /// were six: the `Authorization` header, which was never a value to copy, and the token
    /// file, whose path the bridge arguments already hold.
    func testConnectionFacts_fourFieldsInOrder_atTheServersPortAndNeverLocalhost() throws {
        XCTAssertEqual(fields().map(\.kind), [.bridgeCommand, .bridgeArguments, .endpoint, .callTimeout])
        XCTAssertEqual(fields().map(\.kind), Facts.Field.Kind.allCases, "one field per kind")
        for field in fields() {
            XCTAssertFalse(field.title.isEmpty, "\(field.kind)")
            XCTAssertFalse(field.caption.isEmpty, "\(field.kind)")
            XCTAssertFalse(field.value.lowercased().contains("localhost"), "\(field.kind) must NEVER use localhost")
        }
        XCTAssertEqual(try field(.endpoint).value, "http://127.0.0.1:47321/mcp")
        XCTAssertEqual(try field(.endpoint, port: 49_123).value, "http://127.0.0.1:49123/mcp", "the port the server uses")
        XCTAssertTrue(try field(.endpoint).caption.contains("not localhost"), "and the person is told not to substitute it")
    }

    /// The fields are two ALTERNATIVE routes and what both need, in that order: a flat list left
    /// the person to work out that a client takes either the command and its arguments or the
    /// address and a header. A route with no field of its own is not a group.
    func testConnectionFacts_areGroupedByRoute_bridgeFirst() throws {
        let groups = Facts.groups(fields())
        XCTAssertEqual(groups.map(\.route), [.bridge, .http, .both])
        XCTAssertEqual(groups.map { $0.fields.map(\.kind) }, [[.bridgeCommand, .bridgeArguments], [.endpoint], [.callTimeout]])
        XCTAssertEqual(groups.flatMap(\.fields), fields(), "every field is in exactly one group, in the fields' own order")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertTrue(try XCTUnwrap(groups.first).title.contains("stdio"), "which client takes the bridge")
        XCTAssertTrue(groups[1].title.hasPrefix("HTTP"), groups[1].title)
        for route in Facts.Route.allCases {
            XCTAssertFalse(route.title.isEmpty, "\(route)")
        }

        XCTAssertTrue(Facts.groups([]).isEmpty, "no field, no group")
        let httpOnly = Facts.groups(fields().filter { $0.kind == .endpoint })
        XCTAssertEqual(httpOnly.map(\.route), [.http], "a route with no field is left out")
    }

    /// No field carries a token, and none hands it over through an environment variable (#375):
    /// any process of the same user, a role's sandboxed `bash` included, reads another's
    /// environment, and no Seatbelt clause stops it. The header a client sends is said in words
    /// under the endpoint, with `<token>` where the token goes.
    func testConnectionFacts_carryNoTokenAndNoEnvironmentChannel() throws {
        for field in fields() {
            XCTAssertFalse(field.value.contains(HostedMCPConstants.tokenPrefix), "\(field.kind): \(field.value)")
            for channel in ["NANOTEAMS_TOKEN", "${env:", "bearer_token_env_var", "env_http_headers", "\"env\""] {
                XCTAssertFalse(field.value.contains(channel), "\(field.kind) hands the token over through \(channel)")
                XCTAssertFalse(field.caption.contains(channel), "\(field.kind) hands the token over through \(channel)")
            }
        }
        let endpoint = try field(.endpoint)
        XCTAssertTrue(endpoint.caption.contains("Authorization: Bearer <token>"), endpoint.caption)
        XCTAssertTrue(endpoint.caption.contains("only a hash"), "why it cannot be shown again")
    }

    /// Every value is an agent's own, so every value can be copied as it stands: nothing in one
    /// is a placeholder. Until 2026-11-12 the Settings page drew the same fields for nobody, and
    /// three of its six carried `<agent-id>` or `<token>` and so had no Copy.
    func testConnectionFacts_leaveNothingToFillIn() throws {
        for field in fields() {
            XCTAssertFalse(field.value.contains("<"), "\(field.kind): \(field.value)")
            XCTAssertFalse(field.caption.contains("<agent-id>"), "\(field.kind): \(field.caption)")
        }
        XCTAssertTrue(try field(.bridgeArguments).value.hasSuffix("/a4c36525.token"))
        XCTAssertTrue(
            fields(shortID: "b7d11e02").contains { $0.kind == .bridgeArguments && $0.value.hasSuffix("/b7d11e02.token") },
            "each agent its own file")
        let row = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsConnectionFactRow.swift")
        XCTAssertFalse(row.contains("isTemplate"), "no field is a template, so Copy is never withheld")
    }

    /// The token file is where `HostedMCPClientTokenFile` writes it, by absolute path — never
    /// `~`, since a client or an assistant may run with another HOME — and that folder is one the
    /// sandbox denies to every role's bash, whatever the grants.
    func testConnectionFacts_tokenFileIsTheOneNanoTeamsWrites_absolute_andDeniedToRoles() throws {
        let path = Facts.tokenFilePath(shortID: "a4c36525", home: home)
        XCTAssertEqual(path, HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)?.path)
        XCTAssertTrue(path.hasPrefix("/Users/you/"), path)
        XCTAssertFalse(path.contains("~"), path)
        XCTAssertFalse(path.contains(" "), "no space in the path: the bridge argument pastes unquoted — \(path)")
        let denied = SeatbeltSandbox.externalAgentTokenLocations(home: home.path).subpaths
        XCTAssertTrue(denied.contains { path.hasPrefix($0 + "/") }, "\(path) is outside \(denied)")
        // Its lifecycle is said under the arguments that name it — the file is no field of its own.
        let caption = try field(.bridgeArguments).caption
        for fact in ["readable by you only", "replaced on a reissue", "removed on revoke"] {
            XCTAssertTrue(caption.contains(fact), fact)
        }
    }

    /// The bridge arguments are the relay's own flag and the token file, in the order the relay
    /// reads them — parsed back with the relay's own parser, so the field and the reader cannot
    /// drift apart.
    func testConnectionFacts_bridgeArgumentsAreWhatTheRelayReads() throws {
        let arguments = try field(.bridgeArguments).value
        let path = Facts.tokenFilePath(shortID: "a4c36525", home: home)
        XCTAssertEqual(arguments, "--mcp-stdio --token-file \(path)")
        let words = arguments.split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, 3, "three arguments a client's args array takes one by one")
        XCTAssertEqual(words.first, NanoTeamsLauncher.mcpStdioFlag)
        XCTAssertEqual(HostedMCPStdioRelay.tokenFilePath(in: words), path)
        XCTAssertEqual(try field(.bridgeCommand).value, "/x/NanoTeams.app/Contents/MacOS/NanoTeams", "this copy of the app")
        XCTAssertTrue(try field(.bridgeCommand).caption.contains("holds no secret"))
    }

    /// A client that cuts a call at exactly the longest wait the server advertises turns a full
    /// `wait_for_events` into a timeout error, because the reply leaves after the deadline
    /// (measured 2026-11-07: 3600 s → 3601 s, 35 s → 36.9 s). The field keeps the relay's own
    /// margin, says its unit, and says why.
    func testConnectionFacts_callTimeoutOutlastsTheLongestWait_andIsTheRelays() throws {
        let waitTool = try XCTUnwrap(HostedMCPCatalog.allTools.first { $0.name == ExternalAutovisorToolNames.waitForEvents })
        let longestWait = try XCTUnwrap(waitTool.inputSchema.properties?["timeout_seconds"]?.maximum)
        let timeout = try field(.callTimeout)
        let seconds = try XCTUnwrap(Int(timeout.value), timeout.value)
        XCTAssertGreaterThan(seconds, longestWait)
        XCTAssertEqual(TimeInterval(seconds), URLSessionHostedMCPStdioHTTPClient.mcpRequestTimeout, "one margin for every client")
        XCTAssertTrue(timeout.caption.hasPrefix("Seconds."), timeout.caption)
        XCTAssertTrue(timeout.caption.contains(ExternalAutovisorToolNames.waitForEvents), "the field says why the number is what it is")
        XCTAssertTrue(timeout.caption.contains("in its own unit"), timeout.caption)
    }

    /// The line under an issued agent says where its token went and what is left: the file, for
    /// a first issue and for a reissue; the failure, with what to do. One line's worth, and
    /// never an environment variable (#375).
    func testHandoffLine_saysWhereTheTokenWentAndWhatIsLeft() throws {
        let file = try XCTUnwrap(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home))
        let written = Facts.handoffLine(delivery: .written(file), isReissue: false, home: home)
        XCTAssertEqual(written, "Token written to ~/.config/nanoteams/a4c36525.token. The bridge reads it from there.")
        XCTAssertFalse(written.contains("header"), "who copies the token is the sheet's one note, not every agent's line")
        let rewritten = Facts.handoffLine(delivery: .written(file), isReissue: true, home: home)
        XCTAssertTrue(rewritten.hasPrefix("New token written to ~/.config/nanoteams/a4c36525.token."), rewritten)
        XCTAssertTrue(rewritten.contains("next start"), rewritten)
        let failed = Facts.handoffLine(
            delivery: .notWritten(file, reason: "Could not write ~/.config/nanoteams/a4c36525.token."),
            isReissue: true, home: home)
        XCTAssertTrue(failed.hasPrefix("Could not write"), failed)
        XCTAssertTrue(failed.contains("reissue"), failed)
        XCTAssertTrue(failed.contains("copy the token now"), failed)
        for line in [written, rewritten, failed] {
            XCTAssertFalse(line.contains("NANOTEAMS_TOKEN"), line)
            XCTAssertLessThanOrEqual(line.count, 200, "one line's worth — \(line)")
        }
    }

    /// The hints say what to do next, in words about the facts and never about one client's
    /// format: the port hint, the revoke hint, and the placement rules under the facts.
    func testGuidanceTexts_sayWhatToDoNext() {
        XCTAssertTrue(Facts.portChangeHint.contains("old port"))
        XCTAssertTrue(Facts.portChangeHint.contains("bridge needs nothing"), "the bridge reads the stored port")
        XCTAssertTrue(Facts.removalHint.hasPrefix("Remove the nanoteams entry from the client's configuration"))
        for rule in ["user-level", "work folder", "environment variable", "command line"] {
            XCTAssertTrue(Facts.placementRules.contains(rule), rule)
        }
        for text in [Facts.portChangeHint, Facts.removalHint, Facts.placementRules] + fields().map(\.caption) {
            for format in ["claude mcp", "config.toml", "mcp.json", "settings.json", "headersHelper", "mcpServers"] {
                XCTAssertFalse(text.contains(format), "a client's format is not ours to name: \(text)")
            }
        }
    }

    // MARK: - Design review 2026-11-07

    /// Restart is offered only where it can repair something.
    func testListenerStatus_offersRestartOnlyWhereItCanRepairSomething() {
        typealias S = ExternalAgentsSettingsPresentation.ListenerStatus
        XCTAssertTrue(S.portInUse(port: 47_321).offersRestart)
        XCTAssertTrue(S.failed(message: "x").offersRestart)
        XCTAssertTrue(S.stopped.offersRestart)
        XCTAssertFalse(S.listening(port: 47_321).offersRestart)
        XCTAssertFalse(S.starting.offersRestart)
        XCTAssertFalse(S.disabled.offersRestart)
    }

    private func agentRow(
        label: String = "Claude Code", hint: String? = nil, lastSeen: Date? = nil,
        present: Bool = false, open: Int = 0
    ) -> ExternalAgentRow {
        ExternalAgentRow(
            id: UUID(), shortID: "a4c36525", label: label, clientHint: hint, lastSeenAt: lastSeen,
            isPresent: present, openTasksCount: open, mayReplaceWorkFolderContext: false)
    }

    func testDuplicateLabel_isCaseInsensitiveAndIgnoresAnEmptyDraft() {
        let rows = [agentRow(label: "Claude Code")]
        XCTAssertEqual(ExternalAgentsSettingsPresentation.duplicateLabel("  claude code ", among: rows), "Claude Code")
        XCTAssertNil(ExternalAgentsSettingsPresentation.duplicateLabel("Codex", among: rows))
        XCTAssertNil(ExternalAgentsSettingsPresentation.duplicateLabel("   ", among: rows))
    }

    /// Zero open tasks is noise; an online agent has no "last seen"; the client hint is shown.
    /// The day the agent was created left the line on 2026-11-12 — nothing a person does on this
    /// page depends on it — so an agent with nothing to say has an EMPTY line, which the row
    /// does not draw.
    func testAgentDetailLine_saysOnlyWhatInforms() throws {
        let quiet = agentRow(lastSeen: Date(), present: true).detailLine
        XCTAssertFalse(quiet.contains("open task"))
        XCTAssertFalse(quiet.contains("Last seen"))
        XCTAssertEqual(quiet, "", "online, no hint, no tasks: nothing to say")
        XCTAssertEqual(agentRow().detailLine, "", "never connected")
        XCTAssertEqual(agentRow(hint: "  \n ").detailLine, "", "a blank hint is no hint")
        XCTAssertEqual(agentRow(open: 1).detailLine, "1 open task")
        XCTAssertEqual(agentRow(hint: "codex", present: true, open: 3).detailLine, "codex · 3 open tasks")
        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        XCTAssertTrue(page.contains("if !row.detailLine.isEmpty"), "an empty line holds no height in the row")

        let busy = agentRow(hint: "claude-code/2.1", lastSeen: Date().addingTimeInterval(-600), open: 2).detailLine
        XCTAssertTrue(busy.hasPrefix("claude-code/2.1"))
        XCTAssertTrue(busy.contains("Last seen"))
        XCTAssertTrue(busy.contains("2 open tasks"))
        // The protocol version the client spoke ("MCP 2026-07-28") left the row on 2026-11-08:
        // nothing a person does on this page depends on it. Nor does the row say any more that
        // an agent has "no client recorded" — no agent has one since 2026-11-09.
        XCTAssertFalse(busy.contains("MCP"), busy)
        XCTAssertFalse(busy.contains("client recorded"), busy)
        XCTAssertFalse(busy.contains("Created"), busy)
    }

    // MARK: - Add agent sheet (2026-11-08)

    private func issuedToken(
        id: UUID = UUID(), label: String = "Claude Code", delivery: HostedMCPTokenHandoff.Delivery? = nil
    ) -> ExternalAgentsSettingsView.IssuedAgentTokenItem {
        ExternalAgentsSettingsView.IssuedAgentTokenItem(
            id: id, label: label, shortID: "a4c36525", token: token,
            delivery: delivery ?? .written(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)!))
    }

    private func block(
        _ item: ExternalAgentsSettingsView.IssuedAgentTokenItem, isReissue: Bool = false
    ) -> ExternalAgentSheet.HandoffBlock {
        ExternalAgentSheet.handoffBlock(
            item, isReissue: isReissue, port: 50000, executablePath: "/x/NanoTeams", home: home)
    }

    private var failedFile: HostedMCPTokenHandoff.Delivery {
        .notWritten(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)!, reason: "Could not write it.")
    }

    /// The sheet opens where its entry says — Add at the form, a reissue at its confirmation, an
    /// existing agent at its facts — and each entry's id is stable, so `.sheet(item:)` presents
    /// one sheet per press.
    func testAgentSheetEntry_opensAtItsStageWithAStableID() {
        let row = agentRow()
        XCTAssertEqual(ExternalAgentSheet.Entry.add.id, "add")
        XCTAssertEqual(ExternalAgentSheet.Entry.reissue(.one(row)).id, row.id.uuidString)
        XCTAssertEqual(ExternalAgentSheet.Entry.reissue(.all).id, "reissue-all")
        XCTAssertEqual(ExternalAgentSheet.Entry.connection(row).id, "connection-\(row.id.uuidString)")

        guard case .add = ExternalAgentSheet.Entry.add.initialStage else {
            return XCTFail("Add opens at the form")
        }
        guard case .reissue(.all) = ExternalAgentSheet.Entry.reissue(.all).initialStage else {
            return XCTFail("a reissue opens at its confirmation")
        }
        guard case .reissue(.one(let target)) = ExternalAgentSheet.Entry.reissue(.one(row)).initialStage,
              target.id == row.id else {
            return XCTFail("a reissue names its agent")
        }
        guard case .connection(let shown) = ExternalAgentSheet.Entry.connection(row).initialStage, shown.id == row.id else {
            return XCTFail("the facts open for their agent")
        }
    }

    /// The name an agent gets: what was typed, trimmed — or, with the field left alone, the
    /// default the placeholder showed. No client to propose one from.
    func testAgentSheet_effectiveNameFallsBackToTheDefault() {
        XCTAssertEqual(ExternalAgentSheet.effectiveName(draft: "  Jim's Codex "), "Jim's Codex")
        XCTAssertEqual(ExternalAgentSheet.effectiveName(draft: ""), ExternalAgentSheet.defaultAgentName)
        XCTAssertEqual(ExternalAgentSheet.effectiveName(draft: " \n "), "External agent")
    }

    /// Each agent's block carries its facts with its id filled in and the token to copy; where
    /// the token file could not be written the block is a failure with no facts — the bridge
    /// arguments would name a file that is not there — and the token on the sheet is the only
    /// copy, so it must be copied before the sheet closes.
    func testHandoffBlock_carriesTheFactsForAWrittenToken_andOnlyTheTokenForAFailedFile() throws {
        let written = block(issuedToken())
        XCTAssertFalse(written.isFailure)
        XCTAssertFalse(written.mustBeCopied, "its file holds it")
        XCTAssertTrue(written.offersSetupPrompt)
        XCTAssertEqual(written.fields.map(\.kind), Facts.Field.Kind.allCases)
        XCTAssertTrue(written.fields.contains { $0.kind == .endpoint && $0.value.contains("127.0.0.1:50000") }, "the port the server uses")
        XCTAssertTrue(written.fields.contains { $0.kind == .bridgeArguments && $0.value.hasSuffix("/a4c36525.token") }, "this agent's file")
        XCTAssertTrue(written.fields.contains { $0.kind == .bridgeCommand && $0.value == "/x/NanoTeams" }, "this copy of the app")
        XCTAssertTrue(written.line.hasPrefix("Token written to"), written.line)
        XCTAssertTrue(block(issuedToken(), isReissue: true).line.hasPrefix("New token written to"))

        let failed = block(issuedToken(delivery: failedFile))
        XCTAssertTrue(failed.isFailure)
        XCTAssertTrue(failed.mustBeCopied)
        XCTAssertFalse(failed.offersSetupPrompt)
        XCTAssertTrue(failed.fields.isEmpty)
        XCTAssertTrue(failed.line.hasPrefix("Could not write it."), failed.line)
    }

    /// Done closes at once unless a token that exists nowhere but on the sheet was not copied.
    /// Judged against THESE tokens' ids: an id that is not one of them counts for nothing.
    func testAgentSheet_closesWithoutAskingUnlessAnUnfiledTokenWasNotCopied() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let blocks = [
            block(issuedToken(id: a, delivery: failedFile)),
            block(issuedToken(id: b, delivery: failedFile)),
            block(issuedToken(id: c)),
        ]
        XCTAssertTrue(ExternalAgentSheet.mayCloseWithoutAsking(blocks: blocks, copied: [a, b]), "c is in its file")
        XCTAssertFalse(ExternalAgentSheet.mayCloseWithoutAsking(blocks: blocks, copied: [a]))
        XCTAssertFalse(ExternalAgentSheet.mayCloseWithoutAsking(blocks: blocks, copied: [a, UUID()]),
                       "an id from an earlier hand-over is not this token")
        XCTAssertTrue(ExternalAgentSheet.mayCloseWithoutAsking(blocks: [blocks[2]], copied: []), "nothing to lose")
        XCTAssertTrue(ExternalAgentSheet.mayCloseWithoutAsking(blocks: [], copied: []))
    }

    /// The warning banner only where a token is on the sheet and nowhere else, in the number of
    /// such tokens; who copies the token and the clipboard note wherever one can be copied.
    func testAgentSheet_issuedPresentationWarnsOnlyForAnUnfiledToken() throws {
        func presentation(_ tokens: [ExternalAgentsSettingsView.IssuedAgentTokenItem], isReissue: Bool = false) -> ExternalAgentSheet.IssuedPresentation {
            ExternalAgentSheet.issuedPresentation(
                tokens: tokens, isReissue: isReissue, port: 50000, executablePath: "/x/NanoTeams", home: home)
        }
        let written = presentation([issuedToken()])
        XCTAssertNil(written.banner)
        XCTAssertEqual(written.tokenNote, ExternalAgentSheet.tokenNote)
        XCTAssertEqual(written.clipboardNote, ExternalAgentSheet.clipboardNote)
        XCTAssertTrue(ExternalAgentSheet.tokenNote.contains("header"), "who copies it")
        XCTAssertTrue(ExternalAgentSheet.tokenNote.contains("bridge"), "and who does not")
        XCTAssertTrue(ExternalAgentSheet.tokenNote.contains("cannot be shown again"))

        let one = presentation([issuedToken(delivery: failedFile)])
        XCTAssertEqual(one.banner, "Copy the token now: its file could not be written, and it cannot be shown again.")
        XCTAssertNil(one.tokenNote, "no token is in a file here, and the note says the bridge reads it from one")
        XCTAssertEqual(one.clipboardNote, ExternalAgentSheet.clipboardNote, "it can still be copied")
        let mixed = presentation([issuedToken(delivery: failedFile), issuedToken()], isReissue: true)
        XCTAssertEqual(mixed.tokenNote, ExternalAgentSheet.tokenNote, "one token is in its file")
        XCTAssertNotNil(mixed.banner)
        let two = presentation([issuedToken(delivery: failedFile), issuedToken(delivery: failedFile)], isReissue: true)
        XCTAssertEqual(two.banner, "Copy the tokens now: their files could not be written, and they cannot be shown again.")

        let none = presentation([])
        XCTAssertNil(none.banner)
        XCTAssertNil(none.tokenNote)
        XCTAssertNil(none.clipboardNote)
    }

    /// What an issuing action does to the sheet. A throw stays on the stage it came from with
    /// the message (the typed name is the stage's own state, untouched); tokens move to the
    /// hand-over, carrying any note about agents left out; nothing issued at all stays, and says so.
    func testAgentSheet_afterIssuing_movesToTheRevealOnlyWithTokens() {
        struct Refused: LocalizedError { var errorDescription: String? { "macOS Keychain error: locked" } }
        let token = issuedToken()

        let failed = ExternalAgentSheet.afterIssuing(.failure(Refused()), at: .add, isReissue: false)
        guard case .add = failed.stage else { return XCTFail("a throw stays on the form") }
        XCTAssertEqual(failed.message, "macOS Keychain error: locked")

        let added = ExternalAgentSheet.afterIssuing(.success(.init(tokens: [token], note: nil)), at: .add, isReissue: false)
        guard case .issued(let shown, isReissue: false) = added.stage else {
            return XCTFail("a new agent's token is handed over as a first issue")
        }
        XCTAssertEqual(shown, [token])
        XCTAssertNil(added.message)

        let partly = ExternalAgentSheet.afterIssuing(
            .success(.init(tokens: [token], note: "Not reissued: “Codex”.")), at: .reissue(.all), isReissue: true)
        guard case .issued(_, isReissue: true) = partly.stage else {
            return XCTFail("what was reissued is handed over even when another agent failed")
        }
        XCTAssertEqual(partly.message, "Not reissued: “Codex”.", "the agents left out are said on the reveal")

        let none = ExternalAgentSheet.afterIssuing(
            .success(.init(tokens: [], note: "Not reissued: “Codex”.")), at: .reissue(.all), isReissue: true)
        guard case .reissue(.all) = none.stage else { return XCTFail("nothing issued stays on the confirmation") }
        XCTAssertEqual(none.message, "Not reissued: “Codex”.")

        let empty = ExternalAgentSheet.afterIssuing(.success(.init(tokens: [], note: nil)), at: .add, isReissue: false)
        guard case .add = empty.stage else { return XCTFail("nothing issued stays on the form") }
        XCTAssertNotNil(empty.message, "and says nothing was issued rather than nothing at all")
    }

    /// A copied token leaves the clipboard after `secretLifetime` — a role's sandboxed bash reads
    /// the clipboard (#375) — but only if it is still ours: by content, since Quick Capture's
    /// selection grab restores a snapshot under a new change count.
    func testPasteboard_clearsOnlyTheTokenItPutThere() async throws {
        XCTAssertTrue(ExternalAgentsPasteboard.shouldClear(current: "ntm_a4c36525_x", secret: "ntm_a4c36525_x"))
        XCTAssertFalse(ExternalAgentsPasteboard.shouldClear(current: "something else", secret: "ntm_a4c36525_x"))
        XCTAssertFalse(ExternalAgentsPasteboard.shouldClear(current: nil, secret: "ntm_a4c36525_x"))
        XCTAssertEqual(ExternalAgentsPasteboard.secretLifetime, .seconds(60))

        let kept = NSPasteboard.withUniqueName()
        defer { kept.releaseGlobally() }
        let clearOfKept = ExternalAgentsPasteboard.copySecret("ntm_a4c36525_x", to: kept, lifetime: .milliseconds(20))
        kept.clearContents()
        kept.setString("the person's own", forType: .string)
        await clearOfKept.value
        XCTAssertEqual(kept.string(forType: .string), "the person's own", "copied over: left alone")

        let cleared = NSPasteboard.withUniqueName()
        defer { cleared.releaseGlobally() }
        await ExternalAgentsPasteboard.copySecret("ntm_a4c36525_y", to: cleared, lifetime: .milliseconds(20)).value
        XCTAssertNil(cleared.string(forType: .string), "still ours after the lifetime: cleared")
    }

    /// Quitting inside the minute clears it too — the token would outlive the app on the clipboard,
    /// where the next launch's roles read it.
    func testPasteboard_aQuitClearsThePendingToken() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        ExternalAgentsPasteboard.copySecret("ntm_a4c36525_z", to: pasteboard, lifetime: .seconds(3600))
        let delegate = AppTerminationDelegate()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    /// What the page and the sheet say that the token route cannot say itself: an inherited
    /// environment token, and a running task where a token can be copied.
    func testPageAndSheet_sayWhatTheTokenRouteCannotSayItself() throws {
        let warned = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true, configuredPort: 47321, listenerState: .listening(port: 47321), agents: [],
            presenceByAgent: [:], openTasksByAgent: [:], bashWarnings: [], inheritedTokenAtLaunch: true)
        XCTAssertTrue(warned.environmentTokenWarning?.contains("NANOTEAMS_TOKEN") == true)
        XCTAssertNil(ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true, configuredPort: 47321, listenerState: .listening(port: 47321), agents: [],
            presenceByAgent: [:], openTasksByAgent: [:], bashWarnings: []).environmentTokenWarning)

        func sheet(_ tokens: [ExternalAgentsSettingsView.IssuedAgentTokenItem], running: Bool) -> ExternalAgentSheet.IssuedPresentation {
            ExternalAgentSheet.issuedPresentation(
                tokens: tokens, isReissue: false, port: 47321, executablePath: "/x", home: home, rolesAreRunning: running)
        }
        XCTAssertEqual(sheet([issuedToken()], running: true).clipboardWarning, ExternalAgentSheet.clipboardWarning,
                       "a token can be copied on every hand-over")
        XCTAssertNil(sheet([issuedToken()], running: false).clipboardWarning)
        XCTAssertNil(sheet([], running: true).clipboardWarning, "nothing to copy, nothing to warn about")
    }

    /// The wiring from the store to the sheet: the adapter carries the delivery, the issuers
    /// write the file, and the tab's revoke removes it and says what to remove in the client.
    func testStoreWiring_writesTheFile_andRevokeRemovesItAndSaysWhatIsLeftInTheClient() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nt-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let clientHome = root.appendingPathComponent("home", isDirectory: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        let storage = InMemorySecureTokenStorage()
        let store = TestOrchestrator.make(
            hostedMCPEnvironment: HostedMCPEnvironment(
                directoryURL: { agents }, secretStorage: { storage }, processEnvironment: { [:] },
                allowAutoStart: false, now: { Date() }, clientHomeDirectory: { clientHome }),
            hostedMCPAgentStore: HostedMCPAgentStore(directoryURL: agents, secretStorage: storage))
        let items = try ExternalAgentsSettingsView.tokenIssuers(of: store).addAgent("Claude Code")
        let item = try XCTUnwrap(items.first)
        guard case .written(let url) = item.delivery else { return XCTFail("\(item.delivery)") }
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(url, HostedMCPClientTokenFile.location(shortID: item.shortID, home: clientHome))
        // The revoke says what is left to remove in the CLIENT — NanoTeams removed the token
        // file and the agent, and the entry the person added still names them (#376).
        let afterRevoke = try XCTUnwrap(ExternalAgentsSettingsView.agentRevoker(of: store)(item.id))
        XCTAssertEqual(afterRevoke, Facts.removalHint, "nothing was left behind: \(afterRevoke)")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    /// Reissuing every token keeps going past an agent whose rotation failed, and keeps what it
    /// issued: until 2026-11-08 the loop threw at agent N, after agents 1…N−1 were rotated — their
    /// old tokens dead and their new ones dropped with the error.
    func testBulkRotation_keepsWhatWasIssuedWhenAnAgentFails() {
        let records = ["Claude Code", "Codex", "Cursor"].enumerated().map { index, label in
            HostedMCPAgentRecord(
                id: UUID(), shortID: "s\(index)", label: label,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: nil, clientHint: nil)
        }
        let refused = HostedMCPAgentStoreError.keychainFailure("keychain_unavailable")
        var attempted: [UUID] = []
        let file = HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)!
        let rotation = HostedMCPBulkRotation.rotate(records) { id in
            attempted.append(id)
            guard id != records[1].id else { throw refused }
            let record = records.first { $0.id == id }!
            return HostedMCPTokenHandoff(
                agent: HostedMCPIssuedAgent(record: record, token: "ntm_\(record.shortID)_new"), delivery: .written(file))
        }
        XCTAssertEqual(attempted, records.map(\.id), "every agent is tried, the one after the failure too")
        XCTAssertEqual(rotation.issued.map(\.agent.record.label), ["Claude Code", "Cursor"])
        XCTAssertEqual(rotation.failures, [.init(agentID: records[1].id, label: "Codex", message: refused.message)])

        let nobody = HostedMCPBulkRotation.rotate([]) { _ in XCTFail("no agent, no rotation"); throw refused }
        XCTAssertTrue(nobody.issued.isEmpty)
        XCTAssertTrue(nobody.failures.isEmpty)
    }

    /// A failure the store did not author is reported in the app's own words, never in the
    /// foreign error's localized text — a system-language sentence, possibly with a path, that
    /// would otherwise reach the sheet (`Ratchet/ErrorResponsePinTests`, the rule for this tree).
    func testBulkRotation_saysAForeignFailureInItsOwnWords() {
        let foreign = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSLocalizedDescriptionKey: "Нет прав на запись в /Users/someone/Library/agents.json",
        ])
        let record = HostedMCPAgentRecord(
            id: UUID(), shortID: "s0", label: "Codex",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: nil, clientHint: nil)
        let rotation = HostedMCPBulkRotation.rotate([record]) { _ in throw foreign }
        XCTAssertEqual(rotation.failures.map(\.message), [HostedMCPBulkRotation.unrecognizedFailure])
        XCTAssertFalse(rotation.failures.contains { $0.message.contains("/Users/") }, "no path reaches the sheet")
    }

    /// What the sheet says about a bulk reissue: nothing when every agent got a token; the
    /// agents left out by name, with the fact that their CURRENT tokens still work (a single
    /// rotation that fails changes nothing — `HostedMCPAgentStore.rotateToken`); and a
    /// roster with no agent says that.
    func testIssueResult_fromABulkRotationNamesTheAgentsLeftOut() {
        let id = UUID()
        let record = HostedMCPAgentRecord(
            id: id, shortID: "a4c36525", label: "Claude Code",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: nil, clientHint: nil)
        let issued = HostedMCPTokenHandoff(
            agent: HostedMCPIssuedAgent(record: record, token: "ntm_a4c36525_x"),
            delivery: .written(HostedMCPClientTokenFile.location(shortID: "a4c36525", home: home)!))

        let clean = ExternalAgentSheet.IssueResult(bulk: .init(issued: [issued], failures: []))
        XCTAssertEqual(clean.tokens.map(\.id), [id])
        XCTAssertEqual(clean.tokens.first?.token, "ntm_a4c36525_x")
        XCTAssertNil(clean.note)

        let one = ExternalAgentSheet.IssueResult(bulk: .init(
            issued: [issued], failures: [.init(agentID: UUID(), label: "Codex", message: "macOS Keychain error: locked")]))
        XCTAssertNotNil(one.note)
        let oneNote = one.note ?? ""
        XCTAssertTrue(oneNote.contains("“Codex”"), oneNote)
        XCTAssertTrue(oneNote.contains("macOS Keychain error: locked"), oneNote)
        XCTAssertTrue(oneNote.contains("current token still works"), oneNote)

        let two = ExternalAgentSheet.IssueResult(bulk: .init(issued: [], failures: [
            .init(agentID: UUID(), label: "Codex", message: "m1"), .init(agentID: UUID(), label: "Cursor", message: "m2"),
        ]))
        XCTAssertTrue(two.note?.contains("“Codex”") == true && two.note?.contains("“Cursor”") == true)
        XCTAssertTrue(two.note?.contains("current tokens still work") == true, two.note ?? "")

        let nobody = ExternalAgentSheet.IssueResult(bulk: .init(issued: [], failures: []))
        XCTAssertTrue(nobody.tokens.isEmpty)
        XCTAssertNotNil(nobody.note, "a reissue with no agent to reissue says so")
    }

    /// The sheet hangs on the Settings window's root, ABOVE the tab switch: a button in the main
    /// window (`SettingsNavigation.open(tab:)` — the LLM status, the dictation mic, Quick Capture)
    /// retargets the tab while the sheet is up, and a sheet owned by the External Agents tab went
    /// down with the tab, taking a token nobody had copied (review 2026-11-08).
    func testTheAgentSheetIsPresentedByTheSettingsWindowNotByTheTab() throws {
        let window = try Self.source("NanoTeams/Views/Settings/SettingsView.swift")
        XCTAssertTrue(window.contains(".sheet(item: $externalAgentSheet)"), "the Settings window presents it")
        for tab in ["NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift",
                    "NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsView.swift"] {
            XCTAssertFalse(try Self.source(tab).contains(".sheet("), "\(tab) presents no sheet of its own")
        }
    }

    private static func source(_ path: String) throws -> String {
        RatchetSourceScan.strippingLineComments(try String(
            contentsOf: RatchetSourceScan.repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    /// The page is the server and its agents. It shows no connection fact and no setup prompt of
    /// its own — until 2026-11-12 two cards did, for nobody, with `<agent-id>` standing — and
    /// each agent's row opens the sheet that has both; no client picker is left anywhere.
    func testPageHoldsNoConnectionFacts_theAgentSheetDoes() throws {
        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        for gone in ["connectionCard", "setupPromptCard", "ExternalAgentsConnectionFactRow(", "ExternalAgentsSetupPrompt",
                     "ExternalAgentsConnectionFacts.fields(", "placementRules", "executablePath", "clientHome"] {
            XCTAssertFalse(page.contains(gone), "the page still names \(gone)")
        }
        XCTAssertTrue(page.contains("agentSheet = .connection(row)"), "each agent's row opens its sheet")
        XCTAssertTrue(page.contains("title: \"How to connect\""), "named for what it opens, not as an action")
        XCTAssertTrue(page.contains("agentSheet = .add"))

        let sheet = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentSheet.swift")
        XCTAssertTrue(sheet.contains("ExternalAgentsConnectionFactRow("), "the one row type")
        XCTAssertTrue(sheet.contains("Facts.groups(fields)"), "under their routes")
        XCTAssertTrue(sheet.contains("caption(Facts.placementRules)"), "the rules are said where the configuration is written")
        for file in ["NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift",
                     "NanoTeams/Views/Settings/ExternalAgents/ExternalAgentSheet.swift"] {
            XCTAssertFalse(try Self.source(file).contains("TerminalPicker("), "\(file): no client to pick")
        }
    }

    /// With nobody on the list the Agents card says what adding one gives: the page no longer
    /// shows how a client connects, so this line is where it says that comes with the agent.
    func testEmptyAgentsCard_saysWhatAddingAnAgentGives() throws {
        let hint = ExternalAgentsSettingsPresentation.noAgentsHint
        XCTAssertTrue(hint.hasPrefix("No agents yet."), hint)
        XCTAssertTrue(hint.contains("token"), hint)
        XCTAssertTrue(hint.contains("connect"), hint)
        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        XCTAssertTrue(page.contains("Text(ExternalAgentsSettingsPresentation.noAgentsHint)"), "the page shows it")
    }

    /// Apply stands beside the port only while the draft is not the stored port. A draft that is
    /// no port at all — empty, a word, out of range — still gets it: pressing it is how the page
    /// says what a port is. The caption that spelled the range and the default went with the
    /// permanent button: the refusal says the range, the field's placeholder the default.
    func testPortRow_offersApplyOnlyForAPortThatIsNotTheStoredOne() throws {
        typealias P = ExternalAgentsSettingsPresentation
        XCTAssertFalse(P.showsApply(portDraft: "47321", storedPort: 47_321))
        XCTAssertFalse(P.showsApply(portDraft: "  47321\n", storedPort: 47_321), "spaces around the same port")
        XCTAssertTrue(P.showsApply(portDraft: "47322", storedPort: 47_321))
        XCTAssertTrue(P.showsApply(portDraft: "", storedPort: 47_321), "an emptied field")
        XCTAssertTrue(P.showsApply(portDraft: "   ", storedPort: 47_321))
        XCTAssertTrue(P.showsApply(portDraft: "port", storedPort: 47_321), "not a number")
        XCTAssertTrue(P.showsApply(portDraft: "047321", storedPort: 47_321), "another spelling is still a change to apply")
        XCTAssertTrue(P.showsApply(portDraft: "80", storedPort: 47_321), "out of range: Apply says so")

        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        XCTAssertTrue(page.contains("ExternalAgentsSettingsPresentation.showsApply(portDraft: portDraft, storedPort: storedPort)"))
        XCTAssertFalse(page.contains("default \\(HostedMCPConstants.defaultPort)"), "no caption under the port")
        XCTAssertTrue(page.contains("TextField(String(HostedMCPConstants.defaultPort)"), "the default is the placeholder")
        XCTAssertTrue(page.contains("Enter a port between 1024 and 65535."), "the range is what a refusal says")
    }

    /// Every stage of the sheet draws — the form, the confirmation, the hand-over with facts, the
    /// hand-over of a failed file, and an existing agent's facts — at the sheet's own width, with
    /// the facts folded as a person finds them and unfolded as they are after a click.
    func testAgentSheet_everyStageRenders() throws {
        func sheet(_ stage: ExternalAgentSheet.Stage, unfolded: Bool = false) -> ExternalAgentSheet {
            ExternalAgentSheet(
                opening: stage, existingAgents: [agentRow()], port: 47321,
                executablePath: "/Applications/NanoTeams.app/Contents/MacOS/NanoTeams", clientHome: home, issuers: .inert,
                factsUnfolded: unfolded)
        }
        let stages: [ExternalAgentSheet.Stage] = [
            .add, .reissue(.one(agentRow())), .reissue(.all),
            .issued([issuedToken()], isReissue: false),
            .issued([issuedToken(delivery: failedFile)], isReissue: true),
            .issued([issuedToken(), issuedToken(label: "Codex")], isReissue: true),
            .connection(agentRow()),
        ]
        for stage in stages {
            XCTAssertNotNil(PixelDiff.render(sheet(stage), width: 620, height: 900), "\(stage) drew")
            XCTAssertNotNil(PixelDiff.render(sheet(stage, unfolded: true), width: 620, height: 1400), "\(stage) drew unfolded")
        }
    }

    /// The order of an agent's block (2026-11-12): the simple way — the setup prompt for an
    /// assistant — leads, the token follows ON SHOW since it is handed over once, and the facts
    /// for a client set up by hand come last. Where the token file failed the block is the token
    /// alone. An existing agent's sheet is the same two ways with no name and no token.
    func testAgentSheet_theSimpleWayLeads_theTokenStaysOnShow_theFactsComeLast() throws {
        typealias Sheet = ExternalAgentSheet
        XCTAssertEqual(Sheet.parts(of: block(issuedToken()), isReissue: false), [.name, .setupPrompt, .token, .byHand])
        XCTAssertEqual(Sheet.parts(of: block(issuedToken(delivery: failedFile)), isReissue: false), [.name, .token],
                       "nothing to set up until a reissue writes the file — and the token is still there to copy")
        // A reissue changes the token and nothing else: the clients are set up already, and a
        // bulk reissue would repeat the same card and fold once per agent.
        XCTAssertEqual(Sheet.parts(of: block(issuedToken(), isReissue: true), isReissue: true), [.name, .token])
        XCTAssertEqual(Sheet.parts(of: block(issuedToken(delivery: failedFile), isReissue: true), isReissue: true), [.name, .token])
        XCTAssertEqual(Sheet.connectionParts, [.setupPrompt, .byHand])
        XCTAssertFalse(Sheet.connectionParts.contains(.token), "copied once, when it was issued")

        // Which agents a stage can unfold facts for — and the fold starts closed for a person.
        let row = agentRow()
        let a = UUID(), b = UUID()
        XCTAssertEqual(Sheet.agentIDs(in: .connection(row)), [row.id])
        XCTAssertEqual(Sheet.agentIDs(in: .issued([issuedToken(id: a), issuedToken(id: b)], isReissue: true)), [a, b])
        XCTAssertTrue(Sheet.agentIDs(in: .add).isEmpty)
        XCTAssertTrue(Sheet.agentIDs(in: .reissue(.all)).isEmpty)
        let sheet = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentSheet.swift")
        XCTAssertTrue(sheet.contains("factsUnfolded: Bool = false"), "folded unless a preview or a test opens it")
        XCTAssertTrue(sheet.contains("title: Self.byHandTitle"), "the facts are under a fold")
        XCTAssertTrue(sheet.contains("ForEach(Self.parts(of: block, isReissue: isReissue)"), "the hand-over draws the order it is given")
        XCTAssertTrue(sheet.contains("ForEach(Self.connectionParts"), "and so does the connection stage")
        XCTAssertEqual(Sheet.setupPromptTitle, "Set it up with your assistant")
    }

    /// The stdio bridge is the RUNNING binary with `--mcp-stdio`: a copy launched from anywhere
    /// but /Applications was handed a command pointing at a binary that is not there.
    func testRunningExecutablePath_isTheBundlesOwnExecutable() {
        XCTAssertEqual(Facts.runningExecutablePath, Bundle.main.executablePath ?? Facts.defaultExecutablePath)
    }

    /// What the token does not keep out, said to the person in words (plan §10.1, §11): the
    /// Agents card's footer closes on it. It closed the "Where the token is safe" card until
    /// that card went (2026-11-08), and left the page with it — nothing on screen said any more
    /// that a role's builds, tests and git hooks run outside the sandbox and reach the server.
    /// The footer's first sentence names what ownership refuses: a change, not a look.
    func testAgentsCardFooter_saysWhatTheTokenDoesNotKeepOut() throws {
        let boundary = Facts.honestBoundaryOneLiner
        XCTAssertTrue(boundary.contains("not your roles"))
        XCTAssertTrue(boundary.contains("git hooks"))
        XCTAssertTrue(boundary.contains("outside the sandbox"))
        XCTAssertFalse(boundary.contains("run_xcodebuild"), "a tool identifier says nothing to a person")

        let footer = Facts.agentsCardFooter
        XCTAssertTrue(footer.hasPrefix("Each agent has its own token and changes only the tasks it created"))
        // The one write past its tasks an agent can be allowed (A3 revised, 2026-11-13) is named
        // where the person reads what a token may change.
        XCTAssertTrue(footer.contains("Work Folder Context if you allow it"), footer)
        XCTAssertFalse(footer.contains("sees only"),
                       "list_tasks and task_status show an agent every task; ownership refuses a change")
        XCTAssertTrue(footer.hasSuffix(boundary), "the footer closes on the boundary")

        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        XCTAssertTrue(page.contains("footer: ExternalAgentsConnectionFacts.agentsCardFooter"), "the page shows it")
    }

    // MARK: - The Setup Prompt (#385)

    /// The prompt carries no token, for any agent. It is pasted into an assistant — often one
    /// that is not on this Mac at all, so further outside than any channel #375 closes — and the
    /// header in it keeps `<token>` standing instead, with the instruction to leave it to the
    /// person. The signature cannot even accept a token; this holds the rendering to the same
    /// promise.
    func testSetupPrompt_carriesNoTokenForAnyAgent() {
        for shortID in ["a4c36525", "b7d11e02"] {
            let prompt = ExternalAgentsSetupPrompt.text(port: 47_321, home: home, agentShortID: shortID)
            XCTAssertFalse(prompt.contains(token), shortID)
            XCTAssertFalse(prompt.contains(HostedMCPConstants.tokenPrefix), "\(shortID): no token at all")
            XCTAssertTrue(prompt.contains(Facts.tokenPlaceholder), "the header keeps its placeholder")
            XCTAssertTrue(prompt.contains("paste it in myself"), "and say who fills it in")
            // The same channels no field may use (#375).
            for channel in ["NANOTEAMS_TOKEN", "${env:", "bearer_token_env_var", "env_http_headers", "\"env\""] {
                XCTAssertFalse(prompt.contains(channel), "\(shortID) hands the token over through \(channel)")
            }
        }
    }

    /// Everything a client needs is in it, so the assistant has to invent nothing: the address at
    /// the port the server actually listens on, the header, the call that outlasts the longest
    /// wait, the bridge with the binary that is running and its three arguments, the token file by
    /// absolute path — and no configuration in any client's format, which is the assistant's to
    /// write (until 2026-11-09 the prompt carried six).
    func testSetupPrompt_statesEveryFactAClientNeeds_andNoClientsFormat() {
        let prompt = ExternalAgentsSetupPrompt.text(
            port: 49_123, executablePath: "/x/NanoTeams.app/Contents/MacOS/NanoTeams", home: home,
            agentShortID: "a4c36525")
        XCTAssertTrue(prompt.contains("http://127.0.0.1:49123/mcp"), prompt)
        XCTAssertFalse(prompt.contains("http://localhost"), "Appendix C: the literal address")
        XCTAssertTrue(prompt.contains("not localhost"), "and the assistant is told not to substitute it")
        XCTAssertTrue(prompt.contains("Authorization: Bearer <token>"))
        XCTAssertTrue(prompt.contains("\(ExternalAutovisorToolNames.all.count) tools"))
        XCTAssertTrue(prompt.contains("\(HostedMCPConstants.clientCallTimeoutSeconds) seconds"))
        XCTAssertTrue(prompt.contains("/x/NanoTeams.app/Contents/MacOS/NanoTeams"), "the binary that is running")
        XCTAssertTrue(prompt.contains("--mcp-stdio --token-file /Users/you/.config/nanoteams/a4c36525.token"), prompt)
        XCTAssertTrue(prompt.contains("three arguments"), prompt)
        XCTAssertFalse(prompt.contains("~/.config"), "absolute: an assistant may run with another HOME")
        for format in ["claude mcp", "[mcp_servers", "mcpServers", "promptString", "headersHelper", "httpUrl", "config.toml", "mcp.json"] {
            XCTAssertFalse(prompt.contains(format), "a client's format is the assistant's to write: \(format)")
        }
        // The step people miss: a connected agent that supervises nothing.
        XCTAssertTrue(prompt.contains(AutovisorDriverPicker.label(for: .externalAgent)))
        XCTAssertTrue(prompt.contains(ExternalAutovisorToolNames.folderStatus), "and how to check it worked")
    }

    /// The two moves an assistant makes when the facts run out, closed in words because nothing
    /// in the facts forbids them: exposing a loopback port it cannot reach itself, and writing a
    /// configuration in a format it does not know. Plus the one the page cannot ask for — not to
    /// ask for the token in the conversation.
    func testSetupPrompt_closesWhatTheFactsAloneLeaveOpen() {
        let prompt = ExternalAgentsSetupPrompt.text(home: home, agentShortID: "a4c36525")
        XCTAssertTrue(prompt.contains("Never propose exposing it"))
        for way in ["no tunnel", "no port forwarding", "no proxy", "no third-party bridge"] {
            XCTAssertTrue(prompt.contains(way), way)
        }
        XCTAssertTrue(prompt.contains("you are not the client"), "a chat is told what it is")
        XCTAssertTrue(prompt.contains("Do not invent the client's format"))
        XCTAssertTrue(prompt.contains("Prefer the bridge where the client speaks stdio"), "the route that holds no token")
        XCTAssertTrue(prompt.contains("Do not ask me to paste the token into this conversation"))
        // Where the token may and may not live — the whole list, for the assistant.
        for rule in ["Never in an environment variable", "Never in a file inside a work folder",
                     "shell history", "security tool", "at user level"] {
            XCTAssertTrue(prompt.contains(rule), rule)
        }
    }

    /// The prompt is always an agent's: its token file is named by that agent's id, nothing in
    /// it is left to fill in but the token, and it does not send the assistant to have an agent
    /// added first. Until 2026-11-12 the Settings page offered it for nobody, with `<agent-id>`
    /// in the path and a paragraph about filling it in.
    func testSetupPrompt_isAlwaysAnAgents_withNothingButTheTokenLeftToFillIn() {
        let prompt = ExternalAgentsSetupPrompt.text(home: home, agentShortID: "a4c36525")
        XCTAssertTrue(prompt.contains("/Users/you/.config/nanoteams/a4c36525.token"), prompt)
        XCTAssertFalse(prompt.contains("<agent-id>"), "nothing is left to fill in")
        XCTAssertFalse(prompt.contains("have me do that first"))
        XCTAssertFalse(prompt.contains("-character id"))
        XCTAssertEqual(prompt.components(separatedBy: "<").count - 1, prompt.components(separatedBy: Facts.tokenPlaceholder).count - 1,
                       "the token is the only placeholder in it")
        XCTAssertTrue(prompt.contains("I reissue it there"), "the token was copied once: how to get it again")
        XCTAssertNotEqual(prompt, ExternalAgentsSetupPrompt.text(home: home, agentShortID: "b7d11e02"), "each agent its own")
    }

    /// The prompt is the simple way and leads the agent sheet — the hand-over and an existing
    /// agent's — with that agent's id in it and what Copy takes on show under a fold. Copied as
    /// plain text: it holds no token, so nothing has to be taken back off the clipboard, and it
    /// counts for nothing in `mayCloseWithoutAsking`. The page offers none (it knows no agent).
    func testSetupPrompt_isOfferedInTheAgentSheet_andNotOnThePage() throws {
        let page = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentsSettingsContent.swift")
        XCTAssertFalse(page.contains("copyText("), "nothing on the page is copied any more")
        XCTAssertFalse(page.contains("SettingsDisclosureRow("))

        let sheet = try Self.source("NanoTeams/Views/Settings/ExternalAgents/ExternalAgentSheet.swift")
        XCTAssertTrue(sheet.contains("agentShortID: shortID"), "the sheet fills the agent in")
        XCTAssertTrue(sheet.contains("ExternalAgentsPasteboard.copyText(prompt)"), "no secret, no 60-second clear")
        XCTAssertTrue(sheet.contains("title: \"Show the prompt\""), "what Copy takes is on show")
        func occurrences(_ needle: String, in text: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
        // The one thing copied as a secret is the token; the prompt and the fields are not, so
        // they are not cleared off the clipboard and do not count as the token copied.
        XCTAssertEqual(occurrences("ExternalAgentsPasteboard.copySecret(", in: sheet), 1, "the token alone")
        XCTAssertEqual(occurrences("copiedTokenIDs.insert(", in: sheet), 1, "copying the prompt or a field is not copying the token")
        XCTAssertTrue(ExternalAgentSheet.setupPromptNote.contains("carries no token"))
        XCTAssertTrue(ExternalAgentSheet.connectionNote.contains("cannot be shown again"), "the connection stage says where the token is")
        XCTAssertTrue(ExternalAgentSheet.addCaption.contains("prompt"), "the form says the simple way is the next step")

        // Nothing to set up until the token is reissued: a prompt there would send an assistant
        // to a token file that is not on disk.
        let failed = block(issuedToken(delivery: failedFile))
        XCTAssertTrue(failed.isFailure)
        XCTAssertFalse(failed.offersSetupPrompt)
        XCTAssertFalse(ExternalAgentSheet.parts(of: failed, isReissue: false).contains(.setupPrompt), "and the view draws what the parts say")
        XCTAssertTrue(block(issuedToken()).offersSetupPrompt)
    }

    // MARK: - Listener Status & D11 Port-In-Use Recommendation

    func testListenerStatusPresentation_coversListeningPortInUseAndOff() {
        let offPresentation = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: false,
            configuredPort: 47_321,
            listenerState: .stopped,
            agents: [],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        )
        XCTAssertEqual(offPresentation.listenerStatus, .disabled)
        XCTAssertEqual(offPresentation.listenerStatusTitle, "Off")
        XCTAssertFalse(offPresentation.recommendsTokenRotation)

        let listeningPresentation = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true,
            configuredPort: 47_321,
            listenerState: .listening(port: 47_321),
            agents: [],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        )
        XCTAssertEqual(listeningPresentation.listenerStatus, .listening(port: 47_321))
        // The badge says the state; the address stands beside it in ordinary type, where it
        // can be read and selected (design review 2026-11-07: an address in 10pt capitals).
        XCTAssertEqual(listeningPresentation.listenerStatusTitle, "Listening")
        // Each address carries its OWN port. Written "127.0.0.1 / [::1]:47321" the port binds
        // visually to the IPv6 literal alone — and since `[::1]:47321` is itself a complete
        // address, the eye stops there and reads the IPv4 one as portless. The server binds both
        // or neither (`HostedMCPListener`), it is the same port, and this line is what a person
        // reads when a client will not connect, so it has to be comparable with the client's own
        // config field by field (2026-11-08).
        XCTAssertEqual(listeningPresentation.listenerAddressText, "127.0.0.1:47321 / [::1]:47321")
        XCTAssertEqual(
            listeningPresentation.listenerStatusSentence,
            "Listening on 127.0.0.1:47321 / [::1]:47321")
        XCTAssertEqual(
            listeningPresentation.listenerAddressText?.components(separatedBy: "47321").count, 3,
            "both halves name the port, or the line is ambiguous again")
        XCTAssertFalse(listeningPresentation.recommendsTokenRotation)

        let portInUsePresentation = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true,
            configuredPort: 47_321,
            listenerState: .failed(.portInUse(47_321)),
            agents: [],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        )
        XCTAssertEqual(portInUsePresentation.listenerStatus, .portInUse(port: 47_321))
        XCTAssertEqual(portInUsePresentation.listenerStatusTitle, "Port in use")
        XCTAssertEqual(portInUsePresentation.listenerAddressText, "port 47321")
        XCTAssertEqual(portInUsePresentation.listenerStatusSentence, "Port 47321 is in use")
        XCTAssertTrue(portInUsePresentation.recommendsTokenRotation, "D11: portInUse must recommend rotating tokens")
    }

    /// Every listener state has a short title for the badge, an address where there is one, and
    /// the sentence the Autovisor pane prints; a refusal's message is in the detail, not on the badge.
    func testListenerStatusPresentation_splitsTitleAddressAndDetailForEveryState() {
        func make(enabled: Bool = true, state: HostedMCPListenerState) -> ExternalAgentsSettingsPresentation {
            ExternalAgentsSettingsPresentation.make(
                externalAgentsEnabled: enabled, configuredPort: 47_321, listenerState: state,
                agents: [], presenceByAgent: [:], openTasksByAgent: [:], bashWarnings: [])
        }
        let off = make(enabled: false, state: .listening(port: 47_321))
        XCTAssertEqual(off.listenerStatusTitle, "Off")
        XCTAssertNil(off.listenerAddressText)
        XCTAssertEqual(off.listenerStatusSentence, "Off")

        let starting = make(state: .starting)
        XCTAssertEqual(starting.listenerStatusTitle, "Starting…")
        XCTAssertEqual(starting.listenerAddressText, "port 47321")
        XCTAssertEqual(starting.listenerStatusSentence, "Starting on port 47321…")

        let stopped = make(state: .stopped)
        XCTAssertEqual(stopped.listenerStatusTitle, "Stopped")
        XCTAssertEqual(stopped.listenerAddressText, "port 47321")
        XCTAssertEqual(stopped.listenerStatusSentence, "Stopped")
        XCTAssertTrue(stopped.listenerStatusDetail?.contains("Restart") == true, "what to do, not the port again")

        // Listening and starting say the one fact a person needs about the server — and the same
        // one, so the caption does not jump when the sockets open. No transport names.
        for state in [HostedMCPListenerState.listening(port: 47_321), .starting] {
            XCTAssertEqual(make(state: state).listenerStatusDetail, "Reachable only from this Mac.")
        }
        // A port in use has its own block in the card, with the title, the risk and the button;
        // a caption under the card saying it a third time was dropped.
        XCTAssertNil(make(state: .failed(.portInUse(47_321))).listenerStatusDetail)
        XCTAssertNotNil(off.listenerStatusDetail)

        let failed = make(state: .failed(.bindFailed("no route")))
        XCTAssertEqual(failed.listenerStatus, .failed(message: "Could not start the server: no route"))
        XCTAssertEqual(failed.listenerStatusTitle, "Not started")
        XCTAssertNil(failed.listenerAddressText)
        let failedDetail = failed.listenerStatusDetail ?? ""
        XCTAssertTrue(failedDetail.hasPrefix("Could not start the server: no route."), failedDetail)
        XCTAssertTrue(failedDetail.contains("restart the server"), failedDetail)
        XCTAssertEqual(failed.listenerStatusSentence, "Could not start the server: no route")
        XCTAssertFalse(failed.recommendsTokenRotation)

        // `formatListenerStatus` is the pane's one-line form of the same facts.
        XCTAssertEqual(
            ExternalAgentsSettingsPresentation.formatListenerStatus(enabled: true, configuredPort: 47_321, state: .listening(port: 47_321)),
            "Listening on 127.0.0.1:47321 / [::1]:47321")
        XCTAssertEqual(
            ExternalAgentsSettingsPresentation.formatListenerStatus(enabled: false, configuredPort: 47_321, state: .stopped),
            "Off")
    }

    // MARK: - Agent Rows, Presence, Open Tasks & A8 Warnings

    func testAgentRowAndBashWarningsPresentation() {
        let agentID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let lastSeen = Date(timeIntervalSince1970: 1_700_000_060)
        let record = HostedMCPAgentRecord(
            id: agentID,
            shortID: "a1b2c3d4",
            label: "Claude Code",
            createdAt: created,
            rotatedAt: nil,
            lastSeenAt: lastSeen,
            clientHint: "claude-code"
        )
        let warnings = BashSecurityWarning.evaluate(
            policy: BashPolicy(
                mode: .manual,
                sandboxEnabled: false,
                allowUnsandboxedFallback: true
            ),
            driver: .externalAgent,
            externalAgentsEnabled: true
        )
        XCTAssertEqual(warnings.count, 2)

        let presentation = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true,
            configuredPort: 47_321,
            listenerState: .listening(port: 47_321),
            agents: [record],
            presenceByAgent: [agentID: true],
            openTasksByAgent: [agentID: 2],
            bashWarnings: warnings
        )
        XCTAssertEqual(presentation.agentRows.count, 1)
        let row = presentation.agentRows[0]
        XCTAssertEqual(row.id, agentID)
        XCTAssertEqual(row.label, "Claude Code")
        XCTAssertEqual(row.shortID, "a1b2c3d4")
        XCTAssertTrue(row.isPresent)
        XCTAssertEqual(row.openTasksCount, 2)
        XCTAssertFalse(row.mayReplaceWorkFolderContext, "a record with the switch off shows it off")
        XCTAssertEqual(presentation.bashWarnings, warnings)
    }

    /// The switch on the row is the record's: a mapping that dropped it would show an agent the
    /// store lets replace the context as one it does not (review, 2026-11-13).
    func testAgentRow_showsTheRecordsContextSwitch() {
        var allowed = HostedMCPAgentRecord(
            id: UUID(), shortID: "a1b2c3d4", label: "Claude Code",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeenAt: nil, clientHint: nil)
        allowed.mayReplaceWorkFolderContext = true
        var notAllowed = allowed
        notAllowed.id = UUID()
        notAllowed.mayReplaceWorkFolderContext = false

        let rows = ExternalAgentsSettingsPresentation.make(
            externalAgentsEnabled: true,
            configuredPort: 47_321,
            listenerState: .listening(port: 47_321),
            agents: [allowed, notAllowed],
            presenceByAgent: [:],
            openTasksByAgent: [:],
            bashWarnings: []
        ).agentRows

        XCTAssertEqual(rows.map(\.mayReplaceWorkFolderContext), [true, false])
    }

    // MARK: - Concealed Pasteboard Copy (§10.2.5)

    func testConcealedPasteboardCopy_setsCurrentHostOnlyAndConcealedType() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let token = "ntm_a1b2c3d4_secretvalue123"
        let before = pasteboard.changeCount
        ExternalAgentsPasteboard.copySecret(token, to: pasteboard)
        // ONE generation: the one `prepareForNewContents(with: .currentHostOnly)` marked local.
        // `declareTypes` after it began a second, unmarked one — the token could leave the Mac
        // over Universal Clipboard (review 2026-11-08).
        XCTAssertEqual(pasteboard.changeCount, before + 1)

        XCTAssertEqual(pasteboard.string(forType: .string), token)
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        XCTAssertNotNil(
            pasteboard.data(forType: concealedType),
            "One-time token copy must mark pasteboard with org.nspasteboard.ConcealedType (§10.2.5)"
        )
        XCTAssertEqual(
            ExternalAgentsPasteboard.concealedPasteboardType, PasteboardItemSnapshot.concealedType,
            "one source with whoever puts a concealed item back on the clipboard")
    }

    /// Quick Capture's selection grab snapshots the clipboard, synthesizes ⌘C and puts the
    /// snapshot back — a NEW generation. `.currentHostOnly` is a property of the generation, not
    /// of the items, so the restore published the token Universal-Clipboard-eligible one line
    /// after the copy had marked it local (#376). The restore now carries the marking over.
    func testClipboardRestore_ofAConcealedItem_staysLocalToThisMac() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let token = "ntm_a1b2c3d4_secretvalue123"
        ExternalAgentsPasteboard.copySecret(token, to: pasteboard)
        let snapshot = [PasteboardItemSnapshot(dataByType: [
            .string: Data(token.utf8),
            PasteboardItemSnapshot.concealedType: Data(),
        ])]

        // A host-only generation refuses to be read by another host, which cannot be probed
        // here. What IS pinned is that the restore goes through `prepareForNewContents(with:)`
        // rather than a bare `writeObjects` — one generation, not two. The live adapter runs on
        // a pasteboard of its own: the general one is shared by every process on the Mac, and a
        // parallel runner's writes moved its change count under this assertion (147 for 144,
        // 2026-11-08) — besides putting a token on the person's real clipboard and clearing it.
        XCTAssertEqual(SystemPasteboard().name, .general, "the app's adapter is the clipboard")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let before = board.changeCount
        let restored = ClipboardCaptureService.applyRestore(
            .rewrite(snapshot), to: SystemPasteboard(name: board.name))
        XCTAssertTrue(restored)
        XCTAssertEqual(
            board.changeCount, before + 1,
            "one generation: `write` begins it itself, so the bare clear before it is gone")
        XCTAssertEqual(board.string(forType: .string), token)
    }

    /// The 60-second clear fired while the captured selection was on the clipboard, saw a
    /// different string, cleared nothing and DROPPED the handle — after which the restore put
    /// the token back and nothing, the quit-time clear included, ever took it off (#376).
    func testClearPendingSecret_survivesAnInterveningClipboardWrite() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let token = "ntm_a1b2c3d4_secretvalue123"
        // A lifetime long enough that the timer does not fire during the test.
        ExternalAgentsPasteboard.copySecret(token, to: pasteboard, lifetime: .seconds(600))

        // Something else takes the clipboard — Quick Capture's synthesized ⌘C. The quit-time
        // clear takes back only the token it put there, and forgets the handle, since a quit
        // has no later pass.
        ExternalAgentsPasteboard.copyText("a selected sentence", to: pasteboard)
        ExternalAgentsPasteboard.clearPendingSecret()
        XCTAssertEqual(
            pasteboard.string(forType: .string), "a selected sentence",
            "the clear only ever takes back the token it put there")

        // The timer's own passes keep the handle until the LAST one, which is what lets a
        // restore landing after a successful clear still be taken back (#382).
        let again = ExternalAgentsPasteboard.copySecret(
            token, to: pasteboard, lifetime: .milliseconds(10))
        ExternalAgentsPasteboard.copyText("a selected sentence", to: pasteboard)
        _ = await again.value
        ExternalAgentsPasteboard.copyText(token, to: pasteboard)
        ExternalAgentsPasteboard.clearPendingSecret()
        XCTAssertEqual(
            pasteboard.string(forType: .string), token,
            "the final pass forgot the handle: after the lifetime and its re-check, that text is "
                + "the person's own and NanoTeams does not take it back")
    }

    /// The warning the copy shows is about ROLES reading the clipboard, and a task reports what
    /// it is waiting for while its other roles keep working (CLAUDE.md #45).
    func testRolesAreRunning_countsTheStatesThatParkOneRoleAndRunAnother() {
        for state in [TeamEngineState.running, .needsAcceptance, .needsSupervisorInput] {
            XCTAssertTrue(
                ExternalAgentsSettingsView.statesWithPossiblyLiveRoles.contains(state),
                "\(state) may have a live role")
        }
        for state in [TeamEngineState.pending, .paused, .done, .failed] {
            XCTAssertFalse(
                ExternalAgentsSettingsView.statesWithPossiblyLiveRoles.contains(state),
                "\(state) has none")
        }
    }

    // MARK: - C7: AutovisorSettingsPresentation (.builtInModel vs .externalAgent)

    func testAutovisorSettingsPresentation_builtInModelMode() {
        let tuning = AutovisorTuning()
        let pres = AutovisorSettingsPresentation.make(
            driver: .builtInModel,
            readiness: ExternalAutovisorReadiness(state: .builtInDriver, reason: "Built-in model is active."),
            tuning: tuning,
            bashWarnings: []
        )
        XCTAssertEqual(pres.driver, .builtInModel)
        XCTAssertTrue(pres.showsModelCard)
        XCTAssertTrue(pres.showsIntervalRowInActivationCard)
        XCTAssertTrue(pres.showsRunNowInPowerCard)
        XCTAssertFalse(pres.marksActivationTriggersBuiltInOnly)
        XCTAssertFalse(pres.showsExternalLimits)
        XCTAssertFalse(pres.isMemoryReadOnly)
        XCTAssertFalse(pres.sleepTimerCountsFromAgentActivity)
        XCTAssertTrue(pres.powerCaption.contains("watches all tasks"))
        XCTAssertTrue(pres.showsGoalCard)
        XCTAssertTrue(pres.showsTeamsCard)
        XCTAssertTrue(pres.showsStuckCard)
    }

    func testAutovisorSettingsPresentation_externalAgentMode() {
        let tuning = AutovisorTuning()
        let warnings = [BashSecurityWarning.sandboxDisabled(externalAgentActive: true)]
        let pres = AutovisorSettingsPresentation.make(
            driver: .externalAgent,
            readiness: ExternalAutovisorReadiness(state: .ready, reason: nil),
            tuning: tuning,
            bashWarnings: warnings
        )
        XCTAssertEqual(pres.driver, .externalAgent)
        XCTAssertFalse(pres.showsModelCard, "C7: Model card must be completely hidden when driver == .externalAgent")
        XCTAssertFalse(pres.showsIntervalRowInActivationCard, "C7: Interval row inside Activation card must be hidden")
        XCTAssertFalse(pres.showsRunNowInPowerCard, "C7: Run now button inside Power card must be hidden")
        XCTAssertTrue(pres.marksActivationTriggersBuiltInOnly, "C7: Activation triggers are marked built-in only")
        XCTAssertEqual(pres.activationTriggersBuiltInBadgeText, "built-in model only")
        XCTAssertTrue(pres.showsExternalLimits, "C7: External creation limits must be shown")
        XCTAssertEqual(pres.maxExternalCreationsPerWindow, 5)
        XCTAssertEqual(pres.externalCreationWindowMinutes, 15)
        XCTAssertEqual(pres.maxOpenExternalTasks, 3)
        XCTAssertTrue(pres.isMemoryReadOnly, "C7: Memory card must be read-only when driver == .externalAgent")
        XCTAssertTrue(pres.sleepTimerCountsFromAgentActivity, "C7: Sleep timer caption counts from last agent activity")
        XCTAssertTrue(pres.sleepTimerCaption.contains("agent's last request"))
        // A3: the external agent supervises only its own tasks — the built-in caption ("watches
        // all tasks … keeps the goal, memory, and shared context current") would be false here —
        // and replaces the shared context only where the person allows it (A3 revised, 2026-11-13).
        XCTAssertTrue(pres.powerCaption.contains("tasks it creates"))
        XCTAssertFalse(pres.powerCaption.contains("watches all tasks"))
        XCTAssertTrue(pres.powerCaption.contains("only if you allow it"), pres.powerCaption)
        XCTAssertTrue(pres.showsGoalCard, "C7: Goal card stays active")
        XCTAssertTrue(pres.showsTeamsCard, "C7: Teams card stays active")
        XCTAssertTrue(pres.showsStuckCard, "C7: Stuck Detector card stays active")
        XCTAssertEqual(pres.bashWarnings, warnings)
    }

    // MARK: - View Composition & Orchestrator Integration

    func testViewsComposeAndRotateAllTokensOnPortInUse() async throws {
        let store = TestOrchestrator.make()
        let created = try store.hostedMCPAgentStore.createAgent(label: "Agent One", clientHint: "codex")
        XCTAssertTrue(created.token.hasPrefix("ntm_"))
        XCTAssertEqual(
            store.hostedMCPAgentStore.verifyBearerToken(created.token),
            .authenticated(created.record.identity)
        )

        // Rotate all tokens helper (D11 action on portInUse)
        let rotation = store.rotateAllHostedMCPAgentTokens()
        XCTAssertTrue(rotation.failures.isEmpty)
        let rotated = rotation.issued
        XCTAssertEqual(rotated.count, 1)
        XCTAssertEqual(
            store.hostedMCPAgentStore.verifyBearerToken(created.token),
            .invalidToken,
            "Old token must be immediately invalidated after rotation"
        )
        XCTAssertEqual(
            store.hostedMCPAgentStore.verifyBearerToken(rotated[0].agent.token),
            .authenticated(rotated[0].agent.record.identity),
            "New rotated token must authenticate"
        )

        let externalAgentsView = ExternalAgentsSettingsView(agentSheet: .constant(nil))
            .environment(store)
        let hosting1 = NSHostingView(rootView: externalAgentsView)
        hosting1.frame = NSRect(x: 0, y: 0, width: 720, height: 800)
        hosting1.layoutSubtreeIfNeeded()

        let autovisorView = AutovisorSettingsView()
            .environment(store)
            .environment(ModelCatalog())
        let hosting2 = NSHostingView(rootView: autovisorView)
        hosting2.frame = NSRect(x: 0, y: 0, width: 720, height: 800)
        hosting2.layoutSubtreeIfNeeded()
    }

    func testHostedMCPAgentStoreError_localizedDescriptionSurfacesHumanReadableMessage() {
        let errors: [HostedMCPAgentStoreError] = [
            .emptyLabel,
            .agentNotFound(UUID()),
            .randomGenerationFailed,
            .keychainFailure("keychain_write_failed"),
            .storageWriteFailed("agents_file_write_failed")
        ]
        for err in errors {
            let asError: any Error = err
            XCTAssertEqual(
                asError.localizedDescription,
                err.message,
                "HostedMCPAgentStoreError must conform to LocalizedError so UI error banners display err.message"
            )
            XCTAssertFalse(
                asError.localizedDescription.contains("NanoTeams.HostedMCPAgentStoreError"),
                "localizedDescription must not fall back to generic NSError domain string"
            )
        }
    }

    func testHostedMCPAgentsRevision_incrementsOnAgentCreateRotateVerifyAndRevoke() throws {
        let store = TestOrchestrator.make()
        let initialRev = store.hostedMCPAgentsRevision

        let issued = try store.hostedMCPAgentStore.createAgent(label: "Reactive Agent")
        let afterCreateRev = store.hostedMCPAgentsRevision
        XCTAssertGreaterThan(afterCreateRev, initialRev)

        _ = store.hostedMCPAgentStore.verifyBearerToken(issued.token)
        let afterVerifyRev = store.hostedMCPAgentsRevision
        XCTAssertGreaterThan(afterVerifyRev, afterCreateRev)

        let rotated = try store.hostedMCPAgentStore.rotateToken(agentID: issued.record.id)
        let afterRotateRev = store.hostedMCPAgentsRevision
        XCTAssertGreaterThan(afterRotateRev, afterVerifyRev)

        try store.hostedMCPAgentStore.revokeAgent(agentID: rotated.record.id)
        let afterRevokeRev = store.hostedMCPAgentsRevision
        XCTAssertGreaterThan(afterRevokeRev, afterRotateRev)
    }
}
