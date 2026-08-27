import SwiftUI

/// The "/" button in the composer action bar (right after "+"). Opens a popover
/// of agent skills / slash-commands discovered from well-known AI-agent
/// convention dirs — in the open work folder (`projectRoot`) and under the user's
/// home dir. Picking one appends the skill's full content as a `SkillClip` to the
/// composer's `clips` pipe, where it rides into the LLM prompt as a `## Skill:`
/// section on submit.
///
/// A leaf like `ImprovePromptButton`: it takes only the project root + the clips
/// binding, so the shared `MessageComposer` stays orchestrator-free. `projectRoot`
/// is nil in default-storage mode → global skills only. The popover works inside
/// the QuickCapture `NSPanel` (like the clip / improve popovers already do).
///
/// The catalogue comes from `AgentSkillsCatalogueStore` — the same cache the run
/// start and the Role editor read — so opening this popover costs a JSON decode
/// rather than the full walk of every skill root it used to run on every open. The
/// walk is behind the Refresh control beside the search field: installing a skill
/// is a thing the user does, and they are the only one who knows they did it.
struct SkillsPickerButton: View {
    let projectRoot: URL?
    @Binding var clips: [Clip]

    @State private var isShowing = false
    @State private var snapshot: AgentSkillsSnapshot?   // nil = loading
    @State private var scanTask: Task<Void, Never>?
    @State private var pickError: String?

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Text("/")
                .foregroundStyle(Colors.accent)
        }
        .buttonStyle(.composerIcon)
        .help("Insert an agent skill or command")
        .accessibilityLabel("Insert agent skill")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            SkillsPickerPopover(
                snapshot: snapshot,
                hasProjectRoot: projectRoot != nil,
                stagedClips: clips.texts,
                pickError: pickError,
                onPick: pick,
                onRefresh: { load(force: true) }
            )
        }
        .onChange(of: isShowing) { _, showing in
            if showing { load(force: false) } else { scanTask?.cancel() }
        }
    }

    /// `force: false` reads the cached catalogue (taking one if this install has
    /// never had it); `force: true` is the Refresh control and re-walks every root.
    private func load(force: Bool) {
        pickError = nil
        snapshot = nil
        let root = projectRoot
        scanTask?.cancel()
        scanTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                let store = AgentSkillsCatalogueStore.shared
                return force
                    ? store.rescan(projectRoot: root).snapshot
                    : store.loadOrScan(projectRoot: root).snapshot
            }.value
            guard !Task.isCancelled else { return }
            snapshot = loaded
        }
    }

    private func pick(_ item: AgentSkillsSnapshot.Item) {
        // Duplicate pick of an already-staged skill is a no-op.
        if SkillsPickerLogic.isStaged(item, in: clips.texts) {
            isShowing = false
            return
        }
        let fileURL = item.fileURL
        Task {
            let content = await Task.detached(priority: .userInitiated) {
                AgentSkillsScanner.readFullContent(at: fileURL)
            }.value
            guard let content else {
                pickError = "Could not read \(item.name) — the file may have moved."
                return
            }
            clips.append(Clip(text:
                SkillClip(id: item.id, name: item.name, agentLabel: item.agentLabel, origin: item.origin, body: content).encoded()
            ))
            isShowing = false
        }
    }
}

// MARK: - Popover

private struct SkillsPickerPopover: View {
    let snapshot: AgentSkillsSnapshot?
    let hasProjectRoot: Bool
    let stagedClips: [String]
    let pickError: String?
    let onPick: (AgentSkillsSnapshot.Item) -> Void
    let onRefresh: () -> Void

