import SwiftUI

/// Settings → MCP Servers. The one place an external tool server can be added, and the one
/// place its tools are approved.
///
/// Deliberately the ONLY entry: no `.mcp.json` is read from a work folder, so a repository
/// cannot introduce a server by being opened. Everything on this screen was typed by the
/// person looking at it.
struct MCPServersSettingsView: View {

    @Environment(NTMSOrchestrator.self) private var store

    @State private var selectedServerID: UUID?
    @State private var searchText = ""
    @State private var isAddingServer = false
    @State private var editingServer: MCPServerConfig?
    @State private var pendingDeletion: MCPServerRow?

    private var manager: MCPServerManager? { store.mcpServerManager }
    private var rows: [MCPServerRow] { manager?.serverRows ?? [] }

    private var visibleRows: [MCPServerRow] {
        guard !searchText.isEmpty else { return rows }
        let query = searchText.lowercased()
        return rows.filter { row in
            let name: String = row.config.effectiveDisplayName.lowercased()
            let slug: String = row.config.slug.rawValue
            return name.contains(query) || slug.contains(query)
        }
    }

    private var selectedRow: MCPServerRow? {
        rows.first { $0.id == selectedServerID }
    }

    var body: some View {
        SettingsMasterDetailView(hasSelection: selectedRow != nil) {
            master
        } detail: {
            if let selectedRow {
                Self.detail(
                    for: selectedRow,
                    manager: manager,
                    judgeConfig: store.configuration,
                    onEdit: { editingServer = selectedRow.config },
                    onDelete: { pendingDeletion = selectedRow },
                    onSetEnabled: { enabled in
                        guard let manager else { throw MCPServerEditError.serversNotLoaded }
                        try await manager.setServerEnabled(id: selectedRow.id, enabled: enabled)
                    },
                    onSetEnabledHere: { allowed in
                        guard let manager else { throw MCPServerEditError.serversNotLoaded }
                        try await manager.setServerEnabledInThisFolder(selectedRow.id, enabled: allowed)
                    })
            }
        } emptyDetail: {
            SettingsEmptyState(
                title: rows.isEmpty ? "No MCP servers" : "Pick a server",
                systemImage: "server.rack",
                description: rows.isEmpty
                    ? "Connect an MCP server to give roles tools this app does not ship. "
                    + "Its tools reach no prompt until you review them."
                    : "Choose a server on the left to see its tools.",
                actionTitle: rows.isEmpty ? "Add server" : nil,
                action: rows.isEmpty ? { isAddingServer = true } : nil)
        }
        .sheet(isPresented: $isAddingServer) {
            Self.editorSheet(editing: nil, manager: manager, onSaved: { selectedServerID = $0 })
        }
        .sheet(item: $editingServer) { config in
            Self.editorSheet(editing: config, manager: manager, onSaved: { selectedServerID = $0 })
        }
        .confirmationDialog(
            "Remove this server?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { row in
            Button("Remove \(row.config.effectiveDisplayName)", role: .destructive) {
                Task {
                    await manager?.remove(id: row.id)
                    if selectedServerID == row.id { selectedServerID = nil }
                    pendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("Its approvals and its stored token are removed with it. Roles that granted "
                + "its tools keep the grants, and the team editor flags them.")
        }
    }

    // MARK: - Master

    private var master: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                SearchFieldView(placeholder: "Filter servers...", text: $searchText)
                Button {
                    isAddingServer = true
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accentTint))
                        .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                }
                .buttonStyle(.plain)
                .help("Add an MCP server")
                .accessibilityLabel("Add an MCP server")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            if let error = manager?.lastError {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.error)
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.xs)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    if visibleRows.isEmpty, !rows.isEmpty {
                        Text("No servers match “\(searchText)”.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                    }
                    ForEach(visibleRows) { row in
                        MCPServerListRow(
                            row: row,
                            isSelected: row.id == selectedServerID,
                            onSelect: { selectedServerID = row.id })
                    }
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.s)
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// The selected server's page, carrying that server's identity: a different selection is a
    /// different page, so what one server's page holds in its own state — a failed action's
    /// banner, an open review sheet, a pending bulk approval — does not appear on the next.
    /// Until the second review of group D (2026-09-24) the pane kept one identity for every
    /// server, and server A's folder-rule error sat on server B's page. Static, so a test can
    /// read the identity it is given.
    ///
    /// What the page knows of the manager it reads here, from the manager it is handed — the
    /// server's connection, and whether a work folder is open for its folder rule — rather
    /// than from parameters the list's `body` fills, which no test could see it fill wrongly.
    /// Without a manager there is neither.
    static func detail(
        for row: MCPServerRow,
        manager: MCPServerManager?,
        judgeConfig: StoreConfiguration? = nil,
        onEdit: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () -> Void,
        onSetEnabled: @escaping @MainActor (Bool) async throws -> Void,
        onSetEnabledHere: @escaping @MainActor (Bool) async throws -> Void
    ) -> some View {
        MCPServerDetailView(
            row: row, connection: manager?.connection(for: row.id),
            folderRuleAvailable: manager?.hasWorkFolder ?? false,
            judgeConfig: judgeConfig,
            onEdit: onEdit, onDelete: onDelete,
            onSetEnabled: onSetEnabled, onSetEnabledHere: onSetEnabledHere)
            .id(row.id)
    }

    /// The Add/Edit sheet. It hands its draft to the manager's save and closes only when that
    /// returned; the Keychain's contents reach it as account NAMES from the manager's last
    /// reading, so it offers "leave blank to keep" exactly where something is stored. Static,
    /// with the manager passed in, so a test can open it and read what it was seeded with.
    static func editorSheet(
        editing: MCPServerConfig?,
        manager: MCPServerManager?,
        onSaved: @escaping @MainActor (UUID) -> Void
    ) -> MCPServerEditorSheet {
        MCPServerEditorSheet(
            editing: editing,
            storedSecretKeys: editing.map { manager?.storedSecretKeys(of: $0.id) ?? [] } ?? [],
            existing: manager?.serverRows.map(\.config) ?? [],
            onSave: { config, secrets in
                guard let manager else { throw MCPServerEditError.serversNotLoaded }
                try await manager.save(config, secrets: secrets)
                onSaved(config.id)
            })
    }
}

