import SwiftUI

// MARK: - Skills Policy (pure, testable)

/// Pure-logic backing for the Skills tab, in the same testable-namespace style as
/// `RoleEditorDelegationPolicy`. `nonisolated` so the unit tests, which don't
/// inherit the app target's `@MainActor` default, can call it without a hop.
///
/// Every function here treats `attachedIDs` as an ORDERED list. That order is the
/// order of the `### Skill:` sections in the role's system prompt — segment-0
/// bytes on a stateless transport, where the only speed lever is a byte-stable
/// prefix. Round-tripping it through a `Set` would reshuffle it on every launch.
nonisolated enum RoleEditorSkillsPolicy {

    /// One row in the "attached" list. `item` is nil when the id no longer
    /// resolves — the skill file was deleted, renamed, or lives in a work folder
    /// that isn't open. Those rows still render (visible + removable): dropping
    /// them silently would leave the user with a prompt they can't explain.
    struct AttachedRow: Identifiable, Hashable {
        let id: String
        let item: AgentSkillsSnapshot.Item?

        var isDangling: Bool { item == nil }
        var displayName: String { item?.name ?? id }
    }

    /// Resolves the role's ids against the catalogue, IN ORDER, keeping unknown
    /// ids as dangling rows.
    static func attachedRows(
        attachedIDs: [String],
        catalogue: [AgentSkillsSnapshot.Item]
    ) -> [AttachedRow] {
        let byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return attachedIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return AttachedRow(id: id, item: byID[id])
        }
    }

    // MARK: - Role-list badge

    /// What the role-list row reports about attached skills. Built from the same
    /// `attachedRows` the tab renders, so the badge count can never disagree with
    /// the list behind it.
    struct Badge: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let name: String
            let isDangling: Bool
        }

        let entries: [Entry]
        /// No scan has produced a catalogue yet. Distinct from "every id is
        /// dangling": with no catalogue the names would be the raw opaque ids and
        /// every skill would look broken. Mirrors
        /// `TeamValidationService.validateAttachedSkills`, which stays silent on an
        /// empty catalogue for exactly this reason.
        let catalogueUnavailable: Bool

        var count: Int { entries.count }
        var danglingCount: Int { entries.filter(\.isDangling).count }
    }

    /// `nil` when the role has nothing attached — the row then renders no badge.
    static func badge(
        attachedIDs: [String],
        catalogue: [AgentSkillsSnapshot.Item]
    ) -> Badge? {
        let rows = attachedRows(
            attachedIDs: attachedIDs.filter { !$0.isEmpty },
            catalogue: catalogue
        )
        guard !rows.isEmpty else { return nil }
        let catalogueUnavailable = catalogue.isEmpty
        return Badge(
            entries: rows.map {
                // With no catalogue nothing is knowably dangling, so don't claim it.
                Badge.Entry(name: $0.displayName, isDangling: catalogueUnavailable ? false : $0.isDangling)
            },
            catalogueUnavailable: catalogueUnavailable
        )
    }

    /// Multi-line `.help()` body, matching `SkillsPickerLogic.helpText`'s `/name`
    /// convention so a skill reads the same wherever it appears.
    static func badgeTooltip(_ badge: Badge) -> String {
        let noun = badge.count == 1 ? "skill" : "skills"
        var blocks = ["\(badge.count) agent \(noun) injected into this role's system prompt."]

        if badge.catalogueUnavailable {
            blocks.append("Names appear once the skill scan completes.")
        } else {
            blocks.append(badge.entries
                .map { $0.isDangling ? "/\($0.name) — missing" : "/\($0.name)" }
                .joined(separator: "\n"))
            if badge.danglingCount > 0 {
                blocks.append("Missing skills contribute nothing to the prompt.")
            }
        }

        return blocks.joined(separator: "\n\n")
    }

    static func isAttached(_ item: AgentSkillsSnapshot.Item, in attachedIDs: [String]) -> Bool {
        attachedIDs.contains(item.id)
    }

    /// Appends at the END so the user's ordering intent is "first attached =
    /// first in the prompt". Idempotent.
    static func attaching(_ id: String, to attachedIDs: [String]) -> [String] {
        attachedIDs.contains(id) ? attachedIDs : attachedIDs + [id]
    }

    /// Removes every occurrence, preserving the order of the rest.
    static func detaching(_ id: String, from attachedIDs: [String]) -> [String] {
        attachedIDs.filter { $0 != id }
    }

    /// Moves an attached id one slot toward the front (no-op at the front or when
    /// absent). Reordering is a real editing need: the first skill is the one the
    /// model reads first.
    static func movingUp(_ id: String, in attachedIDs: [String]) -> [String] {
        guard let index = attachedIDs.firstIndex(of: id), index > 0 else { return attachedIDs }
        var out = attachedIDs
        out.swapAt(index, index - 1)
        return out
    }

    /// Moves an attached id one slot toward the back (no-op at the back or when absent).
    static func movingDown(_ id: String, in attachedIDs: [String]) -> [String] {
        guard let index = attachedIDs.firstIndex(of: id), index < attachedIDs.count - 1 else {
            return attachedIDs
        }
        var out = attachedIDs
        out.swapAt(index, index + 1)
        return out
    }

    /// Rough token cost of one skill body, using the SAME estimator
    /// `ContextBudgetPolicy` uses for the overflow warning — so the number shown
    /// at attach time and the number that triggers the warning cannot disagree.
    ///
    /// Always presented as an estimate. The documented "~14% high" bias is
    /// ASCII-only; measured server/estimate ratios span 0.45 (Cyrillic) to 2.58
    /// (emoji), so a precise-looking figure would be a lie for many skills.
    static func estimatedTokens(forBody body: String) -> Int {
        WorkFolderContextPromptPlanner.estimateTokens(body)
    }

    /// Total estimated cost of everything attached — the number that matters,
    /// since all of it ships in EVERY request this role makes.
    static func estimatedTotalTokens(attachedIDs: [String], bodies: [String: String]) -> Int {
        var seen: Set<String> = []
        return attachedIDs.reduce(into: 0) { total, id in
            guard seen.insert(id).inserted, let body = bodies[id] else { return }
            total += estimatedTokens(forBody: body)
        }
    }

    /// `~4.2k` / `~840` — deliberately coarse, matching the estimator's honesty.
    static func formatTokens(_ tokens: Int) -> String {
        tokens >= 1000
            ? "~\(String(format: "%.1f", Double(tokens) / 1000))k tokens"
            : "~\(tokens) tokens"
    }
}

