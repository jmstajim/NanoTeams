import Foundation

// MARK: - Where one grant stands

/// Why a role's `mcp__…` entry does or does not reach a prompt.
///
/// Deliberately finer than the snapshot: a snapshot holds only the tools that SHIP, so every
/// absence there looks alike. A person editing a role needs the reason, because each one has a
/// different repair — switch the server on, fix its address, review the tool, or drop the grant.
nonisolated enum MCPGrantState: Hashable, Sendable {
    /// Reachable and approved: the grant brings tools. Also a whole-server grant of a connected
    /// server that publishes nothing — no tool to review, nothing withheld, and nothing to repair.
    case live
    /// Configured and switched off app-wide. Not a failure.
    case serverDisabled
    /// Switched on, and the open work folder's rule blocks it. Not a failure either — and not
    /// `serverDisabled`: its repair is the folder's switch, not the server's.
    case serverOffInThisFolder
    /// Switched on and allowed, and nothing runs it: the manager is shut down — a work folder
    /// being switched, one that failed to open — until the next folder opens. Nothing for a
    /// person to switch; until 2026-10-28 it read `serverDisabled`, "switched off — turn it
    /// on", of a server whose power switch was on.
    case serverNotRunning
    /// Switched on and allowed, not connected, and a credential its configuration declares is
    /// not in the Keychain: the repair is the token. A server that connects without it ships
    /// its tools, and its grants read as any connected server's.
    case serverNeedsToken
    /// Switched on but not answering: connecting, refused, or the address is one this client
    /// will not talk to. All four are "come back when it connects".
    case serverUnreachable
    /// Connected, and its tool list is being read again: a listing that should have read a
    /// change — asked after its `list_changed`, or once its stated catalogue lifetime ran out —
    /// failed (`Server.catalogueUnverified`). A whole-server grant of a server that listing
    /// approved something of, or a per-tool grant of a tool it had REVIEWED; a per-tool grant
    /// that listing did not publish, or published unreviewed, reads `toolMissing` /
    /// `toolUnreviewed` as it did before the read, and so does a whole-server grant of a server
    /// it approved nothing of.
    /// Nothing ships until a listing commits; the tools it did not change come back then, and
    /// one it changed waits for review. Not `serverUnreachable` — the session is fine, and the
    /// Settings row says Connected; until 2026-09-24 (group C) the badge sent the person to a
    /// connection that was never the problem.
    case catalogueBeingReread
    /// The server publishes the tool and nobody has approved it — or approved it and the
    /// server has since rewritten it — and the person has not refused that text. Withheld from
    /// every prompt until someone reads it. A whole-server grant stands here when its server
    /// publishes tools, not one of them is approved, and at least one is waiting to be read: it
    /// brings nothing until someone reviews one.
    case toolUnreviewed
    /// The server publishes the tool at a text the person read and REFUSED
    /// (`MCPServerTrustRecord.isRejected`). Decided, so not waiting for anyone — the Settings
    /// list counts it apart from what is to review (`MCPToolTally`) — and withheld until
    /// someone reviews it again and approves it. Until 2026-10-28 it read `toolUnreviewed`, and
    /// the badge said "Waiting for review" of a text the person had already turned down.
    case toolRefused
    /// A whole-server grant whose server publishes tools, has not one approved, and has not one
    /// waiting to be read either: the person refused every text it publishes. The whole-server
    /// form of `toolRefused` — it brings nothing until one of them is reviewed again and
    /// approved. A server with some texts refused and some waiting is `toolUnreviewed`.
    case everyToolRefused
    /// The server is connected and does not publish this tool at all. The one per-tool fault
    /// that IS decidable: the tool was renamed or withdrawn.
    case toolMissing
    /// The server publishes the tool and the APP cannot offer it: its listing collided — two of
    /// its names fold to one, so the whole namespace is refused — or the app could not read this
    /// entry (`MCPGrantCatalogue.Server.refusedToolNames`). Not the server's withdrawal
    /// (`toolMissing`), and not the person's refusal of a text (`toolRefused`): the grant works
    /// again once the server fixes what the Settings page names. Until 2026-10-28 it read
    /// `toolMissing` — "does not offer this tool, uncheck it here", false both ways.
    case toolNotOfferable
    /// A whole-server grant whose server published tools and the app can offer none of them
    /// (`MCPGrantCatalogue.Server.nothingItPublishesCanBeOffered`) — the whole-server form of
    /// `toolNotOfferable`. Until 2026-10-28 it read `live`, and the role list showed no badge
    /// while a run got nothing from the server.
    case noToolOfferable
    /// No configured server carries that slug — the server was deleted or its slug renamed.
    case unknownServer
    /// Reachable and approved, and every call of it would still wait for a person — the
    /// server's mode asks one, and neither a standing grant nor a trusted read-only claim clears
    /// the call on its own (`MCPGrantCatalogue.Tool.runsUnattended`) — in a run that has nobody
    /// to answer: Supervisor mode Autonomous, or the Autovisor supervising the folder. A
    /// whole-server grant stands here when not one of the server's approved tools could run.
    /// The runtime withholds exactly these (`MCPToolsSnapshot.resolved(humanPresent:)`), so the
    /// role editor says so rather than counting them as tools the role has (F46).
    case needsApprover
}

