import SwiftUI

// MARK: - The rows

/// One MCP tool as the picker renders it.
nonisolated struct MCPToolRow: Identifiable, Equatable, Sendable {
    let name: String
    let title: String
    let description: String
    /// What withholds it, or `nil` when the grant resolves. Drives the trailing hint, whether
    /// the row can be checked, and whether a whole-server grant brings it.
    let requirement: ToolAvailabilityRequirement?
    /// The whole server is already granted, so this tool rides in on that grant — whenever a
    /// grant of it would hold it (`isOn`) — whether or not its own box is ticked. The row says
    /// so rather than silently disagreeing with the wire.
    let coveredByServerGrant: Bool

    var id: String { name }

    /// Whether a grant of it gives the role the tool: nothing withholds it, or only the team's
    /// setting does — `.humanApprover`, a run of this team having nobody to approve a tool every
    /// call of which would wait for one. That requirement is a fact about the team, not about
    /// the grant: the role holds the tool, a run with a person present gets it, and a checked
    /// `bash` row under the same requirement reads exactly so. Every other requirement is about
    /// the tool itself — off, unreachable, unreviewed, refused, gone, being re-read — and a
    /// grant of it brings nothing.
    private var aGrantHoldsIt: Bool { requirement == nil || requirement == .humanApprover }

    /// A tool a grant would hold can be checked — `.humanApprover` included, as on a `bash`
    /// row (until 2026-10-28 such a row could not be checked at all, and the repair was to
    /// switch the team to Manual and back). One withheld for anything else can still be
    /// UNCHECKED — removing a grant the app cannot honour is the repair, and a disabled row
    /// would leave the person reading the warning with nowhere to act on it.
    func isSelectable(isSelected: Bool) -> Bool {
        aGrantHoldsIt || isSelected
    }

    /// Drawn checked: the role holds it — by its own grant, or by its server's when that grant
    /// brings it. A whole-server grant brings only what a grant of the tool itself would hold,
    /// so a tool it does not bring (unreviewed, refused, rewritten, being re-read) is not drawn
    /// checked under it. Until 2026-10-28 every covered row was.
    func isOn(isSelected: Bool) -> Bool {
        isSelected || (coveredByServerGrant && aGrantHoldsIt)
    }

    /// A row its server's grant covers is toggled from the header, never on its own.
    func isEnabled(isSelected: Bool) -> Bool {
        !coveredByServerGrant && isSelectable(isSelected: isSelected)
    }

    /// The words at the row's trailing edge: what withholds the tool when anything does —
    /// under a whole-server grant too, since "via server grant" over a withheld tool says the
    /// role has what a run will not give it (until 2026-10-28 the grant's words won) — and
    /// otherwise that the server's grant is what brings it.
    var trailingNote: String? {
        if let requirement { return requirement.unmetHint }
        return coveredByServerGrant ? "via server grant" : nil
    }
}

/// One configured server, with the tools it publishes.
nonisolated struct MCPToolSection: Identifiable, Equatable, Sendable {
    let slug: String
    let displayName: String
    /// `mcp__<slug>` — the whole-server grant the header toggles.
    let grantName: String
    /// Where the server stands for a person — what the header's note and the empty line both
    /// read: the manager's one reading (`MCPServerStanding`), the one the Settings list shows.
    let standing: MCPServerStanding
    let rows: [MCPToolRow]
    /// The server publishes nothing right now — switched off, not connected yet, or an empty
    /// catalogue — or nothing a role can be offered. `emptyLine` says which, where the header
    /// does not, above whatever grants the role still holds of it.
    let publishesNoTools: Bool
    /// It published tools and none of them can be offered — its listing collided, or the app
    /// could not read one entry of it (`MCPGrantCatalogue.Server.nothingItPublishesCanBeOffered`).
    /// The app's refusal of what it could not read, not the person's of a text (`.mcpToolRefused`).
    let nothingItPublishesCanBeOffered: Bool

    var id: String { slug }

    /// Shown beside the name when the server is not simply connected — the Settings list's own
    /// words for it (`MCPServerRow.subtitle`). `nil` in the quiet case, so a working server's
    /// header carries no chrome. Until 2026-10-28 it read the runtime status, and a server
    /// off in this folder or not running read "Off" beside a list that said which.
    var statusNote: String? { standing.isQuietlyConnected ? nil : standing.label }

    /// The line under the header when the server publishes nothing, read from the same standing
    /// the header's note reads. It waits for an answer only from a server that is still trying
    /// — connecting, or failed and retrying — and says so of one that answered with nothing. A
    /// server that is off, or that needs a person (a credential, an address, a server update),
    /// gets no line: its header already names the state, and none of them will answer on its
    /// own. Until 2026-09-24 every empty section read "No tools yet — they appear once the
    /// server answers.", under an Off header too, above the grants it keeps listed (F45). A
    /// connected server that published tools none of which can be offered says so, and where
    /// its page lists why — until 2026-10-28 it read "publishes no tools" too.
    var emptyLine: String? {
        guard publishesNoTools else { return nil }
        switch standing {
        case .running(.connecting), .running(.failed): return "No tools yet — they appear once the server answers."
        case .running(.connected):
            return nothingItPublishesCanBeOffered
                ? "None of what it publishes can be offered — see Settings → MCP Servers."
                : "The server publishes no tools."
        case .switchedOff, .offInThisFolder, .needsToken, .notRunning,
             .running(.needsAuth), .running(.unsupportedTransport), .running(.incompatible):
            return nil
        }
    }
}