// MARK: - Skills Tab

/// Editor tab for attaching agent skills (`SKILL.md`, slash-commands) to a role.
///
/// The same catalogue the composer's `/` picker offers, but persistent: an
/// attached skill's full body rides this role's SYSTEM prompt on every step,
/// instead of a single message. Step execution only — `ask_teammate` answers and
/// meeting turns are unaffected.
struct RoleEditorSkillsTab: View {
    @Binding var editorState: RoleEditorState
    @Environment(NTMSOrchestrator.self) private var store

    @State private var searchQuery = ""
    /// Snapshot read once per appearance, off the observation-tracking path.
    @State private var snapshot: RoleSkillsSnapshot = .empty
    /// Bodies for skills attached in THIS editing session. The snapshot only
    /// caches bodies for ids some role has already PERSISTED, so without this
    /// the cost of the skill the user just ticked — the number this tab exists
    /// to show — would read as zero until they saved and came back.
    @State private var sessionBodies: [String: String] = [:]
    @State private var isLoading = true

    /// Snapshot bodies plus anything read for this session's fresh attachments.
    private var bodies: [String: String] {
        snapshot.bodies.merging(sessionBodies) { _, session in session }
    }

    private var attachedRows: [RoleEditorSkillsPolicy.AttachedRow] {
        RoleEditorSkillsPolicy.attachedRows(
            attachedIDs: editorState.attachedSkillIDs,
            catalogue: snapshot.items)
    }

