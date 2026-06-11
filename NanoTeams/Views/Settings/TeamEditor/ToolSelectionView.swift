import SwiftUI

// MARK: - Tool Selection Logic (pure, testable)

/// Pure set logic behind `ToolSelectionView`'s editable-tools filtering and
/// Select-All / Clear-All. Extracted so the locked-tool-preservation invariant
/// (Clear-All must never drop the Autovisor manager's mandatory tools) is unit-tested
/// without rendering a view. See `ToolSelectionLogicTests`.
nonisolated enum ToolSelectionLogic {

    /// Tools the user may toggle: all category tools minus `locked`, narrowed to
    /// `restrictTo` when non-nil. Order preserved.
    static func editableTools(allCategoryTools: [String], locked: [String], restrictTo: Set<String>?) -> [String] {
        let lockedSet = Set(locked)
        return allCategoryTools.filter { tool in
            if lockedSet.contains(tool) { return false }
            if let restrict = restrictTo { return restrict.contains(tool) }
            return true
        }
    }

    /// True when every editable tool is already selected (drives the Clear/Select label).
    static func isAllEditableSelected(selected: Set<String>, editable: [String]) -> Bool {
        Set(editable).isSubset(of: selected)
    }

    /// Toggle Select-All: if all editable are selected, clear them; otherwise select them.
    /// Either way, tools NOT in `editable` (locked/mandatory) are left untouched.
    static func toggledSelectAll(selected: Set<String>, editable: [String]) -> Set<String> {
        let editableSet = Set(editable)
        return editableSet.isSubset(of: selected)
            ? selected.subtracting(editableSet)
            : selected.union(editableSet)
    }
}

// MARK: - Tool Selection View

/// Tool selector with categories, bulk actions (Select All / Deselect All per category),
/// and a search field for quick filtering.
struct ToolSelectionView: View {
    @Binding var selectedTools: Set<String>
    let producedArtifacts: [String]
    let isNonProducingNonObserver: Bool
    let isMeetingCoordinator: Bool
    let isVisionConfigured: Bool
    /// True iff the role has any delegation target configured — drives the
    /// auto-injection of the 4-tool delegation pack into the LLM schema.
    /// Mirrors `TeamRoleDefinition.hasDelegationConfigured`.
    let canDelegate: Bool
    /// Human-readable summary of the role's delegation configuration (e.g.
    /// "2 teams + generated" / "1 team" / "generated"). Rendered as the hint
    /// next to the auto-injected `delegate_to_team` row.
    let delegationHint: String
    /// Mandatory tools that can't be removed — rendered in a locked "Required"
    /// section instead of as toggles. Used by the Autovisor manager role.
    var lockedTools: [String] = []
    /// When non-nil, only these tools are offered as toggles; every other tool is
    /// hidden (can't be added). Used by the Autovisor manager role. `lockedTools`
    /// are shown separately and need not appear here.
    var restrictToTools: Set<String>? = nil
    @State private var searchText: String = ""
    @State private var showDescriptions: Bool = false

    private let toolCategories = ToolConstants.displayCategories

    private var toolDescriptions: [String: String] {
        Dictionary(
            uniqueKeysWithValues: ToolHandlerRegistry.allSchemas.map { ($0.name, $0.description) }
        )
    }

    /// Tools the user may toggle. When `restrictToTools` is set, only the allowed
    /// subset is editable; everything else is hidden (`lockedTools` are excluded —
    /// they render in the Required section, never as toggles).
    private var editableToolNames: [String] {
        ToolSelectionLogic.editableTools(
            allCategoryTools: toolCategories.flatMap(\.tools),
            locked: lockedTools,
            restrictTo: restrictToTools
        )
    }

    private var filteredCategories: [ToolConstants.ToolCategoryDisplay] {
        let editable = Set(editableToolNames)
        let query = searchText.lowercased()
        return toolCategories.compactMap { category in
            var tools = category.tools.filter { editable.contains($0) }
            if !searchText.isEmpty { tools = tools.filter { $0.lowercased().contains(query) } }
            if tools.isEmpty { return nil }
            return ToolConstants.ToolCategoryDisplay(
                id: category.id, name: category.name, icon: category.icon, tools: tools
            )
        }
    }

    private var showAutoInjected: Bool {
        if searchText.isEmpty { return true }
        let query = searchText.lowercased()
        return ToolNames.createArtifact.contains(query)
            || ToolNames.askSupervisor.contains(query)
            || ToolNames.concludeMeeting.contains(query)
            || ToolNames.delegateToTeam.contains(query)
            || ToolNames.cancelDelegation.contains(query)
            || ToolNames.resumeDelegation.contains(query)
            || ToolNames.forwardToTeam.contains(query)
    }