// MARK: - Building them

/// Turning a catalogue into picker sections. Pure and separate from the view so the rules —
/// which row is selectable, what the search matches, where an unplaceable grant goes — are
/// testable without a window.
nonisolated enum MCPToolSectionBuilder {

    /// One section per configured server, in catalogue order (slug), with the rows the search
    /// leaves. A server with nothing to show is kept only when it has no tools at all — its
    /// header is the one place the whole-server grant can be switched on before it connects.
    ///
    /// A row's requirement reads the presence a RUN of the team would have — the team's own
    /// availability (`approval`, `ToolApprovalAvailability.forTeam`), the one value presence is
    /// derived in, never a bare Bool a caller could fix: a tool every call of which would wait
    /// for a person is withheld from a run with nobody to approve, and its row says so (F46).
    ///
    /// Besides what the server publishes, a section lists every per-tool grant the role holds
    /// of it that the server does not publish right now — switched off, connecting, failed, or
    /// the tool withdrawn — with the reason as its hint. They are the server's, not strays:
    /// switching a server off is reversible, and a role granting its tools is not thereby
    /// misconfigured (F45).
    static func sections(
        catalogue: MCPGrantCatalogue,
        selected: Set<String>,
        searchText: String,
        approval: ToolApprovalAvailability
    ) -> [MCPToolSection] {
        let query = searchText.lowercased()
        let heldBySlug = heldToolGrantsBySlug(selected)
        return catalogue.servers.compactMap { server in
            let serverMatches = query.isEmpty
                || server.slug.rawValue.lowercased().contains(query)
                || server.displayName.lowercased().contains(query)
            let covered = selected.contains(server.grantName)
            func row(_ name: String, title: String, description: String) -> MCPToolRow {
                MCPToolRow(
                    name: name, title: title, description: description,
                    requirement: ToolAvailabilityRequirement
                        .forMCPGrant(catalogue.state(ofGrant: name, humanPresent: approval.humanPresent)),
                    coveredByServerGrant: covered)
            }

            // One pass, filtering as it builds rather than building rows to throw away —
            // and no `filter` nested in the server walk, which reads as a multiplicative
            // scan to the complexity ratchet while each server's tools are its own.
            var rows: [MCPToolRow] = []
            var published = Set<String>()
            for tool in server.tools {
                let name: String = tool.modelFacingName
                published.insert(name)
                guard serverMatches || name.lowercased().contains(query) else { continue }
                rows.append(row(name, title: tool.descriptor.displayTitle, description: tool.descriptor.summaryLine))
            }
            for name in heldBySlug[server.slug.rawValue] ?? [] where !published.contains(name) {
                guard serverMatches || name.lowercased().contains(query) else { continue }
                rows.append(row(name, title: name, description: ""))
            }
            guard serverMatches || !rows.isEmpty else { return nil }

            return MCPToolSection(
                slug: server.slug.rawValue,
                displayName: server.displayName,
                grantName: server.grantName,
                standing: server.standing,
                rows: rows,
                publishesNoTools: server.tools.isEmpty,
                nothingItPublishesCanBeOffered: server.nothingItPublishesCanBeOffered)
        }
    }

    /// The per-tool grants among `selected`, by the slug they name, each list sorted — what a
    /// section adds below the tools its server publishes.
    private static func heldToolGrantsBySlug(_ selected: Set<String>) -> [String: [String]] {
        var bySlug: [String: [String]] = [:]
        for name in selected where MCPToolNaming.isMCPName(name) && !MCPToolNaming.isServerGrant(name) {
            guard let slug = MCPToolNaming.slug(ofName: name) else { continue }
            bySlug[slug, default: []].append(name)
        }
        return bySlug.mapValues { $0.sorted() }
    }

    /// Grants the role holds that no section can place: no configured server carries the slug
    /// they name — the server was deleted, or its slug renamed (`MCPGrantState.unknownServer`,
    /// the rule `TeamValidationService.validateMCPTools` applies). Without this they would be
    /// invisible here and unremovable — the team editor's banner would name a fault whose only
    /// repair is hand-editing JSON. A grant of a server that IS configured belongs to its
    /// section, whatever that server is doing; until F45 a switched-off or connecting server's
    /// tool grants landed here, under "No such server", with a hint to uncheck them.
    static func unplaceableGrants(
        catalogue: MCPGrantCatalogue,
        selected: Set<String>,
        searchText: String
    ) -> [String] {
        let query = searchText.lowercased()
        // Whoever would be there to approve, a slug no server carries is unknown — presence is
        // the last reason a grant is read for, and never the one that makes it placeable.
        return selected
            .filter {
                MCPToolNaming.isMCPName($0)
                    && catalogue.state(ofGrant: $0, humanPresent: true) == .unknownServer
            }
            .filter { query.isEmpty || $0.lowercased().contains(query) }
            .sorted()
    }
}