// MARK: - The catalogue

/// What a role can be granted from MCP, and where each grant stands.
///
/// One value, two readers: the role editor's tool picker renders it, and the availability
/// badge explains absences with it. Both used to need a different slice of the manager, and a
/// snapshot cannot serve either — it holds only what ships, so a switched-off server is simply
/// absent from it and a tool awaiting review is indistinguishable from one that never existed.
///
/// `Hashable` on purpose, unlike `MCPToolsSnapshot`: it carries no invoker, so it can be the
/// memo key of a `.task(id:)` and can ride inside an `Equatable` inputs struct.
nonisolated struct MCPGrantCatalogue: Hashable, Sendable {

    /// One tool a server publishes — reviewed or not. An unreviewed tool is listed so a
    /// person can see what is on offer, and is never granted.
    nonisolated struct Tool: Hashable, Sendable, Identifiable {
        let descriptor: MCPToolDescriptor
        let pinState: MCPPinState
        /// The user marked this exact tool, at this exact hash, always-allowed.
        let alwaysAllowed: Bool
        /// Whether a call of it could clear the approval policy with nobody watching —
        /// computed by the manager, because the policy lives in `Services`.
        let runsUnattended: Bool
        /// The person refused exactly this text — read by the manager off the same trust record
        /// as `pinState`, through the record's one reading of a refusal
        /// (`MCPServerTrustRecord.isRejected`), the one the Settings list's tally counts with.
        let isRejected: Bool

        var modelFacingName: String { descriptor.modelFacingName }
        var id: String { modelFacingName }
        var isReviewed: Bool { pinState.isApproved }
    }

    /// One configured server, whether or not it is switched on — the off ones are the reason
    /// this type exists beside the snapshot.
    nonisolated struct Server: Hashable, Sendable, Identifiable {
        let id: UUID
        let slug: MCPServerSlug
        let displayName: String
        /// Where it stands for the runtime: what ships, and what the gate and the drift check
        /// read (`shippedEntries`, `MCPToolsSnapshot.statusByServerID`).
        let status: MCPServerStatus
        /// Where it stands for a person (`MCPServerStanding`), computed by the manager beside
        /// `status`: what the role editor's section header and a held grant's hint read.
        let standing: MCPServerStanding
        let approvalMode: MCPApprovalMode
        let judgeStrictness: MCPJudgeStrictness
        let isTrusted: Bool
        /// Everything the server's last committed listing publishes — what it currently
        /// publishes, unless its list is being read again (`catalogueUnverified`) — sorted by
        /// model-facing name so the picker's rows do not reorder between rebuilds.
        let tools: [Tool]
        /// A listing that should have read a change to the server's tools — asked after its
        /// `list_changed`, or once its stated catalogue lifetime ran out — failed, and none asked
        /// since has committed (`MCPServerConnection.catalogueUnverified`). Nothing says which
        /// text it serves now, so none of its tools ships until one does; `tools` goes on
        /// holding the listing it last committed, and the snapshot carries that listing's
        /// reviewed tools (`lastCommittedApprovalsOfUnverifiedServers`), so the live catalogue
        /// reads a tool it approved at the frozen text as a tool list being read again — the
        /// refusal dispatch gives — and any other as changed.
        let catalogueUnverified: Bool
        /// It published tools and none of them can be offered — its listing collided, or the
        /// app could not read a single entry of it (`MCPServerConnection.nothingItPublishesCanBeOffered`,
        /// copied here by the manager). `tools` is then empty, and the picker says why instead
        /// of "publishes no tools"; a whole-server grant of it reads `noToolOfferable`.
        let nothingItPublishesCanBeOffered: Bool
        /// The model-facing names its last committed listing published that the APP offers
        /// nothing for — every entry of a collided listing, and each entry the descriptor factory
        /// refused (`MCPServerConnection.refusedModelFacingNames`, copied here by the manager). A
        /// per-tool grant naming one reads `toolNotOfferable`, never `toolMissing`.
        let refusedToolNames: Set<String>

        /// `standing` is the manager's; a value built without one — a test's, a preview's — reads
        /// the same rule `MCPServerRow` does (`MCPServerStanding.of(status:)`), so `.disabled` on
        /// an otherwise runnable server reads `.notRunning`.
        init(
            id: UUID,
            slug: MCPServerSlug,
            displayName: String,
            status: MCPServerStatus,
            standing: MCPServerStanding? = nil,
            approvalMode: MCPApprovalMode,
            judgeStrictness: MCPJudgeStrictness = .standard,
            isTrusted: Bool,
            tools: [Tool],
            catalogueUnverified: Bool = false,
            nothingItPublishesCanBeOffered: Bool = false,
            refusedToolNames: Set<String> = []
        ) {
            self.id = id
            self.slug = slug
            self.displayName = displayName
            self.status = status
            self.standing = standing ?? .of(status: status)
            self.approvalMode = approvalMode
            self.judgeStrictness = judgeStrictness
            self.isTrusted = isTrusted
            self.tools = tools.sorted { $0.modelFacingName < $1.modelFacingName }
            self.catalogueUnverified = catalogueUnverified
            self.nothingItPublishesCanBeOffered = nothingItPublishesCanBeOffered
            self.refusedToolNames = refusedToolNames
        }

        /// The grant that holds this server's whole approved set.
        var grantName: String { MCPToolNaming.serverGrant(slug: slug.rawValue) }
        var reviewedTools: [Tool] { tools.filter(\.isReviewed) }
        /// Its tools counted by the rule the Settings list counts the same server's with
        /// (`MCPToolTally`, from `MCPServerConnection.toolTally`): approved, new, rewritten, and
        /// refused apart — what a whole-server grant of it reads its state from, so the list's
        /// "to review" and the grant's "waiting for review" cannot disagree.
        var toolTally: MCPToolTally {
            MCPToolTally(tools.map { (state: $0.pinState, isRejected: $0.isRejected) })
        }
    }

    /// Sorted by slug, for the same reason a server's tools are sorted by name.
    let servers: [Server]
    /// The snapshot revision this was built from. Carried so a reader can tell in one
    /// comparison whether anything moved, without walking the tree.
    let revision: Int

    init(servers: [Server] = [], revision: Int = 0) {
        self.servers = servers.sorted { $0.slug < $1.slug }
        self.revision = revision
    }

    /// What a folder with no MCP at all shows — and the default every existing caller gets,
    /// so a badge built without MCP reads exactly as it did before this feature existed.
    static let empty = MCPGrantCatalogue()

    var isEmpty: Bool { servers.isEmpty }

    func server(slug: String) -> Server? { servers.first { $0.slug.rawValue == slug } }

    // MARK: - Reading a grant

    /// Where one `toolIDs` entry stands in a run of a team where a human is — or is not —
    /// there to approve a held call (`ToolApprovalAvailability.humanPresent`). Threaded, never
    /// defaulted: the role editor asked with a person present "by construction" until F46, and
    /// on an Autonomous team every Manual server's tool read as available while the runtime
    /// withheld it.
    ///
    /// A name that is not an MCP grant at all answers `.unknownServer` — callers filter with
    /// `MCPToolNaming.isMCPName` first, and answering "live" for a built-in tool would be a worse
    /// lie than answering "unknown".
    func state(ofGrant id: String, humanPresent: Bool) -> MCPGrantState {
        let attended = attendedState(ofGrant: id)
        // The missing person is the LAST reason: a tool that is off, unreviewed, gone or being
        // re-read is that first, whoever is there.
        guard attended == .live, !humanPresent,
              let slug = MCPToolNaming.slug(ofName: id), let server = server(slug: slug)
        else { return attended }
        // The same test the runtime's split applies (`MCPToolsSnapshot.resolved`), per tool: a
        // whole-server grant still brings something when any approved tool of it runs unattended.
        // A server with no approved tool is not a missing person's doing: one that publishes
        // tools read `.toolUnreviewed` or `.everyToolRefused` above, and one that publishes
        // nothing stays quiet here — `reviewed` is empty and the guard hands back `.live`.
        let reviewed = MCPToolNaming.isServerGrant(id)
            ? server.reviewedTools
            : server.reviewedTools.filter { $0.modelFacingName == id }
        guard !reviewed.isEmpty, !reviewed.contains(where: \.runsUnattended) else { return attended }
        return .needsApprover
    }

    /// Where a grant stands with a person there to answer every held call.
    private func attendedState(ofGrant id: String) -> MCPGrantState {
        guard MCPToolNaming.isMCPName(id),
              let slug = MCPToolNaming.slug(ofName: id),
              let server = server(slug: slug)
        else { return .unknownServer }

        // Where it stands for a person names the repair (`MCPServerStanding.of`). A server that
        // connected without the token its configuration declares stands at `.running(.connected)`.
        switch server.standing {
        case .switchedOff: return .serverDisabled
        case .offInThisFolder: return .serverOffInThisFolder
        case .notRunning: return .serverNotRunning
        case .needsToken: return .serverNeedsToken
        case .running(.connecting), .running(.needsAuth), .running(.failed),
             .running(.unsupportedTransport), .running(.incompatible):
            return .serverUnreachable
        case .running(.connected): break
        }
        // A whole-server grant brings the server's APPROVED tools, whichever they are. One whose
        // server publishes tools and has not one approved brings nothing until someone reviews
        // one — the reading a per-tool grant of any of them gets, and ahead of a re-read exactly
        // as it is there, since the read would bring nothing back. Until 2026-09-24 it read
        // `.live`, and the role held a grant that gave a run no tool while the badge said nothing.
        // It waits for review only while something IS to review, read by the rule the Settings
        // list counts with (`toolTally`): a server whose every text the person refused has
        // nothing waiting, and says so — until 2026-10-28 it read "Waiting for review" beside a
        // list that showed nothing to review.
        // A server that published tools the APP could offer none of brings nothing, and says so
        // — ahead of `.live`, which is what it read until 2026-10-28, with no badge on the role
        // while a run got nothing. A server that publishes nothing has nothing to review: quiet,
        // because no repair exists.
        // While its tool list is being read again nothing of the server ships, so it brings
        // nothing either.
        if MCPToolNaming.isServerGrant(id) {
            let tally = server.toolTally
            if tally.approved == 0, tally.total > 0 {
                return tally.toReview > 0 ? .toolUnreviewed : .everyToolRefused
            }
            if server.nothingItPublishesCanBeOffered { return .noToolOfferable }
            return server.catalogueUnverified ? .catalogueBeingReread : .live
        }
        // A per-tool grant is answered from the listing the server last committed — which is
        // what `tools` holds while its list is being read again — exactly as the live catalogue
        // answers a call of it: a tool that listing does not publish, or publishes unreviewed,
        // is missing or waiting for review whether or not the list is being read, and only a
        // reviewed one is held back by the read. Until C-5 (2026-09-24) every grant of such a
        // server read as being read again, badging as "back when the read succeeds" a tool
        // that waits for a person, or that the server no longer offers. A text the person
        // refused is decided rather than waiting — the tally counts it apart — and reads so.
        // A name the listing published and the app could not offer is the app's refusal, not
        // the server's withdrawal: until 2026-10-28 it read `.toolMissing`.
        guard let tool = server.tools.first(where: { $0.modelFacingName == id })
        else { return server.refusedToolNames.contains(id) ? .toolNotOfferable : .toolMissing }
        guard tool.isReviewed else { return tool.isRejected ? .toolRefused : .toolUnreviewed }
        return server.catalogueUnverified ? .catalogueBeingReread : .live
    }

    // MARK: - What a role may hold

    /// Every id a role may legally carry in `toolIDs`: one whole-server grant per CONFIGURED
    /// server, plus the model-facing name of every tool currently published by a reachable
    /// one — reviewed or not, because an unreviewed tool is a grant waiting on a click, not a
    /// mistake in the role.
    ///
    /// Configured, not connected and not even enabled: switching a server off is reversible,
    /// and a role granting its tools is not thereby misconfigured. What drops out of this set
    /// is the grant naming a server the user deleted or renamed — the one durable fault.
    var grantableToolIDs: Set<String> {
        var ids = Set(servers.map(\.grantName))
        for server in servers {
            ids.formUnion(server.tools.map(\.modelFacingName))
        }
        return ids
    }

    // MARK: - What would ship

    /// The servers whose reviewed tools either ship or stand as a last committed verdict: the
    /// connected ones. The one filter both derivations below read, so the tools that ship and
    /// the approvals the live catalogue answers from while a list is being read again are one
    /// partition of one set — a server is in exactly one of them, and cannot be in neither.
    private var connectedServers: [Server] { servers.filter(\.status.isConnected) }

    /// The snapshot entries a run with a person present would see: the reviewed tools of every
    /// reachable server whose catalogue is verified, in catalogue order.
    ///
    /// Rebuilt here rather than carried alongside, so the picker, the badge and the wire
    /// cannot disagree about which tools are approved — there is one list and this derives
    /// from it. The approval policy is NOT re-decided: `runsUnattended` rides on each tool
    /// exactly as the manager computed it.
    var shippedEntries: [MCPToolsSnapshot.Entry] {
        connectedServers.filter { !$0.catalogueUnverified }.flatMap { server -> [MCPToolsSnapshot.Entry] in
            guard let era = server.status.connectedEra else { return [] }
            return server.reviewedTools.map { tool in
                MCPToolsSnapshot.Entry(
                    serverID: server.id,
                    slug: server.slug,
                    serverDisplayName: server.displayName,
                    approvalMode: server.approvalMode,
                    judgeStrictness: server.judgeStrictness,
                    serverTrusted: server.isTrusted,
                    alwaysAllowed: tool.alwaysAllowed,
                    runsUnattended: tool.runsUnattended,
                    descriptor: tool.descriptor,
                    era: era)
            }
        }
    }

    /// For every connected server whose catalogue is unverified, what its LAST COMMITTED listing
    /// approved: model-facing name → the pin hash of the approved text. A server whose last
    /// commit approved nothing maps to an empty table, so the keys are exactly the unverified
    /// set. What the snapshot carries so the live catalogue can answer a step's frozen tool with
    /// the verdict the app last committed (`MCPLiveCatalogueIndex.standing(of:)`): a tool that
    /// listing approved at the frozen text is being read again; any other was already gone.
    ///
    /// The other half of `shippedEntries`' partition, from the same tools: while a list is
    /// being read again the connection keeps its last committed descriptors and re-derives
    /// their pins on every approval or revocation, so these are exactly the entries that would
    /// ship were the catalogue verified. NEVER shipped — a table of names and hashes, not
    /// entries, so no snapshot reader, split, picker or prompt can reach a tool through it.
    /// Connected only: a server that lost its session, or was switched off, is refused for THAT.
    var lastCommittedApprovalsOfUnverifiedServers: [UUID: [String: String]] {
        var approvals: [UUID: [String: String]] = [:]
        for server in connectedServers where server.catalogueUnverified {
            approvals[server.id] = Dictionary(
                server.reviewedTools.map { ($0.modelFacingName, $0.descriptor.pinHash) },
                uniquingKeysWith: { first, _ in first })
        }
        return approvals
    }

    /// The same split a step takes at entry, for a surface that is reasoning about a run
    /// rather than driving one — the role editor — asked with the presence a run of the team
    /// would have (`ToolApprovalAvailability.humanPresent`). The person at the editor is not the
    /// run's approver: until F46 the editor asked with `true` "by construction", and on an
    /// Autonomous team every Manual server's tool read as shipped while the runtime withheld it.
    func resolvedTools(humanPresent: Bool) -> MCPResolvedTools {
        MCPToolsSnapshot(entries: shippedEntries, revision: revision).resolved(humanPresent: humanPresent)
    }
}

