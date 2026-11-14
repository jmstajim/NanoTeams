import SwiftUI

// MARK: - Preview data

/// Mocked server rows for the Server card's states — rendered through `./render_preview.sh`
/// for a design review, at the Settings window's default detail-pane width (about 509 pt).
// periphery:ignore - used in #Preview macros below
enum MCPServerStatusCardPreview {

    static func config(
        slug: String, name: String, url: String, enabled: Bool = true,
        authorization: MCPAuthorizationMode = .none, trusted: Bool = false,
        mode: MCPApprovalMode = .manual, strictness: MCPJudgeStrictness = .standard
    ) -> MCPServerConfig {
        MCPServerConfig(
            slug: MCPServerSlug(slug)!,
            displayName: name,
            transport: .http(MCPHTTPConfig(urlString: url, authorization: authorization)),
            isEnabled: enabled,
            isTrusted: trusted,
            approvalMode: mode,
            judgeStrictness: strictness)
    }

    static func row(
        _ config: MCPServerConfig, status: MCPServerStatus, hasSecrets: Bool = true,
        tools: MCPToolTally = MCPToolTally(approved: 0, new: 0, changed: 0, rejected: 0)
    ) -> MCPServerRow {
        MCPServerRow(
            config: config, status: status, isAllowedInThisFolder: true,
            hasRequiredSecrets: hasSecrets, catalogueUnverified: false, tools: tools,
            nothingItPublishesCanBeOffered: false)
    }

    /// Screenshot 4: a bearer-token server with no token in the Keychain, and unreachable.
    static func needsAToken() -> MCPServerRow {
        row(
            config(slug: "telegram", name: "Telegram", url: "http://127.0.0.1:8765/mcp", authorization: .staticBearer),
            status: .failed(reason: "Could not reach the server: the connection was refused"),
            hasSecrets: false)
    }

    /// A live server with tools waiting to be read, trusted, judged automatically.
    static func connectedWithReviews() -> MCPServerRow {
        row(
            config(slug: "figma", name: "Figma Desktop", url: "http://127.0.0.1:3845/mcp", trusted: true, mode: .auto),
            status: .connected(era: .modern),
            tools: MCPToolTally(approved: 1, new: 3, changed: 0, rejected: 0))
    }

    /// Switched off.
    static func off() -> MCPServerRow {
        row(
            config(slug: "figma", name: "Figma Desktop", url: "http://127.0.0.1:3845/mcp", enabled: false),
            status: .disabled)
    }

    static func presentation(_ row: MCPServerRow, hasConnection: Bool) -> MCPServerDetailPresentation {
        MCPServerDetailPresentation(
            row: row, hasConnection: hasConnection, serverInfoLabel: nil,
            folderRuleAvailable: true, isRefreshing: false, rejections: [])
    }
}

// periphery:ignore - used in #Preview macros below
private func statusCardPreview(_ row: MCPServerRow, hasConnection: Bool) -> some View {
    ScrollView {
        MCPServerStatusCard(
            row: row,
            presentation: MCPServerStatusCardPreview.presentation(row, hasConnection: hasConnection),
            isRefreshing: false,
            onFlip: { _, _ in }, onEdit: {}, onReconnect: {}, onRefresh: {}, onDelete: {})
        .padding(Spacing.xl)
    }
    .frame(width: 509, height: 420)
    .background(Colors.surfacePrimary)
}

#Preview("Needs a token — unreachable") {
    statusCardPreview(MCPServerStatusCardPreview.needsAToken(), hasConnection: false)
}

#Preview("Connected — 3 to review, trusted, Auto") {
    statusCardPreview(MCPServerStatusCardPreview.connectedWithReviews(), hasConnection: true)
}

#Preview("Off") {
    statusCardPreview(MCPServerStatusCardPreview.off(), hasConnection: false)
}