// MARK: - The section view

/// One server's rows, shaped like `ToolCategorySection` — same header, same row metrics — so
/// the MCP half of the picker reads as part of the same list rather than as a visitor.
struct MCPToolSectionView: View {

    let section: MCPToolSection
    @Binding var selectedTools: Set<String>
    var showDescriptions: Bool = false

    private var grantsWholeServer: Bool { selectedTools.contains(section.grantName) }

    private var selectedCount: Int {
        section.rows.count { selectedTools.contains($0.name) }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selectedTools.contains(name) },
            set: { isSelected in
                if isSelected { selectedTools.insert(name) } else { selectedTools.remove(name) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let line = section.emptyLine {
                Text(line)
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 5)
            }
            ForEach(section.rows) { row in
                MCPToolRowView(
                    row: row,
                    isSelected: binding(for: row.name),
                    description: showDescriptions ? row.description : nil)
            }
        }
        .padding(.top, Spacing.m)
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "server.rack")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textTertiary)
                .frame(width: 14)

            MonoLabel(text: section.displayName)

            if let note = section.statusNote {
                Text(note)
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.warning)
                    .lineLimit(1)
            }

            Spacer()

            Text(grantsWholeServer ? "all" : "\(selectedCount)/\(section.rows.count)")
                .font(Typography.term2xs)
                .lineLimit(1)
                .foregroundStyle(Colors.textTertiary)

            Button {
                if grantsWholeServer {
                    selectedTools.remove(section.grantName)
                } else {
                    selectedTools.insert(section.grantName)
                }
            } label: {
                Text(grantsWholeServer ? "Clear server" : "All tools of this server")
                    .font(Typography.term2xs)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Colors.accent)
            .help("Grants every approved tool of this server, including ones approved later")
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - The row view

/// Mirrors `ToolRow`'s metrics; differs only where MCP differs — a row can be un-checkable,
/// and a row can be granted by its server rather than by itself.
private struct MCPToolRowView: View {

    let row: MCPToolRow
    @Binding var isSelected: Bool
    let description: String?
    @State private var isHovered = false

    private var isOn: Bool { row.isOn(isSelected: isSelected) }
    private var isEnabled: Bool { row.isEnabled(isSelected: isSelected) }

    var body: some View {
        Button {
            isSelected.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: isOn ? "checkmark.circle" : "circle")
                    .font(Typography.termBase)
                    .foregroundStyle(isOn ? Colors.accent : Colors.textTertiary)
                    .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(Typography.termBase)
                        .foregroundStyle(isOn ? Colors.textPrimary : Colors.textSecondary)

                    if let description, !description.isEmpty {
                        Text(description)
                            .font(Typography.term2xs)
                            .foregroundStyle(Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let trailingNote = row.trailingNote {
                    Text(trailingNote)
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .background(isHovered && isEnabled ? Colors.surfaceHover : .clear)
        .trackHover($isHovered)
    }
}

// MARK: - Unplaceable grants

/// The grants no server can place. A section rather than a banner, because the repair is the
/// same gesture as every other row here: uncheck it.
struct MCPUnplaceableGrantsSection: View {

    let names: [String]
    @Binding var selectedTools: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "questionmark.circle")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.warning)
                    .frame(width: 14)
                MonoLabel(text: "No such server")
                Spacer()
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)

            ForEach(names, id: \.self) { name in
                MCPToolRowView(
                    row: MCPToolRow(
                        name: name, title: name, description: "",
                        requirement: .mcpToolLive, coveredByServerGrant: false),
                    isSelected: Binding(
                        get: { selectedTools.contains(name) },
                        set: { if $0 { selectedTools.insert(name) } else { selectedTools.remove(name) } }),
                    description: nil)
            }
        }
        .padding(.top, Spacing.m)
    }
}
