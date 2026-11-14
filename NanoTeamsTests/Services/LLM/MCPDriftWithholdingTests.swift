import XCTest

@testable import NanoTeams

/// What happens when an external server changes a tool under a running step, and what
/// happens to a call the schema never carried.
///
/// The step freezes the catalogue at entry and keeps the copy for its whole life — the tool
/// list is rendered into segment 0 of the prompt and the wire is append-only, so narrowing it
/// mid-step would re-prefill every remaining request. That freeze is only defensible because
/// the promise it leaves standing is kept honest one call at a time, which is what this suite
/// pins.
@MainActor
final class MCPDriftWithholdingTests: XCTestCase {

    private static let folioID = UUID()

    private func entry(
        tool: String, hash: String = "h1", runsUnattended: Bool = true
    ) throws -> MCPToolsSnapshot.Entry {
        let slug = try XCTUnwrap(MCPServerSlug("folio"))
        let name = try XCTUnwrap(MCPToolNaming.modelFacingName(slug: "folio", toolName: tool))
        return MCPToolsSnapshot.Entry(
            serverID: Self.folioID,
            slug: slug,
            serverDisplayName: "Folio Desktop",
            approvalMode: .semiAutomatic,
            serverTrusted: true,
            alwaysAllowed: false,
            runsUnattended: runsUnattended,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: tool, modelFacingName: name, pinHash: hash), era: .modern)
    }

    /// A live catalogue whose server is `status` — connected unless a test says otherwise,
    /// because a live entry exists only for a connected server. `rereading`, when given, puts
    /// the server's list in a re-read, its last committed listing having approved those entries.
    private func snapshot(
        _ entries: [MCPToolsSnapshot.Entry], revision: Int,
        status: MCPServerStatus? = .connected(era: .modern),
        rereading lastCommitted: [MCPToolsSnapshot.Entry]? = nil
    ) -> MCPToolsSnapshot {
        MCPToolsSnapshot(
            entries: entries,
            statusByServerID: status.map { [Self.folioID: $0] } ?? [:],
            lastCommittedApprovalsOfUnverifiedServers: lastCommitted.map { approved in
                [Self.folioID: Dictionary(
                    approved.map { ($0.modelFacingName, $0.descriptor.pinHash) },
                    uniquingKeysWith: { first, _ in first })]
            } ?? [:],
            revision: revision)
    }

    // MARK: - Drift detection

    func testAnUnchangedCatalogueDriftsNothing() throws {
        let live = snapshot([try entry(tool: "get_metadata")], revision: 7)
        let frozen = live.resolved(humanPresent: true)
        XCTAssertEqual(frozen.drift(against: live), .none)
    }

    /// The whole reason the pin is a HASH: a rug pull rewrites the description while the
    /// name and the arguments stay exactly as approved.
    func testARewrittenDescriptionDriftsEvenThoughTheNameIsTheSame() throws {
        let frozen = snapshot([try entry(tool: "get_metadata", hash: "h1")], revision: 1)
            .resolved(humanPresent: true)
        let live = snapshot([try entry(tool: "get_metadata", hash: "h2")], revision: 2)
        XCTAssertEqual(frozen.drift(against: live).changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(frozen.drift(against: live).serverNotConnected, [])
    }

    /// Connected, and the tool is no longer there — withdrawn, or no longer approved.
    func testAToolThatLeftTheCatalogueOfAConnectedServerDriftsAsChanged() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        let drift = frozen.drift(against: snapshot([], revision: 2))
        XCTAssertEqual(drift.changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(drift.names, ["mcp__folio__get_metadata"])
    }

    /// Every tool of a server leaves the live catalogue while it has no session, and comes
    /// back at the same hash when it reconnects. That is not a change to the tool (F32).
    func testAToolWhoseServerIsBetweenSessionsDriftsAsNotConnected() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        for status in [MCPServerStatus.connecting, .failed(reason: "refused")] {
            let drift = frozen.drift(against: snapshot([], revision: 2, status: status))
            XCTAssertEqual(drift.serverNotConnected, ["mcp__folio__get_metadata"], "\(status)")
            XCTAssertEqual(drift.changed, [], "\(status)")
            XCTAssertEqual(drift.serverNeedsAttention, [], "\(status)")
        }
    }

    /// A rejected credential, a refused address, a server this client cannot speak to, a server
    /// a person switched off: none comes back on its own, so its tools are neither "changed"
    /// nor "not connected right now" — they wait for a person to change the server's settings.
    ///
    /// RED until 2026-09-23 (A2 verification) for the first two; for `.incompatible` and
    /// `.disabled` until the status could tell them from a reconnect (group C, item 13).
    func testAToolWhoseServerNeedsAPersonDriftsAsNeedingAttention() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        let statuses: [MCPServerStatus] = [
            .needsAuth(reason: "401"), .unsupportedTransport(reason: "http"),
            .incompatible(reason: "2027-01-01"), .disabled,
        ]
        for status in statuses {
            let drift = frozen.drift(against: snapshot([], revision: 2, status: status))
            XCTAssertEqual(drift.serverNeedsAttention, ["mcp__folio__get_metadata"], "\(status)")
            XCTAssertEqual(drift.serverNotConnected, [], "\(status)")
            XCTAssertEqual(drift.changed, [], "\(status)")
            XCTAssertEqual(drift.names, ["mcp__folio__get_metadata"], "withheld all the same: \(status)")
        }
    }

    /// Every set is a drifted name: the iteration withholds all four from the allowed set.
    func testTheDriftedNamesAreTheUnionOfAllFourSets() {
        let drift = MCPToolDrift(
            changed: ["mcp__a__x"], serverNotConnected: ["mcp__b__y"], serverNeedsAttention: ["mcp__c__z"],
            toolsBeingReread: ["mcp__d__w"])
        XCTAssertEqual(drift.names, ["mcp__a__x", "mcp__b__y", "mcp__c__z", "mcp__d__w"])
        XCTAssertEqual(MCPToolDrift.none.serverNeedsAttention, [])
        XCTAssertEqual(MCPToolDrift.none.toolsBeingReread, [])
    }

    /// A server re-reading its tool list — after a `list_changed`, or once its stated catalogue
    /// lifetime ran out — whose listing failed: its own bucket. Not
    /// `changed` — a re-read that finds the tool unchanged brings it back within the step —
    /// and not a lost session either: the session is fine.
    ///
    /// RED until 2026-09-24 (group C): drifted as `changed`, and so told the model the tool was
    /// withheld for the rest of the step.
    func testAToolWhoseServerRereadsItsToolsDriftsAsBeingReread() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        let drift = frozen.drift(
            against: snapshot([], revision: 2, rereading: [try entry(tool: "get_metadata")]))
        XCTAssertEqual(drift.toolsBeingReread, ["mcp__folio__get_metadata"])
        XCTAssertEqual(drift.changed, [])
        XCTAssertEqual(drift.serverNotConnected, [])
        XCTAssertEqual(drift.serverNeedsAttention, [])
        XCTAssertEqual(drift.names, ["mcp__folio__get_metadata"], "withheld all the same")
    }

    /// Nothing latches: drift is read afresh against each live catalogue, so the re-read that
    /// commits the tool unchanged drifts nothing, and one that commits a rewrite drifts it as
    /// changed — the one case the refusal said it would become.
    func testTheRereadEndsWithTheListingThatCommits() throws {
        let frozen = snapshot([try entry(tool: "get_metadata", hash: "h1")], revision: 1)
            .resolved(humanPresent: true)
        XCTAssertEqual(
            frozen.drift(
                against: snapshot([], revision: 2, rereading: [try entry(tool: "get_metadata", hash: "h1")]))
                .toolsBeingReread,
            ["mcp__folio__get_metadata"])

        XCTAssertEqual(
            frozen.drift(against: snapshot([try entry(tool: "get_metadata", hash: "h1")], revision: 3)).names, [])
        let rewritten = frozen.drift(
            against: snapshot([try entry(tool: "get_metadata", hash: "h2")], revision: 4))
        XCTAssertEqual(rewritten.changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(rewritten.toolsBeingReread, [])
    }

    /// While the list is being read again, each frozen tool drifts by the verdict the app last
    /// COMMITTED: one that listing had already rewritten out of its approval stays changed —
    /// the step was told it is withheld for the rest of it — while one it approved at the
    /// frozen text is being read again.
    ///
    /// RED until 2026-09-24 (group C, C-5): both drifted as being read again, and the tool
    /// already withheld for the rest of the step was invited back.
    func testWhileTheListIsReadAgainEachToolDriftsByTheLastCommittedVerdict() throws {
        let frozen = snapshot(
            [try entry(tool: "get_metadata", hash: "h1"), try entry(tool: "get_screenshot", hash: "h1")],
            revision: 1).resolved(humanPresent: true)
        let drift = frozen.drift(against: snapshot([], revision: 2, rereading: [
            try entry(tool: "get_metadata", hash: "h2"), try entry(tool: "get_screenshot", hash: "h1"),
        ]))
        XCTAssertEqual(drift.changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(drift.toolsBeingReread, ["mcp__folio__get_screenshot"])
        XCTAssertEqual(drift.serverNotConnected, [])
        XCTAssertEqual(drift.serverNeedsAttention, [])
    }

    /// A server removed from the list has no status at all, and it does not come back under
    /// the same id — a server added later is another one. Its tools are gone for the rest of
    /// the step, which is what "changed" says; "not connected" would invite a later call that
    /// can never succeed.
    func testAToolWhoseServerWasRemovedDriftsAsChanged() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        let drift = frozen.drift(against: snapshot([], revision: 2, status: nil))
        XCTAssertEqual(drift.changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(drift.serverNotConnected, [])
    }

    /// The same model-facing name at the same hash, published by ANOTHER server: one server
    /// was renamed away from the slug and another took it with an identical tool. The call
    /// would be routed to the server the step froze, under a policy read from the other one —
    /// so the name and the text agreeing is not enough; the server has to be the same too.
    func testTheSameNameOnAnotherServerDriftsAsChanged() throws {
        let frozen = snapshot([try entry(tool: "get_metadata")], revision: 1)
            .resolved(humanPresent: true)
        let original = try entry(tool: "get_metadata")
        let otherID = UUID()
        let impostor = MCPToolsSnapshot.Entry(
            serverID: otherID, slug: original.slug, serverDisplayName: "Other",
            approvalMode: .semiAutomatic, serverTrusted: true, alwaysAllowed: true,
            runsUnattended: true, descriptor: original.descriptor, era: .modern)
        let live = MCPToolsSnapshot(
            entries: [impostor],
            statusByServerID: [Self.folioID: .connected(era: .modern),
                               otherID: .connected(era: .modern)],
            revision: 2)
        let drift = frozen.drift(against: live)
        XCTAssertEqual(drift.changed, ["mcp__folio__get_metadata"])
        XCTAssertEqual(drift.serverNotConnected, [])
    }

    /// Two servers, one reconnecting and one that rewrote its tool: each drift under its own
    /// server's facts.
    func testDriftIsSplitPerServer() throws {
        let otherID = UUID()
        let other = MCPToolsSnapshot.Entry(
            serverID: otherID, slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            serverDisplayName: "Trade Room", approvalMode: .semiAutomatic, serverTrusted: false,
            alwaysAllowed: false, runsUnattended: true,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: "get_quote", modelFacingName: "mcp__trade_room__get_quote",
                pinHash: "q1"), era: .modern)
        let frozen = MCPToolsSnapshot(entries: [try entry(tool: "get_metadata"), other], revision: 1)
            .resolved(humanPresent: true)
        let rewritten = MCPToolsSnapshot.Entry(
            serverID: otherID, slug: other.slug, serverDisplayName: "Trade Room",
            approvalMode: .semiAutomatic, serverTrusted: false, alwaysAllowed: false,
            runsUnattended: true,
            descriptor: MCPToolDescriptorTests.makeDescriptor(
                originalName: "get_quote", modelFacingName: "mcp__trade_room__get_quote",
                pinHash: "q2"), era: .modern)
        let live = MCPToolsSnapshot(
            entries: [rewritten],
            statusByServerID: [Self.folioID: .connecting,
                               otherID: .connected(era: .modern)],
            revision: 2)
        let drift = frozen.drift(against: live)
        XCTAssertEqual(drift.changed, ["mcp__trade_room__get_quote"])
        XCTAssertEqual(drift.serverNotConnected, ["mcp__folio__get_metadata"])
    }

    func testOnlyTheChangedToolDrifts() throws {
        let frozen = snapshot(
            [try entry(tool: "get_metadata", hash: "h1"), try entry(tool: "get_screenshot", hash: "s1")],
            revision: 1).resolved(humanPresent: true)
        let live = snapshot(
            [try entry(tool: "get_metadata", hash: "h9"), try entry(tool: "get_screenshot", hash: "s1")],
            revision: 2)
        XCTAssertEqual(frozen.drift(against: live).changed, ["mcp__folio__get_metadata"])
    }

    /// The manager bumps `revision` on every rebuild, so an equal revision is a whole
    /// catalogue's worth of comparison skipped — which is the answer on every iteration but
    /// the rare one.
    func testAnEqualRevisionShortCircuitsTheComparison() throws {
        let frozen = snapshot([try entry(tool: "get_metadata", hash: "h1")], revision: 4)
            .resolved(humanPresent: true)
        // Same revision, different hash: the manager cannot produce this, and the
        // short-circuit is what makes the common case one integer comparison.
        let impossible = snapshot([try entry(tool: "get_metadata", hash: "h2")], revision: 4)
        XCTAssertEqual(frozen.drift(against: impossible), .none)
    }

    /// A withheld tool was never in the schema, so it cannot be the thing that drifted.
    func testAWithheldToolIsNotReportedAsDrift() throws {
        let frozen = snapshot(
            [try entry(tool: "post_order", hash: "p1", runsUnattended: false)], revision: 1)
            .resolved(humanPresent: false)
        XCTAssertTrue(frozen.shipped.isEmpty)
        XCTAssertEqual(frozen.drift(against: snapshot([], revision: 2)), .none)
    }

    func testAStepThatShippedNothingNeverWalksTheCatalogue() throws {
        XCTAssertEqual(
            MCPResolvedTools.empty.drift(against: snapshot([try entry(tool: "x")], revision: 9)),
            .none)
    }

    // MARK: - Classification

    private func classify(
        _ name: String,
        drifted: Set<String> = [],
        notConnected: Set<String> = [],
        needsAttention: Set<String> = [],
        rereading: Set<String> = [],
        withheld: Set<String> = [],
        known: Set<String> = []
    ) -> LLMExecutionService.ToolUnavailabilityReason {
        LLMExecutionService.classifyUnavailability(
            toolName: name,
            workFolderRoot: FileManager.default.temporaryDirectory,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            approval: .available,
            mcpDrift: MCPToolDrift(
                changed: drifted, serverNotConnected: notConnected, serverNeedsAttention: needsAttention,
                toolsBeingReread: rereading),
            mcpWithheldToolNames: withheld,
            mcpKnownToolNames: known)
    }

    func testADriftedToolIsClassifiedAsChangedByItsServer() {
        XCTAssertEqual(
            classify("mcp__folio__get_metadata", drifted: ["mcp__folio__get_metadata"]),
            .mcpToolChanged)
    }

    func testAToolWithheldForWantOfAnApproverSaysSo() {
        XCTAssertEqual(
            classify("mcp__trade_room__post_order", withheld: ["mcp__trade_room__post_order"]),
            .approverUnavailable)
    }

    /// Both outrank the planning phase, and for the reason the bash and computer-use arms
    /// already state: recording a plan re-enables neither, so `plan_required`'s "call it
    /// again after recording your plan" would invite a retry that lands here again.
    func testDriftOutranksThePlanningPhase() {
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: "mcp__folio__get_metadata",
            workFolderRoot: FileManager.default.temporaryDirectory,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            approval: .available,
            phaseWithheldToolNames: ["mcp__folio__get_metadata"],
            mcpDrift: MCPToolDrift(changed: ["mcp__folio__get_metadata"], serverNotConnected: []))
        XCTAssertEqual(reason, .mcpToolChanged)
    }

    /// Recording a plan does not reconnect a server either.
    func testAServerBetweenSessionsOutranksThePlanningPhase() {
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: "mcp__folio__get_metadata",
            workFolderRoot: FileManager.default.temporaryDirectory,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            approval: .available,
            phaseWithheldToolNames: ["mcp__folio__get_metadata"],
            mcpDrift: MCPToolDrift(changed: [], serverNotConnected: ["mcp__folio__get_metadata"]))
        XCTAssertEqual(reason, .mcpServerNotConnected)
    }

    /// The reconnect window is not reported as a change (F32).
    func testReconnectWindowIsNotReportedAsChanged() {
        XCTAssertEqual(
            classify("mcp__folio__get_metadata", notConnected: ["mcp__folio__get_metadata"]),
            .mcpServerNotConnected)
    }

    /// A server waiting for a person is its own reason, not the reconnect window's.
    func testAServerThatNeedsAPersonIsClassifiedAsNeedingAttention() {
        XCTAssertEqual(
            classify("mcp__folio__get_metadata", needsAttention: ["mcp__folio__get_metadata"]),
            .mcpServerNeedsAttention)
    }

    /// Ahead of the approver arm: the tool could not run even with a person to approve it,
    /// and "this run has none" would name the wrong thing to fix. Recording a plan does not
    /// fix a server's settings either.
    func testAServerThatNeedsAPersonOutranksTheApproverAndThePhase() {
        let name = "mcp__folio__get_metadata"
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: name,
            workFolderRoot: FileManager.default.temporaryDirectory,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            approval: .available,
            phaseWithheldToolNames: [name],
            mcpDrift: MCPToolDrift(changed: [], serverNotConnected: [], serverNeedsAttention: [name]),
            mcpWithheldToolNames: [name])
        XCTAssertEqual(reason, .mcpServerNeedsAttention)
    }

    /// A tool list being read again is its own reason — and, like the other MCP facts, outranks
    /// the approver arm and the planning phase: neither a person to approve nor a recorded plan
    /// makes the list readable.
    func testAServerRereadingItsToolsIsClassifiedAsBeingReread() {
        let name = "mcp__folio__get_metadata"
        XCTAssertEqual(classify(name, rereading: [name]), .mcpToolsBeingReread)
        let reason = LLMExecutionService.classifyUnavailability(
            toolName: name,
            workFolderRoot: FileManager.default.temporaryDirectory,
            isDefaultStorage: false,
            isVisionConfigured: true,
            selectedScheme: "App",
            approval: .available,
            phaseWithheldToolNames: [name],
            mcpDrift: MCPToolDrift(changed: [], serverNotConnected: [], toolsBeingReread: [name]),
            mcpWithheldToolNames: [name])
        XCTAssertEqual(reason, .mcpToolsBeingReread)
    }

    /// The dispatch check's refusals map onto the classifier's reasons, so the model reads one
    /// text for one fact whichever side of the iteration's check the server moved.
    func testEachDispatchRefusalIsTheReasonTheClassifierGivesTheSameFact() {
        XCTAssertEqual(
            LLMExecutionService.ToolUnavailabilityReason(MCPDispatchRefusal.toolChanged), .mcpToolChanged)
        XCTAssertEqual(
            LLMExecutionService.ToolUnavailabilityReason(MCPDispatchRefusal.serverNotConnected),
            .mcpServerNotConnected)
        XCTAssertEqual(
            LLMExecutionService.ToolUnavailabilityReason(MCPDispatchRefusal.serverNeedsAttention),
            .mcpServerNeedsAttention)
        XCTAssertEqual(
            LLMExecutionService.ToolUnavailabilityReason(MCPDispatchRefusal.toolsBeingReread),
            .mcpToolsBeingReread)
    }

    /// A real tool this role was not issued has a repair in the model's own output; a name
    /// that is no tool at all has none. Calling another role's MCP tool must land in the
    /// first class, not the second.
    func testAnotherRolesMCPToolIsNotIssuedRatherThanUnknown() {
        XCTAssertEqual(
            classify("mcp__folio__get_metadata", known: ["mcp__folio__get_metadata"]),
            .notInRoleConfig)
        XCTAssertEqual(classify("mcp__folio__get_metadata"), .unknownToolName)
    }

    func testNameShapedReasonKeepsAnsweringForBuiltInTools() {
        XCTAssertEqual(
            LLMExecutionService.nameShapedReason(canonical: ToolNames.readFile), .notInRoleConfig)
        XCTAssertEqual(
            LLMExecutionService.nameShapedReason(canonical: "not_a_tool"), .unknownToolName)
    }

    // MARK: - What the model reads

    private func envelope(_ reason: LLMExecutionService.ToolUnavailabilityReason) -> ToolExecutionResult {
        LLMExecutionService.makeUnavailableToolResult(
            call: StepToolCall(name: "mcp__folio__get_metadata", argumentsJSON: "{}"),
            canonicalName: "mcp__folio__get_metadata",
            scope: "for this role",
            reason: reason)
    }

    func testTheDriftEnvelopeBlamesTheServerAndInvitesNoRetry() throws {
        let result = envelope(.mcpToolChanged)
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        XCTAssertEqual(dict["error"] as? String, "mcp_tool_changed")
        let message = try XCTUnwrap(dict["message"] as? String)
        XCTAssertTrue(message.contains("its server"), message)
        XCTAssertTrue(message.contains("unverified"), message)
        XCTAssertFalse(message.lowercased().contains("try again"), message)
    }

    /// The description the server changed TO is never quoted back: the difference is between
    /// two server-authored texts, and putting either in front of the model is the rug pull's
    /// own channel.
    func testTheDriftEnvelopeQuotesNothingTheServerWrote() throws {
        let message = try XCTUnwrap(
            JSONUtilities.parseJSONDictionary(envelope(.mcpToolChanged).outputJSON)?["message"] as? String)
        XCTAssertFalse(message.contains("description:"), message)
    }

    /// The default arm would tell the model to fix its arguments — for the one withholding a
    /// retry cannot clear, since the schema goes on listing the tool all step.
    func testTheDriftEnvelopeIsAnsweredWithNoAppendedDirection() {
        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: envelope(.mcpToolChanged), allowedToolNames: []))
    }

    func testTheReasonStatesItsContractAndItsBlocker() {
        let reason = LLMExecutionService.ToolUnavailabilityReason.mcpToolChanged
        XCTAssertEqual(reason.errorCode, "mcp_tool_changed")
        XCTAssertEqual(reason.disposition, .terminalCarryForward)
        XCTAssertEqual(reason.blocker, .theServer)
    }

    /// A person revoking the approval mid-step reaches this text too (the dispatch check), so
    /// it may not blame the server alone.
    func testTheDriftEnvelopeAlsoCoversAWithdrawnApproval() throws {
        let message = try XCTUnwrap(
            JSONUtilities.parseJSONDictionary(envelope(.mcpToolChanged).outputJSON)?["message"] as? String)
        XCTAssertTrue(message.contains("its approval was withdrawn"), message)
    }

    // MARK: - A server between sessions (F32)

    func testTheNotConnectedReasonStatesItsContractAndItsBlocker() {
        let reason = LLMExecutionService.ToolUnavailabilityReason.mcpServerNotConnected
        XCTAssertEqual(reason.errorCode, "mcp_server_not_connected")
        XCTAssertEqual(reason.disposition, .retryLater)
        XCTAssertEqual(reason.blocker, .serverConnection)
        XCTAssertNotEqual(reason.errorCode, ToolErrorCode.mcpServerUnavailable.rawValue.lowercased(),
                          "the server-unavailable code says do not retry, and stays as it is")
    }

    /// Says what is known — no session right now — and nothing it cannot know: it does not
    /// claim the tool changed, does not withhold it for the rest of the step, and leaves one
    /// later call open without inviting an immediate one.
    func testTheNotConnectedEnvelopeLeavesALaterCallOpenAndDiagnosesNothingFalse() throws {
        let result = envelope(.mcpServerNotConnected)
        XCTAssertTrue(result.isError)
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        XCTAssertEqual(dict["error"] as? String, "mcp_server_not_connected")
        XCTAssertEqual(dict["tool"] as? String, "mcp__folio__get_metadata")
        let message = try XCTUnwrap(dict["message"] as? String)
        XCTAssertTrue(message.contains("not connected"), message)
        XCTAssertTrue(message.contains("again later in this step"), message)
        XCTAssertTrue(message.contains("after other work"), message)
        XCTAssertTrue(message.contains("unverified"), message)
        XCTAssertFalse(message.contains("changed"), message)
        XCTAssertFalse(message.contains("remainder of this step"), message)
        XCTAssertFalse(message.lowercased().contains("do not retry"), message)
    }

    /// The envelope carries both halves; the default arm would blame the arguments, and the
    /// unavailable arm's "Do not retry" would forbid the one retry that can succeed.
    func testTheNotConnectedEnvelopeIsAnsweredWithNoAppendedDirection() {
        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: envelope(.mcpServerNotConnected), allowedToolNames: []))
    }

    // MARK: - A server that needs a person

    func testTheNeedsAttentionReasonStatesItsContractAndItsBlocker() {
        let reason = LLMExecutionService.ToolUnavailabilityReason.mcpServerNeedsAttention
        XCTAssertEqual(reason.errorCode, "mcp_server_needs_attention")
        XCTAssertEqual(reason.disposition, .terminalCarryForward)
        XCTAssertEqual(reason.blocker, .serverSettings)
    }

    /// Says the server needs a person and invites no retry: nothing in the step brings it back.
    ///
    /// RED until 2026-09-23 (A2 verification): such a call was told "call it again later in
    /// this step, after other work, when its server may be back".
    func testTheNeedsAttentionEnvelopeNeedsAPersonAndInvitesNoRetry() throws {
        let result = envelope(.mcpServerNeedsAttention)
        XCTAssertTrue(result.isError)
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        XCTAssertEqual(dict["error"] as? String, "mcp_server_needs_attention")
        XCTAssertEqual(dict["tool"] as? String, "mcp__folio__get_metadata")
        let message = try XCTUnwrap(dict["message"] as? String)
        XCTAssertTrue(message.contains("until a person changes its settings"), message)
        XCTAssertTrue(message.contains("unverified"), message)
        XCTAssertFalse(message.contains("again later"), message)
        XCTAssertFalse(message.lowercased().contains("try again"), message)
        XCTAssertFalse(message.contains("reconnecting"), message)
        XCTAssertFalse(message.contains("changed what this tool does"), message)
    }

    /// Unlike the reconnect window, a direction IS appended: the default arm would blame the
    /// arguments, and what the envelope does not say is that no call can reach the blocker.
    func testTheNeedsAttentionEnvelopeDrawsADoNotRetryDirection() throws {
        let direction = try XCTUnwrap(ToolErrorNotePolicy.direction(
            for: envelope(.mcpServerNeedsAttention), allowedToolNames: []))
        XCTAssertTrue(direction.contains("Do not retry"), direction)
    }

    // MARK: - A tool list being read again (group C, 2026-09-24)

    func testTheBeingRereadReasonStatesItsContractAndItsBlocker() {
        let reason = LLMExecutionService.ToolUnavailabilityReason.mcpToolsBeingReread
        XCTAssertEqual(reason.errorCode, "mcp_tools_being_reread")
        XCTAssertEqual(reason.disposition, .retryLater)
        XCTAssertEqual(reason.blocker, .serverToolList)
    }

    /// The text, byte for byte. Third person, no server-authored text and no description of
    /// the change; it says why the call did not run, that a later call is open, and the one
    /// case in which that later call will be refused instead. It names no cause of the re-read:
    /// the state is reached by a server's `list_changed` AND by its stated catalogue lifetime
    /// running out, and the second announces nothing — so it states only what holds in both,
    /// that the list is being read again and no call of that server runs until it is.
    ///
    /// RED until 2026-09-24 (group C): the call got `mcp_tool_changed` — "withheld for the
    /// remainder of this step: … its server changed what this tool does" — about a tool that
    /// came back as soon as the re-read committed (R1.8.5). And RED until C-5 (same day) for
    /// the cause: it said "its server announced a change to the tools it offers", false for a
    /// catalogue lifetime that ran out (`MCPServerManagerTests.testAStaleSweepWhoseListingFailsWithdrawsTheToolsToo`).
    func testTheBeingRereadEnvelopeSaysWhatIsKnownAndLeavesALaterCallOpen() throws {
        let result = envelope(.mcpToolsBeingReread)
        XCTAssertTrue(result.isError)
        let dict = try XCTUnwrap(JSONUtilities.parseJSONDictionary(result.outputJSON))
        XCTAssertEqual(dict["error"] as? String, "mcp_tools_being_reread")
        XCTAssertEqual(dict["tool"] as? String, "mcp__folio__get_metadata")
        XCTAssertEqual(
            dict["message"] as? String,
            "Tool 'mcp__folio__get_metadata' did not run: the list of tools its server offers is "
                + "being read again, and none of that server's tools runs until the read succeeds. "
                + "Nothing in the call is at fault, and it returned nothing. Continue with the tools "
                + "you hold; if this step still needs it, call it again later in this step, after "
                + "other work — if the re-read list changed this tool, it will be withheld for the "
                + "rest of the step instead. Until it answers, treat what it would have settled as "
                + "unverified.")
    }

    /// The envelope carries both halves — why, and the one later call that may work. The
    /// default arm would blame the arguments, and a "Do not retry" would forbid the retry that
    /// succeeds once the list is read.
    func testTheBeingRereadEnvelopeIsAnsweredWithNoAppendedDirection() {
        XCTAssertNil(
            ToolErrorNotePolicy.direction(for: envelope(.mcpToolsBeingReread), allowedToolNames: []))
        XCTAssertNil(ToolErrorNotePolicy.direction(
            for: envelope(.mcpToolsBeingReread), allowedToolNames: [ToolNames.askSupervisor]))
    }
}