    /// Locked tools matching the current search (shown in the Required section).
    private var visibleLockedTools: [String] {
        guard !lockedTools.isEmpty else { return [] }
        if searchText.isEmpty { return lockedTools }
        let query = searchText.lowercased()
        return lockedTools.filter { $0.lowercased().contains(query) }
    }

    private var toolHints: [String: String] {
        let tn = ToolNames.self
        var hints: [String: String] = [:]
        hints[tn.analyzeImage] = isVisionConfigured
            ? "Vision model configured"
            : "Requires vision model"
        let gitTools = ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools)
        for tool in ToolHandlerRegistry.defaultStorageBlocked {
            // Git tools need the work folder to be an actual git repo (not just any
            // folder) — `LLMExecutionService.filterForGitAvailability` strips them
            // at runtime when `.git` is missing. Reflect that precondition in the UI.
            hints[tool] = gitTools.contains(tool) ? "Requires git repo" : "Requires work folder"
        }
        return hints
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: Spacing.s) {
                SearchFieldView(placeholder: "Filter tools...", text: $searchText)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDescriptions.toggle()
                    }
                } label: {
                    Image(systemName: showDescriptions ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(showDescriptions ? Colors.accent : Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(showDescriptions ? "Hide descriptions" : "Show descriptions")

                Spacer()

                Text("\(selectedTools.intersection(editableToolNames).count)/\(editableToolNames.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    selectedTools = ToolSelectionLogic.toggledSelectAll(
                        selected: selectedTools, editable: editableToolNames
                    )
                } label: {
                    Text(ToolSelectionLogic.isAllEditableSelected(selected: selectedTools, editable: editableToolNames)
                         ? "Clear All" : "Select All")
                        .font(.caption)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Colors.accent)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            Divider()

            // Categories
            if filteredCategories.isEmpty && !showAutoInjected && visibleLockedTools.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !visibleLockedTools.isEmpty {
                            RequiredToolsSection(tools: visibleLockedTools)
                        }

                        if showAutoInjected {
                            AutoInjectedToolsSection(
                                producedArtifacts: producedArtifacts,
                                isNonProducingNonObserver: isNonProducingNonObserver,
                                isMeetingCoordinator: isMeetingCoordinator,
                                canDelegate: canDelegate,
                                delegationHint: delegationHint
                            )
                        }

                        ForEach(filteredCategories) { category in
                            ToolCategorySection(
                                name: category.name,
                                icon: category.icon,
                                tools: category.tools,
                                selectedTools: $selectedTools,
                                toolHints: toolHints,
                                toolDescriptions: toolDescriptions,
                                showDescriptions: showDescriptions
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.m)
                }
            }
        }
    }
}

// MARK: - Auto-Injected Tools Section

private struct AutoInjectedToolsSection: View {
    let producedArtifacts: [String]
    let isNonProducingNonObserver: Bool
    let isMeetingCoordinator: Bool
    let canDelegate: Bool
    let delegationHint: String

    private var isCreateArtifactActive: Bool { !producedArtifacts.isEmpty }

    /// Only active auto-injections render — an inactive row (empty circle) was confusing
    /// because it looked identical to a tool the user could toggle on. Auto-injection
    /// semantics are: either the system adds it, or it does not apply to this role.
    private var hasAnyActiveInjection: Bool {
        isCreateArtifactActive || isNonProducingNonObserver || isMeetingCoordinator || canDelegate
    }

    var body: some View {
        if hasAnyActiveInjection {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(Colors.warning)
                    Text("Auto-injected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.s)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xs)

                if isCreateArtifactActive {
                    autoInjectedRow(
                        toolName: ToolNames.createArtifact,
                        hint: "produces: \(producedArtifacts.joined(separator: ", "))"
                    )
                }
                if isNonProducingNonObserver {
                    autoInjectedRow(
                        toolName: ToolNames.askSupervisor,
                        hint: "Role has no output artifacts"
                    )
                }
                if isMeetingCoordinator {
                    autoInjectedRow(
                        toolName: ToolNames.concludeMeeting,
                        hint: "Role can start team meetings"
                    )
                }
                if canDelegate {
                    autoInjectedRow(
                        toolName: ToolNames.delegateToTeam,
                        hint: delegationHint
                    )
                    autoInjectedRow(
                        toolName: ToolNames.cancelDelegation,
                        hint: "Pause-and-Decide control plane"
                    )
                    autoInjectedRow(
                        toolName: ToolNames.resumeDelegation,
                        hint: "Pause-and-Decide control plane"
                    )
                    autoInjectedRow(
                        toolName: ToolNames.forwardToTeam,
                        hint: "Pause-and-Decide control plane"
                    )
                }
            }
        }
    }

