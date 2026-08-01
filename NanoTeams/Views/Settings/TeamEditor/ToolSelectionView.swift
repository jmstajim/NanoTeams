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
    let isVisionConfigured: Bool
    /// `StoreConfiguration.isComputerUseEnabled` — drives the computer-use tool hints.
    let isComputerUseEnabled: Bool
    /// Tool names the runtime will add on top of `selectedTools`, resolved by the
    /// SAME chain the wire uses (`RoleToolBadgePolicy` → `EffectiveToolset`).
    ///
    /// This replaced a set of booleans that re-derived the injection rules here —
    /// a second model that could disagree with the runtime, and did: it advertised
    /// the delegation pack whenever any target was configured, while the runtime
    /// withholds it when every whitelisted team has been deleted or turned
    /// chat-mode. The per-row wording below stays local; only the SET is shared.
    let autoInjectedTools: [String]
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

    /// Auto-injected tools matching the current search. Filtering the resolved set
    /// rather than a hardcoded name list keeps the section honest when the
    /// injection rules change — the old version searched 7 fixed names whether or
    /// not the role actually received them.
    private var visibleAutoInjectedTools: [String] {
        guard !searchText.isEmpty else { return autoInjectedTools }
        let query = searchText.lowercased()
        return autoInjectedTools.filter { $0.lowercased().contains(query) }
    }

    /// Locked tools matching the current search (shown in the Required section).
    private var visibleLockedTools: [String] {
        guard !lockedTools.isEmpty else { return [] }
        if searchText.isEmpty { return lockedTools }
        let query = searchText.lowercased()
        return lockedTools.filter { $0.lowercased().contains(query) }
    }

    /// Per-tool precondition wording. Sourced from `ToolAvailabilityRequirement` so
    /// this list and the role-list badge's tooltip name the same blocker with the
    /// same words — two surfaces describing one runtime filter.
    private var toolHints: [String: String] {
        var hints: [String: String] = [:]
        hints[ToolNames.analyzeImage] = ToolAvailabilityRequirement.visionModel
            .hint(isMet: isVisionConfigured)
        for tool in ToolHandlerRegistry.computerUseTools {
            hints[tool] = ToolAvailabilityRequirement.computerUse.hint(isMet: isComputerUseEnabled)
        }
        let gitTools = ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools)
        for tool in ToolHandlerRegistry.defaultStorageBlocked {
            // Git tools need the work folder to be an actual git repo (not just any
            // folder) — `LLMExecutionService.filterForGitAvailability` strips them
            // at runtime when `.git` is missing. This view doesn't know the repo
            // state, so it states the precondition unconditionally.
            hints[tool] = (gitTools.contains(tool)
                ? ToolAvailabilityRequirement.gitRepository
                : ToolAvailabilityRequirement.workFolder).unmetHint
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
                        .font(Typography.termBase)
                        .foregroundStyle(showDescriptions ? Colors.accent : Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(showDescriptions ? "Hide descriptions" : "Show descriptions")

                Spacer()

                Text("\(selectedTools.intersection(editableToolNames).count)/\(editableToolNames.count)")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize()

                Button {
                    selectedTools = ToolSelectionLogic.toggledSelectAll(
                        selected: selectedTools, editable: editableToolNames
                    )
                } label: {
                    Text(ToolSelectionLogic.isAllEditableSelected(selected: selectedTools, editable: editableToolNames)
                         ? "Clear All" : "Select All")
                        .font(Typography.caption)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Colors.accent)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            TerminalDivider()

            // Categories
            if filteredCategories.isEmpty && visibleAutoInjectedTools.isEmpty && visibleLockedTools.isEmpty {
                NTMSSearchEmptyState(searchText: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !visibleLockedTools.isEmpty {
                            RequiredToolsSection(tools: visibleLockedTools)
                        }

                        if !visibleAutoInjectedTools.isEmpty {
                            AutoInjectedToolsSection(
                                tools: visibleAutoInjectedTools,
                                producedArtifacts: producedArtifacts,
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
    /// Already resolved AND already search-filtered by the parent. Only active
    /// injections reach here — an inactive row was confusing because it looked
    /// identical to a tool the user could toggle on. Auto-injection semantics are:
    /// either the system adds it, or it does not apply to this role.
    let tools: [String]
    let producedArtifacts: [String]
    let delegationHint: String

    /// Per-tool wording. Deliberately local: the SET of injected tools is the rule
    /// (owned by the resolver), the copy explaining each one is presentation.
    private func hint(for toolName: String) -> String {
        switch toolName {
        case ToolNames.createArtifact:
            return producedArtifacts.isEmpty
                ? "Role produces artifacts"
                : "produces: \(producedArtifacts.joined(separator: ", "))"
        case ToolNames.askSupervisor:
            return "Role has no output artifacts"
        case ToolNames.concludeMeeting:
            return "Role can start team meetings"
        case ToolNames.delegateToTeam:
            return delegationHint
        case ToolNames.cancelDelegation, ToolNames.resumeDelegation, ToolNames.forwardToTeam:
            return "Pause-and-Decide control plane"
        default:
            // A future auto-injection reaches the user as a row with no copy rather
            // than being silently dropped from the list.
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bolt")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.warning)
                MonoLabel(text: "Auto-injected", accent: true)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)

            ForEach(tools, id: \.self) { toolName in
                autoInjectedRow(toolName: toolName, hint: hint(for: toolName))
            }
        }
    }

    private func autoInjectedRow(toolName: String, hint: String) -> some View {
        HStack(spacing: Spacing.s) {
            StatusGlyph(glyph: TerminalGlyph.done, color: Colors.success)
                .frame(width: 16)

            Text(toolName)
                .font(Typography.termBase)

            Text("Auto")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.successTint))
                .foregroundStyle(Colors.success)

            Spacer()

            Text(hint)
                .font(Typography.term2xs)
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
                Image(systemName: "lock")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                MonoLabel(text: "Required")
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)

            VStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    HStack(spacing: Spacing.s) {
                        StatusGlyph(glyph: TerminalGlyph.done, color: Colors.textTertiary)
                            .frame(width: 16)

                        Text(tool)
                            .font(Typography.termBase)
                            .foregroundStyle(Colors.textSecondary)

                        Spacer(minLength: 0)

                        Text("Required")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.neutralTint))
                            .foregroundStyle(Colors.textSecondary)
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 5)
                }
            }
            .background(Colors.surfaceCard)
            .clipShape(RoundedRectangle.squircle(CornerRadius.small))
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
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(width: 14)

                MonoLabel(text: name)

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
                            .font(Typography.term2xs)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.accent)
                }

                Text("\(selectedInCategory)/\(tools.count)")
                    .font(Typography.term2xs)
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
            .clipShape(RoundedRectangle.squircle(CornerRadius.small))
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
                Image(systemName: isSelected ? "checkmark.circle" : "circle")
                    .font(Typography.termBase)
                    .foregroundStyle(isSelected ? Colors.accent : Colors.textTertiary)
                    .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Typography.termBase)
                        .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)

                    if let description {
                        Text(description)
                            .font(Typography.term2xs)
                            .foregroundStyle(Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let hint {
                    Text(hint)
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
        isVisionConfigured: true,
        isComputerUseEnabled: true,
        autoInjectedTools: [ToolNames.createArtifact, ToolNames.concludeMeeting],
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
        isVisionConfigured: false,
        isComputerUseEnabled: false,
        autoInjectedTools: [ToolNames.askSupervisor],
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
        isVisionConfigured: true,
        isComputerUseEnabled: true,
        autoInjectedTools: [ToolNames.createArtifact],
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
        isVisionConfigured: false,
        isComputerUseEnabled: false,
        autoInjectedTools: [ToolNames.askSupervisor],
        delegationHint: ""
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

