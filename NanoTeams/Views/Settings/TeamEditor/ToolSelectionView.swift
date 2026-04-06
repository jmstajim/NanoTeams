import SwiftUI

// MARK: - Tool Selection View

/// Tool selector with categories, bulk actions (Select All / Deselect All per category),
/// and a search field for quick filtering.
struct ToolSelectionView: View {
    @Binding var selectedTools: Set<String>
    let producedArtifacts: [String]
    let isNonProducingNonObserver: Bool
    let isVisionConfigured: Bool
    @State private var searchText: String = ""
    @State private var showDescriptions: Bool = false

    private let toolCategories = ToolConstants.displayCategories

    private static let lockedTools: Set<String> = [ToolNames.askSupervisor]

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
    }

    private var toolHints: [String: String] {
        let tn = ToolNames.self
        var hints: [String: String] = [:]
        hints[tn.analyzeImage] = isVisionConfigured
            ? "Vision model configured"
            : "Requires vision model"
        for tool in ToolHandlerRegistry.defaultStorageBlocked {
            hints[tool] = "Requires work folder"
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
                        selectedTools = Self.lockedTools
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
                                isNonProducingNonObserver: isNonProducingNonObserver
                            )
                        }

                        ForEach(filteredCategories) { category in
                            ToolCategorySection(
                                name: category.name,
                                icon: category.icon,
                                tools: category.tools,
                                selectedTools: $selectedTools,
                                lockedTools: Self.lockedTools,
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
        .onAppear {
            for tool in Self.lockedTools {
                selectedTools.insert(tool)
            }
        }
    }
}

// MARK: - Auto-Injected Tools Section

private struct AutoInjectedToolsSection: View {
    let producedArtifacts: [String]
    let isNonProducingNonObserver: Bool

    private var isCreateArtifactActive: Bool { !producedArtifacts.isEmpty }

    var body: some View {
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

            // create_artifact row
            autoInjectedRow(
                toolName: ToolNames.createArtifact,
                isActive: isCreateArtifactActive,
                activeHint: "produces: \(producedArtifacts.joined(separator: ", "))",
                inactiveHint: "Active when role produces artifacts"
            )

            // ask_supervisor row
            autoInjectedRow(
                toolName: ToolNames.askSupervisor,
                isActive: isNonProducingNonObserver,
                activeHint: "Role has no output artifacts",
                inactiveHint: "Active when role has no output artifacts"
            )
        }
    }

    private func autoInjectedRow(toolName: String, isActive: Bool, activeHint: String, inactiveHint: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isActive ? Colors.success : Colors.textTertiary)
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

            Text(isActive ? activeHint : inactiveHint)
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
    var lockedTools: Set<String> = []
    var toolHints: [String: String] = [:]
    var toolDescriptions: [String: String] = [:]
    var showDescriptions: Bool = false

    private var selectedInCategory: Int {
        tools.filter { selectedTools.contains($0) }.count
    }

    private var unlockedTools: [String] {
        tools.filter { !lockedTools.contains($0) }
    }

    private var allUnlockedSelected: Bool {
        unlockedTools.allSatisfy { selectedTools.contains($0) }
    }

    private func toolBinding(for tool: String) -> Binding<Bool> {
        Binding(
            get: { selectedTools.contains(tool) },
            set: { isSelected in
                if lockedTools.contains(tool) { return }
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

                if !unlockedTools.isEmpty {
                    Button {
                        if allUnlockedSelected {
                            for tool in unlockedTools { selectedTools.remove(tool) }
                        } else {
                            for tool in unlockedTools { selectedTools.insert(tool) }
                        }
                    } label: {
                        Text(allUnlockedSelected ? "Clear" : "All")
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
                        isLocked: lockedTools.contains(tool),
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
    var isLocked: Bool = false
    let hint: String?
    let description: String?
    @State private var isHovered = false

    var body: some View {
        Button {
            isSelected.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: isLocked || isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isLocked ? Colors.success : (isSelected ? Colors.accent : Colors.textTertiary))
                    .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(isLocked || isSelected ? .primary : .secondary)

                    if let description {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                if isLocked {
                    Text("Required")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Colors.successTint))
                        .foregroundStyle(Colors.success)
                }

                Spacer(minLength: 0)

                if let hint, !isLocked {
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
        .disabled(isLocked)
        .background(isHovered && !isLocked ? Colors.surfaceHover : .clear)
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
        isVisionConfigured: false
    )
    .frame(width: 460, height: 600)
    .background(Colors.surfacePrimary)
}

