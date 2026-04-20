import SwiftUI

// MARK: - Tool Selection View

/// Tool selector with categories, bulk actions (Select All / Deselect All per category),
/// and a search field for quick filtering.
struct ToolSelectionView: View {
    @Binding var selectedTools: Set<String>
    let producedArtifacts: [String]
    let isNonProducingNonObserver: Bool
    let isMeetingCoordinator: Bool
    let isVisionConfigured: Bool
    @State private var searchText: String = ""
    @State private var showDescriptions: Bool = false

    private let toolCategories = ToolConstants.displayCategories

    private var toolDescriptions: [String: String] {
        Dictionary(
            uniqueKeysWithValues: ToolHandlerRegistry.allSchemas.map { ($0.name, $0.description) }
        )
    }

    private var allToolNames: [String] {
        toolCategories.flatMap(\.tools)
    }

    private var filteredCategories: [ToolConstants.ToolCategoryDisplay] {
        if searchText.isEmpty {
            return toolCategories
        }
        let query = searchText.lowercased()
        return toolCategories.compactMap { category in
            let matchingTools = category.tools.filter { $0.lowercased().contains(query) }
            if matchingTools.isEmpty { return nil }
            return ToolConstants.ToolCategoryDisplay(
                id: category.id, name: category.name, icon: category.icon, tools: matchingTools
            )
        }
    }

    private var showAutoInjected: Bool {
        if searchText.isEmpty { return true }
        let query = searchText.lowercased()
        return ToolNames.createArtifact.contains(query)
            || ToolNames.askSupervisor.contains(query)
            || ToolNames.concludeMeeting.contains(query)
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

                Text("\(selectedTools.count)/\(allToolNames.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    let all = Set(allToolNames)
                    if selectedTools == all {
                        selectedTools = []
                    } else {
                        selectedTools = all
                    }
                } label: {
                    Text(selectedTools.count == allToolNames.count ? "Clear All" : "Select All")
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
            if filteredCategories.isEmpty && !showAutoInjected {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if showAutoInjected {
                            AutoInjectedToolsSection(
                                producedArtifacts: producedArtifacts,
                                isNonProducingNonObserver: isNonProducingNonObserver,
                                isMeetingCoordinator: isMeetingCoordinator
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

    private var isCreateArtifactActive: Bool { !producedArtifacts.isEmpty }

    /// Only active auto-injections render — an inactive row (empty circle) was confusing
    /// because it looked identical to a tool the user could toggle on. Auto-injection
    /// semantics are: either the system adds it, or it does not apply to this role.
    private var hasAnyActiveInjection: Bool {
        isCreateArtifactActive || isNonProducingNonObserver || isMeetingCoordinator
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
                        hint: "Role is the team's Meeting Coordinator"
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
        isVisionConfigured: true
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
        isVisionConfigured: false
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
        isVisionConfigured: true
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
        isVisionConfigured: false
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