// MARK: - Master row

/// Hand-rolled, like every other settings master list: a native `List` brings indigo selection
/// and row dividers that no design token can reach.
private struct MCPServerListRow: View {

    let row: MCPServerRow
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var background: Color {
        if isSelected { return Colors.accentTint }
        return isHovered ? Colors.surfaceHover : .clear
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Circle()
                    .fill(MCPServerStatusStyle.dotColor(for: row))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.config.effectiveDisplayName)
                        .font(Typography.termBase)
                        .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle.squircle(CornerRadius.small).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The dot is colour alone; VoiceOver reads the row as its name and its standing.
        .accessibilityLabel("\(row.config.effectiveDisplayName), \(row.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .trackHover($isHovered)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
        .animationWithReduceMotion(Animations.quick, value: isSelected)
    }
}

#Preview("MCP Servers") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var catalog = PreviewStore.catalog()
    MCPServersSettingsView()
        .environment(store)
        .environment(catalog)
        .frame(width: 900, height: 700)
}

/// Card for configuring the global MCP Auto judge model override (`StoreConfiguration.mcpJudgeLLMOverride`).
struct MCPAutoJudgeModelCard: View {
    @Bindable var config: StoreConfiguration
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    nonisolated static let headerTitle = "Auto judge model"
    nonisolated static let footerText =
        "Shared by every server in Auto mode: the approval judge and the on-demand “Ask AI” "
            + "advisor on held MCP calls run on it. Empty fields fall back to the calling role's configuration for Auto verdicts, and to the global LLM configuration for “Ask AI”."

    var body: some View {
        SettingsCard(header: Self.headerTitle, footer: Self.footerText) {
            LLMOverrideEditor(
                config: config,
                keyPath: \.mcpJudgeLLMOverride,
                onTokenSaveError: onTokenSaveError,
                onTokenLoadError: onTokenLoadError)
        }
    }
}
