import SwiftUI
import XCTest
@testable import NanoTeams

/// The picker's MCP half. Every rule here is about what a person can DO to a grant — which is
/// the half a catalogue cannot answer on its own, and the half that decides whether a warning
/// the team editor raises has a repair anywhere in the app.
final class ToolSelectionMCPSectionsTests: XCTestCase {

    private let folioID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    private let investID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    /// Folio connected — `get_screenshot` approved, `get_design_context` awaiting review —
    /// and Trade-Room configured but switched off.
    private func catalogue() throws -> MCPGrantCatalogue {
        MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(slug: "trade_room", id: investID, status: .disabled, standing: .switchedOff),
            try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, tools: [
                try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_screenshot"),
                try MCPGrantCatalogueTests.makeTool(
                    slug: "folio", tool: "get_design_context", pinState: .new),
            ]),
        ])
    }

    private func sections(
        selected: Set<String> = [], search: String = "", approval: ToolApprovalAvailability = .available
    ) throws -> [MCPToolSection] {
        MCPToolSectionBuilder.sections(
            catalogue: try catalogue(), selected: selected, searchText: search, approval: approval)
    }

    /// The availability the role editor hands the picker, derived where the app derives it
    /// (`ToolApprovalAvailability.forTeam`): a team in `mode`, no Autovisor. The families' own
    /// modes are Auto so nothing but the presence moves.
    private func availability(_ mode: SupervisorMode) -> ToolApprovalAvailability {
        var team = TeamTemplateFactory.startup()
        team.settings.supervisorMode = mode
        return .forTeam(bashMode: .auto, computerUseMode: .auto, team: team, workFolderSettings: nil)
    }

    private func row(_ name: String, in sections: [MCPToolSection]) throws -> MCPToolRow {
        try XCTUnwrap(sections.lazy.flatMap(\.rows).first { $0.name == name }, name)
    }

    // MARK: - Shape

    func testOneSectionPerConfiguredServerInSlugOrder() throws {
        XCTAssertEqual(try sections().map(\.slug), ["folio", "trade_room"])
    }

    /// A switched-off server still gets a header: it is the one place the whole-server grant
    /// can be switched on before the server ever answers.
    func testAServerWithNoToolsStillGetsItsHeader() throws {
        let invest = try XCTUnwrap(try sections().first { $0.slug == "trade_room" })

        XCTAssertTrue(invest.rows.isEmpty)
        XCTAssertEqual(invest.grantName, "mcp__trade_room")
        XCTAssertEqual(invest.statusNote, "Off")
    }

    /// The quiet case carries no chrome — a working server's header says nothing extra.
    func testAConnectedServerHasNoStatusNote() throws {
        XCTAssertNil(try sections().first { $0.slug == "folio" }?.statusNote)
    }

    // MARK: - The line under an empty header

    /// The line under a server that publishes nothing reads the state the header's note reads,
    /// and waits for an answer only from a server that is still trying. An Off server's header
    /// already says Off, a server that needs a person already says so, and neither will answer
    /// on its own — so neither gets a line promising it will. A server that answered with an
    /// empty catalogue has answered.
    ///
    /// RED until 2026-09-24: every empty section read "No tools yet — they appear once the
    /// server answers.", under "TRADE ROOM Off" too, above the grants F45 keeps listed there.
    func testTheEmptyLineWaitsForAnAnswerOnlyFromAServerThatIsStillTrying() throws {
        func section(_ status: MCPServerStatus, tools: [MCPGrantCatalogue.Tool] = []) throws -> MCPToolSection {
            let catalogue = MCPGrantCatalogue(servers: [
                try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, status: status, tools: tools),
            ])
            return try XCTUnwrap(MCPToolSectionBuilder.sections(
                catalogue: catalogue, selected: ["mcp__folio__get_screenshot"], searchText: "",
                approval: .available).first)
        }
        for status: MCPServerStatus in [.connecting, .failed(reason: "refused")] {
            XCTAssertEqual(try section(status).emptyLine,
                           "No tools yet — they appear once the server answers.", "\(status)")
        }
        for status: MCPServerStatus in [
            .disabled, .needsAuth(reason: "401"), .unsupportedTransport(reason: "http"), .incompatible(reason: "v"),
        ] {
            let quiet = try section(status)
            XCTAssertNil(quiet.emptyLine, "\(status)")
            XCTAssertEqual(quiet.statusNote, quiet.standing.label, "the header names the state instead")
        }
        XCTAssertEqual(try section(.disabled).standing, .notRunning)
        XCTAssertEqual(try section(.connected(era: .modern)).emptyLine, "The server publishes no tools.")
        XCTAssertNil(try section(.connected(era: .modern), tools: [
            try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_screenshot"),
        ]).emptyLine, "a server that publishes something has no empty line")
    }

    /// A server that published tools of which roles can be offered none — its listing collided,
    /// or the app could not read one entry of it — is not a server that publishes nothing: its
    /// section says none can be offered, and where to see why. The APP's refusal, worded apart
    /// from a text the person refused (`.mcpToolRefused`, "You rejected…"). A server not
    /// connected still reads its status's line. `MCPServerManagerTests` drives both causes
    /// through a real connection.
    ///
    /// RED until 2026-10-28: "The server publishes no tools." for both.
    func testAServerWhoseToolsCannotBeOfferedSaysSoRatherThanPublishingNothing() throws {
        func section(_ status: MCPServerStatus, nothingOffered: Bool) throws -> MCPToolSection {
            let catalogue = MCPGrantCatalogue(servers: [
                try MCPGrantCatalogueTests.makeServer(
                    slug: "folio", id: folioID, status: status, nothingOffered: nothingOffered),
            ])
            return try XCTUnwrap(MCPToolSectionBuilder.sections(
                catalogue: catalogue, selected: [], searchText: "", approval: .available).first)
        }
        let unofferable = try section(.connected(era: .modern), nothingOffered: true)
        XCTAssertTrue(unofferable.nothingItPublishesCanBeOffered)
        XCTAssertEqual(unofferable.emptyLine, "None of what it publishes can be offered — see Settings → MCP Servers.")
        XCTAssertFalse(try XCTUnwrap(unofferable.emptyLine).contains("reject"), "not the person's refusal")
        XCTAssertTrue(try XCTUnwrap(unofferable.emptyLine).contains(SettingsView.SettingsTab.mcpServers.rawValue))

        XCTAssertEqual(try section(.connected(era: .modern), nothingOffered: false).emptyLine,
                       "The server publishes no tools.")
        XCTAssertEqual(try section(.connecting, nothingOffered: true).emptyLine,
                       "No tools yet — they appear once the server answers.", "the status speaks first")
        XCTAssertNil(try section(.disabled, nothingOffered: true).emptyLine)
    }

    /// Under a section that says none of what its server publishes can be offered, a grant the
    /// role holds of one of those tools does not say the opposite — that the server does not
    /// offer it and the role should drop it. It names the app's refusal and sends the person to
    /// the same page the section line does; only a name the listing did not publish at all is
    /// the server's to have withdrawn.
    ///
    /// RED until 2026-10-28: the row read "Its MCP server does not offer this tool —
    /// uncheck it here" directly under "None of what it publishes can be offered".
    func testAHeldGrantOfAToolTheAppCannotOfferAgreesWithItsSectionsLine() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(
                slug: "orders", id: folioID, nothingOffered: true,
                refused: ["mcp__orders__get_orders", "mcp__orders__list_items"]),
        ])
        let all = MCPToolSectionBuilder.sections(
            catalogue: catalogue, selected: ["mcp__orders__get_orders", "mcp__orders__gone"], searchText: "",
            approval: .available)
        let section = try XCTUnwrap(all.first)
        let line = try XCTUnwrap(section.emptyLine)
        XCTAssertEqual(line, "None of what it publishes can be offered — see Settings → MCP Servers.")

        let held = try row("mcp__orders__get_orders", in: all)
        XCTAssertEqual(held.requirement, .mcpToolNotOfferable)
        let hint = try XCTUnwrap(held.trailingNote)
        XCTAssertFalse(hint.contains("does not offer"), "the section says the server publishes it: \(hint)")
        XCTAssertFalse(hint.contains("uncheck"), "the grant is not the fault: \(hint)")
        XCTAssertTrue(hint.hasSuffix("see Settings → MCP Servers"), "the page the section line points at: \(hint)")
        XCTAssertTrue(held.isSelectable(isSelected: true), "a held grant can still be unchecked")
        XCTAssertFalse(held.isOn(isSelected: false), "it brings nothing")

        XCTAssertEqual(try row("mcp__orders__gone", in: all).requirement, .mcpToolNotOffered,
                       "a name the listing did not publish is the server's to have withdrawn")
    }

    // MARK: - Selectability

    func testAReviewedToolCanBeChecked() throws {
        let row = try XCTUnwrap(try sections().first?.rows.first { $0.name.hasSuffix("screenshot") })

        XCTAssertNil(row.requirement)
        XCTAssertTrue(row.isSelectable(isSelected: false))
    }

    func testAnUnreviewedToolCannotBeChecked() throws {
        let row = try XCTUnwrap(try sections().first?.rows.first { $0.name.hasSuffix("context") })

        XCTAssertEqual(row.requirement, .mcpToolUnreviewed)
        XCTAssertFalse(row.isSelectable(isSelected: false))
    }

    /// The rule that makes every warning actionable: what the app cannot honour can still be
    /// REMOVED. A row frozen in the checked state would leave the person reading "this grant
    /// resolves to nothing" with nowhere to act on it.
    func testAWithheldToolThatIsAlreadyHeldCanStillBeUnchecked() throws {
        let held = "mcp__folio__get_design_context"
        let row = try XCTUnwrap(
            try sections(selected: [held]).first?.rows.first { $0.name == held })

        XCTAssertTrue(row.isSelectable(isSelected: true))
    }

    // MARK: - The whole-server grant

    func testHoldingTheServerGrantMarksEveryRowAsCovered() throws {
        let rows = try XCTUnwrap(try sections(selected: ["mcp__folio"]).first?.rows)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy(\.coveredByServerGrant))
    }

    func testWithoutTheServerGrantNoRowClaimsCoverage() throws {
        XCTAssertTrue(try sections().allSatisfy { $0.rows.allSatisfy { !$0.coveredByServerGrant } })
    }

    // MARK: - Search

    func testSearchingTheServerNameKeepsAllOfItsRows() throws {
        let found = try sections(search: "folio")

        XCTAssertEqual(found.map(\.slug), ["folio"])
        XCTAssertEqual(found.first?.rows.count, 2)
    }

    func testSearchingAToolNameNarrowsToThatRow() throws {
        let found = try sections(search: "screenshot")

        XCTAssertEqual(found.map(\.slug), ["folio"])
        XCTAssertEqual(found.first?.rows.map(\.name), ["mcp__folio__get_screenshot"])
    }

    /// A server whose name does not match and whose tools do not either drops out entirely —
    /// otherwise a search would leave a page of empty headers.
    func testAServerThatMatchesNothingDropsOut() throws {
        XCTAssertTrue(try sections(search: "nothing_here").isEmpty)
    }

    // MARK: - Grants nothing can place

    func testAGrantOfADeletedServerIsListedSoItCanBeRemoved() throws {
        let orphans = MCPToolSectionBuilder.unplaceableGrants(
            catalogue: try catalogue(),
            selected: ["mcp__gone__x", "mcp__folio__get_screenshot", ToolNames.readFile],
            searchText: "")

        XCTAssertEqual(orphans, ["mcp__gone__x"])
    }

    /// An unreviewed tool is placeable — it has a row in its server's section, disabled. It
    /// must not ALSO appear under "no such server", or the same grant would be in two places.
    func testAnUnreviewedToolIsNotCalledUnplaceable() throws {
        let orphans = MCPToolSectionBuilder.unplaceableGrants(
            catalogue: try catalogue(),
            selected: ["mcp__folio__get_design_context"],
            searchText: "")

        XCTAssertTrue(orphans.isEmpty)
    }

    func testABuiltInToolIsNeverCalledUnplaceable() throws {
        XCTAssertTrue(MCPToolSectionBuilder.unplaceableGrants(
            catalogue: .empty, selected: [ToolNames.readFile, ToolNames.search],
            searchText: "").isEmpty)
    }

    /// With no catalogue at all every MCP grant the role holds is unplaceable — which is what
    /// puts it on screen, removable, instead of vanishing.
    func testWithNoCatalogueEveryGrantIsUnplaceable() {
        XCTAssertEqual(
            MCPToolSectionBuilder.unplaceableGrants(
                catalogue: .empty, selected: ["mcp__folio", "mcp__folio__x"], searchText: ""),
            ["mcp__folio", "mcp__folio__x"])
    }

    func testTheUnplaceableListHonoursTheSearch() throws {
        XCTAssertTrue(MCPToolSectionBuilder.unplaceableGrants(
            catalogue: try catalogue(), selected: ["mcp__gone__x"], searchText: "folio").isEmpty)
    }

    func testAnEmptyCatalogueProducesNoSections() {
        XCTAssertTrue(MCPToolSectionBuilder.sections(
            catalogue: .empty, selected: [], searchText: "", approval: .available).isEmpty)
    }

    // MARK: - A grant of a server that is off, connecting or failed (F45)

    /// Switching a server off is reversible, and a role granting its tools is not thereby
    /// misconfigured: the grant stays in its server's section, saying the server is off — not
    /// under "No such server", telling the person to uncheck it.
    ///
    /// RED until 2026-09-24: a switched-off server publishes no tools, so its per-tool grants
    /// fell out of `grantableToolIDs` and were filed as unplaceable (F45).
    func testAGrantOfASwitchedOffServerIsNotUnplaceable() throws {
        let held = "mcp__trade_room__get_orders"
        XCTAssertTrue(MCPToolSectionBuilder.unplaceableGrants(
            catalogue: try catalogue(), selected: [held], searchText: "").isEmpty)

        let invest = try XCTUnwrap(try sections(selected: [held]).first { $0.slug == "trade_room" })
        let row = try XCTUnwrap(invest.rows.first { $0.name == held })
        XCTAssertEqual(row.requirement, .mcpServerDisabled)
        XCTAssertTrue(row.isSelectable(isSelected: true), "it can still be removed here")
        XCTAssertTrue(invest.publishesNoTools)
        XCTAssertNil(invest.emptyLine, "the header says Off; no line promises an answer above the grant")
    }

    /// The header and the Settings list read ONE standing — the manager's (`MCPServerStanding`) —
    /// so for every standing that is not a quiet connection the header's note IS the list's
    /// subtitle, word for word, and a quiet connection has none. Every standing, every status
    /// under `.running`; the empty line waits for an answer only from a server still trying.
    ///
    /// RED until 2026-10-28: the header read the runtime status, which says "Off" of a server
    /// off in this folder or not running, and nothing of one missing its token.
    func testTheHeaderSaysWhatTheListSaysForEveryStanding() throws {
        let statuses: [MCPServerStanding.RunningStatus] = [
            .connecting, .connected(era: .modern), .connected(era: .legacy), .needsAuth(reason: "401"),
            .failed(reason: "refused"), .unsupportedTransport(reason: "plain http"), .incompatible(reason: "2027-01-01"),
        ]
        let standings: [MCPServerStanding] =
            [.switchedOff, .offInThisFolder, .needsToken, .notRunning] + statuses.map { .running($0) }
        let config = MCPServerConfig(
            slug: try XCTUnwrap(MCPServerSlug("folio")), displayName: "folio",
            transport: .http(MCPHTTPConfig(urlString: "https://a.test/mcp")))
        for standing in standings {
            let status: MCPServerStatus
            if case .running(let running) = standing { status = running.status } else { status = .disabled }
            let catalogue = MCPGrantCatalogue(servers: [
                try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, status: status, standing: standing),
            ])
            let section = try XCTUnwrap(MCPToolSectionBuilder.sections(
                catalogue: catalogue, selected: [], searchText: "", approval: .available).first, "\(standing)")
            let row = MCPServerRow(
                config: config, status: status, standing: standing, isAllowedInThisFolder: true, hasRequiredSecrets: true)
            if standing.isQuietlyConnected {
                XCTAssertNil(section.statusNote, "\(standing)")
                XCTAssertTrue(row.subtitle.hasPrefix("Connected"), "\(standing): \(row.subtitle)")
            } else {
                XCTAssertEqual(section.statusNote, row.subtitle, "\(standing)")
                XCTAssertEqual(section.statusNote, standing.label, "\(standing)")
            }
            let waits: Bool
            switch standing {
            case .running(.connecting), .running(.failed): waits = true
            default: waits = false
            }
            XCTAssertEqual(section.emptyLine == "No tools yet — they appear once the server answers.", waits,
                           "\(standing): \(section.emptyLine ?? "(none)")")
        }
        XCTAssertEqual(MCPServerStanding.offInThisFolder.label, "Off in this folder")
        XCTAssertEqual(MCPServerStanding.notRunning.label, "Not running")
        XCTAssertEqual(MCPServerStanding.needsToken.label, "Needs a token")
        XCTAssertEqual(MCPServerStanding.switchedOff.label, "Off")
    }

    /// Each standing that runs nothing files a held grant under its own repair, and the words say
    /// which — never "switched off — turn it on" of a server whose switch is on.
    func testAHeldGrantNamesTheRepairItsServersStandingNeeds() throws {
        let rows: [(MCPServerStanding, MCPServerStatus, ToolAvailabilityRequirement, String)] = [
            (.switchedOff, .disabled, .mcpServerDisabled, "switched off — turn it on"),
            (.offInThisFolder, .disabled, .mcpServerOffInThisFolder, "off in this work folder — allow it"),
            (.notRunning, .disabled, .mcpServerNotRunning, "it starts when a work folder opens"),
            (.needsToken, .connecting, .mcpServerNeedsToken, "needs a token — add it"),
            (.running(.connecting), .connecting, .mcpServerDisconnected, "not connected"),
        ]
        let held = "mcp__folio__get_screenshot"
        for (standing, status, requirement, repair) in rows {
            let catalogue = MCPGrantCatalogue(servers: [
                try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, status: status, standing: standing),
            ])
            let row = try self.row(held, in: MCPToolSectionBuilder.sections(
                catalogue: catalogue, selected: [held], searchText: "", approval: .available))
            XCTAssertEqual(row.requirement, requirement, "\(standing)")
            XCTAssertTrue(row.trailingNote?.contains(repair) ?? false, "\(standing): \(row.trailingNote ?? "(none)")")
        }
        for requirement: ToolAvailabilityRequirement in [.mcpServerOffInThisFolder, .mcpServerNotRunning, .mcpServerNeedsToken] {
            XCTAssertFalse(requirement.unmetHint.contains("switched off"), "\(requirement)")
            XCTAssertNil(requirement.metHint, "\(requirement)")
        }
    }

    /// The same for a server that is switched on and not answering — connecting at launch, or
    /// failed: its grant sits in its section with the reachability hint.
    func testAGrantOfAServerThatIsNotConnectedSitsInItsSection() throws {
        for status: MCPServerStatus in [.connecting, .failed(reason: "refused"), .needsAuth(reason: "401")] {
            let catalogue = MCPGrantCatalogue(servers: [
                try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, status: status),
            ])
            let held = "mcp__folio__get_screenshot"
            XCTAssertTrue(
                MCPToolSectionBuilder.unplaceableGrants(catalogue: catalogue, selected: [held], searchText: "").isEmpty,
                "\(status)")
            let rows = MCPToolSectionBuilder.sections(
                catalogue: catalogue, selected: [held], searchText: "", approval: .available).first?.rows
            XCTAssertEqual(rows?.map(\.name), [held], "\(status)")
            XCTAssertEqual(rows?.first?.requirement, .mcpServerDisconnected, "\(status)")
        }
    }

    /// A connected server that stopped publishing a tool: the grant names a server that exists,
    /// so it is shown there — once, and not also as unplaceable — saying the server does not
    /// offer it, with the repair that is the role's: uncheck it.
    ///
    /// RED until 2026-10-28: it carried the residual `.mcpToolLive` hint, "No configured MCP
    /// server offers this — … or add the server", directly under that configured server's header.
    func testAGrantOfAToolAConnectedServerNoLongerPublishesSitsInItsSection() throws {
        let held = "mcp__folio__get_variable_defs"
        XCTAssertTrue(MCPToolSectionBuilder.unplaceableGrants(
            catalogue: try catalogue(), selected: [held], searchText: "").isEmpty)
        let folio = try XCTUnwrap(try sections(selected: [held]).first { $0.slug == "folio" })
        XCTAssertEqual(folio.rows.filter { $0.name == held }.count, 1)
        let withdrawn = try row(held, in: [folio])
        XCTAssertEqual(withdrawn.requirement, .mcpToolNotOffered)
        XCTAssertEqual(withdrawn.trailingNote, "Its MCP server does not offer this tool — uncheck it here")
        XCTAssertTrue(withdrawn.isEnabled(isSelected: true), "the repair is here: uncheck it")
        XCTAssertFalse(folio.publishesNoTools)
    }

    /// Only a grant naming no configured server at all is unplaceable — a tool grant or a
    /// whole-server grant alike.
    func testOnlyAGrantOfAnUnknownServerIsUnplaceable() throws {
        XCTAssertEqual(
            MCPToolSectionBuilder.unplaceableGrants(
                catalogue: try catalogue(),
                selected: ["mcp__gone", "mcp__gone__x", "mcp__trade_room", "mcp__trade_room__x", "mcp__folio__y"],
                searchText: ""),
            ["mcp__gone", "mcp__gone__x"])
    }

    /// A held grant with no published row honours the search like every other row: it shows
    /// when its server or its own name matches, and not otherwise.
    func testAHeldGrantWithNoPublishedRowHonoursTheSearch() throws {
        let held = "mcp__trade_room__get_orders"
        XCTAssertEqual(try sections(selected: [held], search: "orders").first?.rows.map(\.name), [held])
        XCTAssertEqual(try sections(selected: [held], search: "trade").first?.rows.map(\.name), [held])
        XCTAssertTrue(try sections(selected: [held], search: "screenshot").allSatisfy { $0.slug != "trade_room" })
    }

    /// A whole-server grant rides in the section's header, never as a row of its own.
    func testAWholeServerGrantIsNeverARow() throws {
        let invest = try XCTUnwrap(try sections(selected: ["mcp__trade_room"]).first { $0.slug == "trade_room" })
        XCTAssertTrue(invest.rows.isEmpty)
    }

    // MARK: - A run with nobody to approve (F46)

    /// On a team whose runs have nobody to approve, an approved tool every call of which would
    /// be held is withheld at run time — so its row says so, with the words bash gets. Presence
    /// comes from the team's availability, derived where the app derives it (`forTeam`): an
    /// Autonomous team has nobody, a Manual one has a person.
    ///
    /// RED until 2026-09-24: the rows never considered who would be there to approve.
    func testATheToolAManualServerWouldHoldSaysItNeedsAPersonWhenNobodyIsThere() throws {
        let screenshot = "mcp__folio__get_screenshot"
        XCTAssertEqual(
            try row(screenshot, in: try sections(approval: availability(.autonomous))).requirement, .humanApprover)
        XCTAssertNil(try row(screenshot, in: try sections(approval: availability(.manual))).requirement)
    }

    /// A tool that needs a person to approve stays CHECKABLE on a team that runs with nobody
    /// there, exactly as a `bash` row under the same requirement is: the requirement is a fact
    /// about the team's setting, not about the grant — the role holds the tool, and the hint
    /// says why a run of this team withholds it. Every other requirement keeps the rule: a
    /// withheld tool can only be UNchecked.
    ///
    /// RED until 2026-10-28: `isSelectable` read `requirement == nil || isSelected`, so on an
    /// Autonomous team nobody could grant an approved tool of a Manual server at all — the
    /// repair was to switch the team to Manual, check it, and switch back.
    func testAToolThatNeedsAnApproverStaysCheckableWithItsHint() throws {
        let nobody = try sections(approval: availability(.autonomous))

        let approved = try row("mcp__folio__get_screenshot", in: nobody)
        XCTAssertEqual(approved.requirement, .humanApprover)
        XCTAssertTrue(approved.isSelectable(isSelected: false))
        XCTAssertTrue(approved.isEnabled(isSelected: false))
        XCTAssertEqual(approved.trailingNote, ToolAvailabilityRequirement.humanApprover.unmetHint)

        let unreviewed = try row("mcp__folio__get_design_context", in: nobody)
        XCTAssertEqual(unreviewed.requirement, .mcpToolUnreviewed)
        XCTAssertFalse(unreviewed.isSelectable(isSelected: false))
        XCTAssertFalse(unreviewed.isEnabled(isSelected: false))
        XCTAssertTrue(unreviewed.isEnabled(isSelected: true), "a held one can still be unchecked")
    }

    /// The picker hands the builder the availability it was given — the team's — and never a
    /// fixed one. Read through the view itself, because that call is the one place a fixed
    /// availability could slip in: the builder's own tests cannot see what the view passes.
    ///
    /// RED until 2026-10-28: the view passing a person present regardless passed
    /// every test.
    @MainActor
    func testThePickerHandsTheBuilderTheTeamsAvailability() async throws {
        func view(_ mode: SupervisorMode) throws -> ToolSelectionView {
            ToolSelectionView(
                selectedTools: .constant([]), producedArtifacts: [], isVisionConfigured: false,
                approval: availability(mode), autoInjectedTools: [], delegationHint: "",
                mcpGrants: try catalogue())
        }
        let screenshot = "mcp__folio__get_screenshot"
        XCTAssertEqual(try row(screenshot, in: try view(.autonomous).mcpSections(matching: "")).requirement, .humanApprover)
        XCTAssertNil(try row(screenshot, in: try view(.manual).mcpSections(matching: "")).requirement)
    }

    /// The memberwise availability carries the presence it is given, and the rows read it: a
    /// `false` there is never silently a person present.
    ///
    /// RED until 2026-10-28: the memberwise init storing `true` passed every test,
    /// because every caller passed `true`.
    func testAMemberwiseAvailabilityWithNobodyThereReadsSo() throws {
        let nobody = ToolApprovalAvailability(bash: .available, computerUse: .available, humanPresent: false)
        XCTAssertFalse(nobody.humanPresent)
        XCTAssertEqual(
            try row("mcp__folio__get_screenshot", in: try sections(approval: nobody)).requirement, .humanApprover)
    }

    // MARK: - Under a whole-server grant

    /// Under a whole-server grant a row says what a run does with the tool, not only that the
    /// grant covers it. The tool of a Manual server on a team with nobody to approve: the role
    /// holds it — drawn checked, as a checked `bash` row under the same requirement is — and the
    /// row says why a run of this team withholds it. With a person there it rides in on the
    /// grant, and says so.
    ///
    /// RED until 2026-10-28: every covered row read "✓ via server grant", its own requirement
    /// computed and discarded — the picker said the role had tools the badge and the run did not.
    func testACoveredRowNamesWhatARunOfTheTeamDoesWithIt() throws {
        let screenshot = "mcp__folio__get_screenshot"
        let nobody = try row(screenshot, in: try sections(selected: ["mcp__folio"], approval: availability(.autonomous)))
        XCTAssertTrue(nobody.coveredByServerGrant)
        XCTAssertEqual(nobody.requirement, .humanApprover)
        XCTAssertTrue(nobody.isOn(isSelected: false), "the role holds it; the team's setting withholds it")
        XCTAssertEqual(nobody.trailingNote, ToolAvailabilityRequirement.humanApprover.unmetHint)
        XCTAssertFalse(nobody.isEnabled(isSelected: false), "the header's grant is what toggles it")

        let attended = try row(screenshot, in: try sections(selected: ["mcp__folio"], approval: availability(.manual)))
        XCTAssertTrue(attended.isOn(isSelected: false))
        XCTAssertEqual(attended.trailingNote, "via server grant")

        let unreviewed = try row(
            "mcp__folio__get_design_context", in: try sections(selected: ["mcp__folio"], approval: availability(.manual)))
        XCTAssertFalse(unreviewed.isOn(isSelected: false), "the grant does not bring an unreviewed tool")
        XCTAssertEqual(unreviewed.trailingNote, ToolAvailabilityRequirement.mcpToolUnreviewed.unmetHint)
    }

    /// A row nothing withholds and no server grant covers says nothing at its trailing edge: it
    /// is a tool the role may hold on its own, and "via server grant" there would claim a grant the
    /// role does not have.
    ///
    /// RED until 2026-10-28: every row saying "via server grant" passed every test.
    func testAnUncoveredRowNothingWithholdsHasNoTrailingNote() throws {
        let plain = try row("mcp__folio__get_screenshot", in: try sections(selected: [], approval: availability(.manual)))
        XCTAssertNil(plain.requirement, "premise: nothing withholds it")
        XCTAssertFalse(plain.coveredByServerGrant, "premise: no server grant covers it")
        XCTAssertNil(plain.trailingNote)

        let held = try row(
            "mcp__folio__get_screenshot",
            in: try sections(selected: ["mcp__folio__get_screenshot"], approval: availability(.manual)))
        XCTAssertNil(held.trailingNote, "held on its own grant — still nothing to say")
        XCTAssertEqual(
            MCPToolRow(name: "x", title: "x", description: "", requirement: nil, coveredByServerGrant: false).trailingNote,
            nil)
    }

    /// A whole-server grant brings only what is approved and can ship: a tool that is new,
    /// rewritten, refused, or of a server whose list is being read again is not checked by it,
    /// and its row names its own reason. A tool the role ALSO holds on its own stays checked —
    /// that is its own grant.
    func testAToolAServerGrantDoesNotBringIsNotCheckedByIt() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, tools: [
                try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_screenshot"),
                try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_metadata", pinState: .new, isRejected: true),
                try MCPGrantCatalogueTests.makeTool(
                    slug: "folio", tool: "get_whiteboard", pinState: .changed(approvedHash: "old")),
            ]),
            try MCPGrantCatalogueTests.makeServer(slug: "trade_room", id: investID, tools: [
                try MCPGrantCatalogueTests.makeTool(slug: "trade_room", tool: "get_orders"),
            ], catalogueUnverified: true),
        ])
        let all = MCPToolSectionBuilder.sections(
            catalogue: catalogue, selected: ["mcp__folio", "mcp__trade_room"], searchText: "", approval: .available)

        let expected: [(String, Bool, String)] = [
            ("mcp__folio__get_screenshot", true, "via server grant"),
            ("mcp__folio__get_metadata", false, ToolAvailabilityRequirement.mcpToolRefused.unmetHint),
            ("mcp__folio__get_whiteboard", false, ToolAvailabilityRequirement.mcpToolUnreviewed.unmetHint),
            ("mcp__trade_room__get_orders", false, ToolAvailabilityRequirement.mcpToolsBeingReread.unmetHint),
        ]
        for (name, isOn, note) in expected {
            let covered = try row(name, in: all)
            XCTAssertTrue(covered.coveredByServerGrant, name)
            XCTAssertEqual(covered.isOn(isSelected: false), isOn, name)
            XCTAssertEqual(covered.trailingNote, note, name)
        }
        XCTAssertTrue(try row("mcp__folio__get_whiteboard", in: all).isOn(isSelected: true),
                      "a tool the role also holds on its own is checked by its own grant")
    }

    // MARK: - A refused text

    /// A tool whose text the person refused is not "waiting for review": its row says they
    /// rejected it and where to review it again, and — like every requirement but the missing
    /// person — it can only be unchecked.
    ///
    /// RED until 2026-10-28: the catalogue carried no refusal, and the row read "Waiting for
    /// review" beside a Settings list that counted nothing to review.
    func testARefusedToolsRowSaysItWasRejected() throws {
        let catalogue = MCPGrantCatalogue(servers: [
            try MCPGrantCatalogueTests.makeServer(slug: "folio", id: folioID, tools: [
                try MCPGrantCatalogueTests.makeTool(slug: "folio", tool: "get_metadata", pinState: .new, isRejected: true),
            ]),
        ])
        let refused = try row("mcp__folio__get_metadata", in: MCPToolSectionBuilder.sections(
            catalogue: catalogue, selected: [], searchText: "", approval: .available))
        XCTAssertEqual(refused.requirement, .mcpToolRefused)
        XCTAssertEqual(
            refused.trailingNote,
            "You rejected this tool's text — review it again in Settings → MCP Servers to grant it")
        XCTAssertFalse(refused.isSelectable(isSelected: false))
        XCTAssertTrue(refused.isSelectable(isSelected: true))
    }
}