    private var filteredCatalogue: [AgentSkillsSnapshot.Item] {
        SkillsPickerLogic.filter(snapshot.items, query: searchQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                header
                TerminalDivider().padding(.horizontal, Spacing.standard)
                attachedSection
                TerminalDivider().padding(.horizontal, Spacing.standard)
                catalogueSection
            }
            .padding(.bottom, Spacing.m)
        }
        .task {
            // Rescan first: bodies are read at scan time, so a stale snapshot
            // would show the previous contents and the previous token cost.
            await store.refreshAgentSkills()
            snapshot = store.roleSkills ?? .empty
            isLoading = false
            await loadMissingBodies()
        }
        // `.task(id:)` rather than `onChange` + an unstructured Task: it cancels
        // on disappear and on a rapid re-tick (reordering fires this per click).
        // Its first firing races the load above and simply finds no catalogue
        // yet; the `loadMissingBodies()` there covers the initial state.
        .task(id: editorState.attachedSkillIDs) {
            await loadMissingBodies()
        }
    }

    /// Fills in bodies the snapshot doesn't carry, so every attached row can be
    /// priced the moment it is attached rather than after a save round-trip.
    private func loadMissingBodies() async {
        let fetched = await store.skillBodies(forIDs: editorState.attachedSkillIDs)
        guard !fetched.isEmpty else { return }
        sessionBodies.merge(fetched) { _, new in new }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Skills", marker: true)

            Text("Attach agent skills to this role. Each attached skill's full text is injected into the role's system prompt on every step — the same skills the composer's `/` picker offers for a single message, made permanent for this role.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !editorState.attachedSkillIDs.isEmpty {
                costBanner
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.top, Spacing.m)
    }

    /// The price is stated where the decision is made. All of it ships in EVERY
    /// request this role makes, and an over-budget prompt is truncated from the
    /// HEAD — i.e. the system prompt — with no error.
    private var costBanner: some View {
        let total = RoleEditorSkillsPolicy.estimatedTotalTokens(
            attachedIDs: editorState.attachedSkillIDs, bodies: bodies)
        return HStack(spacing: Spacing.xs) {
            Text(RoleEditorSkillsPolicy.formatTokens(total))
                .font(Typography.termXs.weight(.medium))
                .foregroundStyle(Colors.textPrimary)
            Text("added to this role's system prompt on every request")
                .font(Typography.caption2)
                .foregroundStyle(Colors.textSecondary)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceCard))
    }

    // MARK: - Attached

    @ViewBuilder
    private var attachedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Attached")

            if attachedRows.isEmpty {
                Text("None. Pick from the catalogue below.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            } else {
                Text("Injected in this order.")
                    .font(Typography.caption2)
                    .foregroundStyle(Colors.textTertiary)

                ForEach(Array(attachedRows.enumerated()), id: \.element.id) { index, row in
                    attachedRow(row, index: index)
                }
            }
        }
        .padding(.horizontal, Spacing.standard)
    }

    private func attachedRow(
        _ row: RoleEditorSkillsPolicy.AttachedRow,
        index: Int
    ) -> some View {
        HStack(spacing: Spacing.s) {
            Text("\(index + 1).")
                .font(Typography.termXs)
                .foregroundStyle(Colors.textTertiary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(row.displayName)
                        .font(Typography.termBase)
                        .foregroundStyle(row.isDangling ? Colors.textSecondary : Colors.textPrimary)
                        .lineLimit(1)
                    if row.isDangling {
                        TerminalStatusBadge(glyph: "!", label: "Missing", color: Colors.warning)
                    }
                }
                if let item = row.item {
                    Text(item.displayPath)
                        .font(Typography.caption2)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("This skill file is no longer on disk, or its work folder isn't open. It contributes nothing to the prompt.")
                        .font(Typography.caption2)
                        .foregroundStyle(Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.s)

            if let body = bodies[row.id] {
                Text(RoleEditorSkillsPolicy.formatTokens(
                    RoleEditorSkillsPolicy.estimatedTokens(forBody: body)))
                    .font(Typography.caption2)
                    .foregroundStyle(Colors.textTertiary)
            }

            reorderButtons(row, index: index)

            Button {
                editorState.attachedSkillIDs = RoleEditorSkillsPolicy.detaching(
                    row.id, from: editorState.attachedSkillIDs)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.terminalGhost)
            .help("Detach")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func reorderButtons(
        _ row: RoleEditorSkillsPolicy.AttachedRow,
        index: Int
    ) -> some View {
        HStack(spacing: 2) {
            Button {
                editorState.attachedSkillIDs = RoleEditorSkillsPolicy.movingUp(
                    row.id, in: editorState.attachedSkillIDs)
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.terminalGhost)
            .disabled(index == 0)
            .help("Move earlier in the prompt")

            Button {
                editorState.attachedSkillIDs = RoleEditorSkillsPolicy.movingDown(
                    row.id, in: editorState.attachedSkillIDs)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.terminalGhost)
            .disabled(index == attachedRows.count - 1)
            .help("Move later in the prompt")
        }
    }

    // MARK: - Catalogue

    @ViewBuilder
    private var catalogueSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                MonoLabel(text: "Available")
                Spacer()
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .terminalField()
                    .frame(width: 200)
            }

            if isLoading {
                NTMSLoader(.inline)
            } else if snapshot.items.isEmpty {
                Text(SkillsPickerLogic.emptyStateHint(hasProjectRoot: store.hasRealWorkFolder))
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if filteredCatalogue.isEmpty {
                Text("No skill matches “\(searchQuery)”.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            } else {
                ForEach(SkillsPickerLogic.grouped(filteredCatalogue), id: \.section) { group in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(group.section)
                            .font(Typography.caption2.weight(.medium))
                            .foregroundStyle(Colors.textTertiary)
                            .padding(.top, Spacing.xs)

                        ForEach(group.items, id: \.id) { item in
                            catalogueRow(item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.standard)
    }

    private func catalogueRow(_ item: AgentSkillsSnapshot.Item) -> some View {
        Toggle(isOn: binding(for: item)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
                if let description = item.description, !description.isEmpty {
                    Text(description)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.terminal)
        .help(SkillsPickerLogic.helpText(for: item))
        .padding(.vertical, 2)
    }

    private func binding(for item: AgentSkillsSnapshot.Item) -> Binding<Bool> {
        Binding(
            get: { RoleEditorSkillsPolicy.isAttached(item, in: editorState.attachedSkillIDs) },
            set: { isOn in
                editorState.attachedSkillIDs = isOn
                    ? RoleEditorSkillsPolicy.attaching(item.id, to: editorState.attachedSkillIDs)
                    : RoleEditorSkillsPolicy.detaching(item.id, from: editorState.attachedSkillIDs)
            }
        )
    }
}