    private func autoInjectedRow(toolName: String, hint: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Colors.success)
                .frame(width: 16)

            Text(toolName)
                .font(.system(.callout, design: .monospaced))

            Text("Auto")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Colors.successTint))
                .foregroundStyle(Colors.success)

            Spacer()

            Text(hint)
                .font(.caption2)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Required Tools Section

/// Mandatory, non-removable tools (e.g. the Autovisor manager's management toolset).
/// Rendered as locked rows so the user sees them but can't toggle them off.
private struct RequiredToolsSection: View {
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Colors.textTertiary)
                Text("Required")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)

            VStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Colors.textTertiary)
                            .frame(width: 16)

                        Text(tool)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text("Required")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(Colors.neutralTint))
                            .foregroundStyle(Colors.textSecondary)
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 5)
                }
            }
            .background(Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        }
    }
}

// MARK: - Tool Category Section

private struct ToolCategorySection: View {
    let name: String
    let icon: String
    let tools: [String]
    @Binding var selectedTools: Set<String>
    var toolHints: [String: String] = [:]
    var toolDescriptions: [String: String] = [:]
    var showDescriptions: Bool = false

    private var selectedInCategory: Int {
        tools.filter { selectedTools.contains($0) }.count
    }

    private var allSelected: Bool {
        tools.allSatisfy { selectedTools.contains($0) }
    }

    private func toolBinding(for tool: String) -> Binding<Bool> {
        Binding(
            get: { selectedTools.contains(tool) },
            set: { isSelected in
                if isSelected { selectedTools.insert(tool) }
                else { selectedTools.remove(tool) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(width: 14)

                Text(name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if !tools.isEmpty {
                    Button {
                        if allSelected {
                            for tool in tools { selectedTools.remove(tool) }
                        } else {
                            for tool in tools { selectedTools.insert(tool) }
                        }
                    } label: {
                        Text(allSelected ? "Clear" : "All")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.accent)
                }

                Text("\(selectedInCategory)/\(tools.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize()
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)

            // Tool rows
            VStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    ToolRow(
                        name: tool,
                        isSelected: toolBinding(for: tool),
                        hint: toolHints[tool],
                        description: showDescriptions ? toolDescriptions[tool] : nil
                    )
                }
            }
            .background(Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        }
    }
}

// MARK: - Tool Row

private struct ToolRow: View {
    let name: String
    @Binding var isSelected: Bool
    let hint: String?
    let description: String?
    @State private var isHovered = false

    var body: some View {
        Button {
            isSelected.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
                    .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    if let description {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let hint {
                    Text(hint)
                        .font(.caption2)
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
        .background(isHovered ? Colors.surfaceHover : .clear)
        .trackHover($isHovered)
    }
}

#Preview("Tool Selector") {
    @Previewable @State var selected: Set<String> = [
        "read_file", "write_file", "edit_file", "list_files", "search",
        "git_status", "git_add", "git_commit", "git_diff",
        "run_xcodebuild",
        "ask_teammate", "request_team_meeting",
        "update_scratchpad",
        "ask_supervisor",
    ]
    ToolSelectionView(
        selectedTools: $selected,
        producedArtifacts: ["Engineering Notes"],
        isNonProducingNonObserver: false,
        isMeetingCoordinator: false,
        isVisionConfigured: true,
        canDelegate: false,
        delegationHint: ""
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}
#Preview("Empty Selection") {
    @Previewable @State var selected: Set<String> = []
    ToolSelectionView(
        selectedTools: $selected,
        producedArtifacts: [],
        isNonProducingNonObserver: true,
        isMeetingCoordinator: false,
        isVisionConfigured: false,
        canDelegate: false,
        delegationHint: ""
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

#Preview("All Selected") {
    @Previewable @State var selected = Set(
        ToolConstants.displayCategories.flatMap(\.tools)
    )
    ToolSelectionView(
        selectedTools: $selected,
        producedArtifacts: ["Product Requirements", "Design Spec"],
        isNonProducingNonObserver: false,
        isMeetingCoordinator: false,
        isVisionConfigured: true,
        canDelegate: false,
        delegationHint: ""
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

#Preview("Read-Only Tools") {
    @Previewable @State var selected: Set<String> = [
        "read_file", "read_lines", "list_files", "search",
        "git_status", "git_log", "git_diff", "git_branch_list",
    ]
    ToolSelectionView(
        selectedTools: $selected,
        producedArtifacts: [],
        isNonProducingNonObserver: true,
        isMeetingCoordinator: false,
        isVisionConfigured: false,
        canDelegate: false,
        delegationHint: ""
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