// MARK: - The Settings row

/// One configured server as the Settings list shows it: what the user set, where it stands,
/// and the two facts that are not in the config — whether this folder allows it, and whether
/// the credential it says it needs is actually in the Keychain.
///
/// `hasRequiredSecrets` is here so "needs a token" is visible BEFORE the first 401 rather
/// than after it, which is the difference between a setup step and a mystery.
nonisolated struct MCPServerRow: Identifiable, Hashable, Sendable {
    let config: MCPServerConfig
    let status: MCPServerStatus
    /// Where it stands for a person — the manager's one reading (`MCPServerStanding`), which
    /// the subtitle, the server page and the role editor's section header all show.
    let standing: MCPServerStanding
    let isAllowedInThisFolder: Bool
    let hasRequiredSecrets: Bool
    /// Its tool list is being read again — a listing asked after its `list_changed`, or once its
    /// stated catalogue lifetime ran out, failed (`MCPServerConnection.catalogueUnverified`) — a
    /// fact the status does not carry: the session is fine, and the status goes on saying
    /// connected.
    let catalogueUnverified: Bool
    /// How its published tools stand against the approvals on record — read only while it is
    /// connected, when the counts describe a catalogue the server is serving.
    let tools: MCPToolTally
    /// It published tools and roles can be offered none of them — its listing collided, or the
    /// app could not read a single entry of it (`MCPServerConnection.nothingItPublishesCanBeOffered`,
    /// copied here by the manager). `tools` then counts nothing, and the row says "none
    /// offered" rather than "no tools".
    let nothingItPublishesCanBeOffered: Bool

    /// `standing` is the manager's; a row built without one — a test's, a preview's — reads the
    /// rule over its own fields, a switched-on, allowed server with its token whose status is
    /// `.disabled` being one nothing runs.
    init(
        config: MCPServerConfig,
        status: MCPServerStatus,
        standing: MCPServerStanding? = nil,
        isAllowedInThisFolder: Bool,
        hasRequiredSecrets: Bool,
        catalogueUnverified: Bool = false,
        tools: MCPToolTally = .none,
        nothingItPublishesCanBeOffered: Bool = false
    ) {
        self.config = config
        self.status = status
        self.standing = standing ?? .of(
            isSwitchedOn: config.isEnabled, isAllowedInThisFolder: isAllowedInThisFolder,
            hasRequiredSecrets: hasRequiredSecrets, status: status)
        self.isAllowedInThisFolder = isAllowedInThisFolder
        self.hasRequiredSecrets = hasRequiredSecrets
        self.catalogueUnverified = catalogueUnverified
        self.tools = tools
        self.nothingItPublishesCanBeOffered = nothingItPublishesCanBeOffered
    }

    var id: UUID { config.id }

    /// Switched on globally and allowed here. Not the same as connected — that is `status`.
    var isRunnable: Bool { config.isEnabled && isAllowedInThisFolder }

    /// The one line under the server's name in the list. The status reason is deliberately
    /// NOT folded in: it is server-controlled and can be long, so the detail view shows it.
    ///
    /// A connected server says what a person has to act on — "Connected · 3 to review · 2
    /// approved" (`MCPToolTally.summary`); until F47 it said "Connected — 2026-07-28, 0 tools" for a
    /// server with five tools waiting, the protocol revision reading as a date and the count
    /// being of the approved tools alone. The revision is a line of its own on the server's page.
    ///
    /// A connected server whose tool list is being read again says so, and claims no count:
    /// none of its approved tools ships until the read succeeds, and a role's badge says the
    /// same thing about each of them (`MCPGrantState.catalogueBeingReread`). One that published
    /// tools the app could offer none of says "none offered", not "no tools"
    /// (`nothingItPublishesCanBeOffered`).
    ///
    /// Anything in the way first, in the standing's words (`MCPServerStanding.label`) — the one
    /// reading the role editor's section header shows too: a server switched on and allowed
    /// here that nothing runs, because the manager is shut down, reads "Not running", as its
    /// page's own line does (until 2026-10-28 it read "Off" beside a power switch that was on).
    var subtitle: String {
        guard standing.isQuietlyConnected else { return standing.label }
        if catalogueUnverified { return "\(status.displayLabel) · re-reading its tool list" }
        if nothingItPublishesCanBeOffered { return "\(status.displayLabel) · none offered" }
        return "\(status.displayLabel) · \(tools.summary)"
    }
}