    @State private var searchText = ""
    @State private var contentHeight: CGFloat = .infinity

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                searchField
                refreshButton
            }

            if let pickError {
                Text(pickError)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(Spacing.m)
        .frame(width: 340)
    }

    private var searchField: some View {
        TextField("Search skills…", text: $searchText)
            .textFieldStyle(.plain)
            .font(Typography.termBase)
            .inputSurface(.field) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
    }

    /// The one control in the app that pays for a skill-root walk.
    ///
    /// Disabled while a load is in flight (`snapshot == nil`) — a second walk
    /// stacked on the first would replace the `scanTask` and leave the popover on
    /// its loader for two walks instead of one.
    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(Typography.caption)
        }
        .buttonStyle(.navbarIcon)
        .disabled(snapshot == nil)
        .help("Rescan for installed skills")
        .accessibilityLabel("Rescan skills")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            let groups = SkillsPickerLogic.grouped(SkillsPickerLogic.filter(snapshot.items, query: searchText))
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(groups, id: \.section) { group in
                            MonoLabel(text: group.section, size: .xs)
                            ForEach(group.items) { item in
                                row(item)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                        if abs(newHeight - contentHeight) > 1 { contentHeight = newHeight }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, 400))
            }
        } else {
            HStack(spacing: Spacing.xs) {
                NTMSLoader(.small)
                Text("Scanning…")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.m)
        }
    }

    private var emptyState: some View {
        Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? SkillsPickerLogic.emptyStateHint(hasProjectRoot: hasProjectRoot)
            : "No skills match “\(searchText)”.")
            .font(Typography.caption)
            .foregroundStyle(Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.s)
    }

    private func row(_ item: AgentSkillsSnapshot.Item) -> some View {
        let staged = SkillsPickerLogic.isStaged(item, in: stagedClips)
        return Button {
            onPick(item)
        } label: {
            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("/\(item.name)")
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Spacing.xs)
                TerminalStatusBadge(
                    glyph: TerminalGlyph.prompt,
                    label: item.origin.badgeLabel,
                    color: item.origin == .project ? Colors.accent : Colors.info,
                    bordered: false
                )
                if staged {
                    Image(systemName: "checkmark")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.success)
                }
            }
            .padding(.vertical, Spacing.xxs)
            .padding(.horizontal, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SkillsPickerLogic.helpText(for: item))
    }
}

// MARK: - Pure logic

/// Pure, unit-testable helpers for the skills picker (filtering, grouping,
/// staged detection, empty-state copy).
nonisolated enum SkillsPickerLogic {
    static func filter(_ items: [AgentSkillsSnapshot.Item], query: String) -> [AgentSkillsSnapshot.Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.name.lowercased().contains(q)
                || (item.description?.lowercased().contains(q) ?? false)
        }
    }

    /// Groups by "Agent — Kinds" (e.g. "Claude Code — Skills"), preserving the
    /// incoming order (the scanner already sorts table → origin → name).
    static func grouped(_ items: [AgentSkillsSnapshot.Item]) -> [(section: String, items: [AgentSkillsSnapshot.Item])] {
        var order: [String] = []
        var buckets: [String: [AgentSkillsSnapshot.Item]] = [:]
        for item in items {
            let key = "\(item.agentLabel) — \(item.kindLabel)s"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(item)
        }
        return order.map { (section: $0, items: buckets[$0] ?? []) }
    }

    /// A skill is staged when a clip decodes to the same item. Staged clips (from
    /// the picker) carry the item's opaque `id`, so detection is exact — two
    /// distinct skills sharing a name/agent/origin (e.g. same-named skills from two
    /// plugins) never cross-mark. An id-less clip (a feed-re-extracted display clip,
    /// or a legacy staged clip) falls back to coarse name+agent+origin identity.
    static func isStaged(_ item: AgentSkillsSnapshot.Item, in clips: [String]) -> Bool {
        clips.contains { clip in
            guard let skill = SkillClip.parse(clip) else { return false }
            if let id = skill.id { return id == item.id }
            return skill.name == item.name
                && skill.agentLabel == item.agentLabel
                && skill.origin == item.origin
        }
    }

    /// Full hover tooltip: name + untruncated description + path, so the detail a
    /// row clips (name/description) is still readable on hover.
    static func helpText(for item: AgentSkillsSnapshot.Item) -> String {
        var lines = ["/\(item.name)"]
        if let description = item.description, !description.isEmpty { lines.append(description) }
        lines.append(item.displayPath)
        return lines.joined(separator: "\n\n")
    }

    static func emptyStateHint(hasProjectRoot: Bool) -> String {
        hasProjectRoot
            ? "No agent skills found in this work folder or your home directory (~/.claude/skills, ~/.codex/prompts, …)."
            : "No agent skills found in your home directory (~/.claude/skills, ~/.codex/prompts, …). Open a work folder to include project skills."
    }
}
