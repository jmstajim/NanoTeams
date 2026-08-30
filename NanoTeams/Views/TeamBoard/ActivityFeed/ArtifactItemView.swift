import SwiftUI

/// Renders a single artifact card. Tap (or context-menu "Open in Window")
/// opens the full untruncated content in a standalone window — there is no
/// inline expansion or chevron.
struct ArtifactItemView: View {
    let artifact: Artifact
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    let originTaskID: Int
    let workFolderURL: URL?
    var onAvatarTap: (() -> Void)? = nil
    /// Override role display name. `nil` falls back to roleDefinition.name.
    var roleLabelOverride: String? = nil
    /// Optional ` from <Team>` suffix in secondary gray for delegated
    /// child-team items.
    var roleTeamSuffix: String? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(NTMSOrchestrator.self) private var store

    // MARK: - Derived

    private var roleName: String { roleLabelOverride ?? roleDefinition?.name ?? role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? role.tintColor }

    private func openDetailWindow() {
        openWindow(value: ActivityDetailWindow.artifact(
            taskID: originTaskID,
            artifactName: artifact.name,
            mimeType: artifact.mimeType,
            relativePath: artifact.relativePath,
            createdAt: artifact.createdAt
        ))
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedRoleAvatar(role: role, roleDefinition: roleDefinition, onTap: showHeader ? onAvatarTap : nil)
                .opacity(showHeader ? 1 : 0)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                if showHeader {
                    HStack(spacing: Spacing.s) {
                        roleNameText(roleName: roleName, teamSuffix: roleTeamSuffix, tintColor: tintColor)
                        Text("produced artifact").font(Typography.termXs).foregroundStyle(Colors.textSecondary)
                        Spacer()
                        Text(artifact.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(Typography.term2xs).foregroundStyle(Colors.textTertiary)
                    }
                }

                artifactCard
            }
        }
        .contextMenu {
            Button {
                openDetailWindow()
            } label: {
                Label("Open in Window", systemImage: "rectangle.on.rectangle")
            }

            Divider()

            Button {
                copyContent()
            } label: {
                Label("Copy Content", systemImage: "doc.on.doc")
            }

            if let path = artifact.relativePath {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "link")
                }
            }
        }
    }

    // MARK: - Artifact Card

    private var artifactCard: some View {
        HStack(spacing: ActivityCardTokens.contentSpacing) {
            Image(systemName: "doc")
                .foregroundStyle(Colors.artifact)
                .font(Typography.termBase)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(Typography.termSm.weight(.medium))
                    .foregroundStyle(Colors.textPrimary)
                Text(artifact.mimeType).font(Typography.term2xs).foregroundStyle(Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, Spacing.xs)
        .padding(.leading, Spacing.s)
        .overlay(alignment: .leading) {
            RoundedRectangle.squircle(CornerRadius.accent)
                .fill(Colors.artifact)
                .frame(width: 2)
                .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { openDetailWindow() }
    }

    // MARK: - Helpers

    private func copyContent() {
        guard let relativePath = artifact.relativePath else {
            store.lastErrorMessage = "Artifact has no on-disk path yet — nothing to copy."
            return
        }
        guard let projectURL = workFolderURL else {
            store.lastErrorMessage = "Open a work folder to copy artifact content."
            return
        }
        let fileURL = projectURL.appendingPathComponent(".nanoteams")
            .appendingPathComponent(relativePath)
        do {
            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileContent, forType: .string)
        } catch {
            store.lastErrorMessage = "Couldn't copy artifact content: \(error.localizedDescription)"
        }
    }
}

// MARK: - Equatable

/// See `MessageBubbleView`'s Equatable extension for full rationale.
/// `Artifact` is `Hashable` so `==` is structural. `onAvatarTap` excluded
/// (closure; captures only props in `==`).
extension ArtifactItemView: Equatable {
    static func == (lhs: ArtifactItemView, rhs: ArtifactItemView) -> Bool {
        lhs.artifact == rhs.artifact
            && lhs.role == rhs.role
            && lhs.roleDefinition?.renderIdentity == rhs.roleDefinition?.renderIdentity
            && lhs.showHeader == rhs.showHeader
            && lhs.originTaskID == rhs.originTaskID
            && lhs.workFolderURL == rhs.workFolderURL
            && lhs.roleLabelOverride == rhs.roleLabelOverride
            && lhs.roleTeamSuffix == rhs.roleTeamSuffix
    }
}

// MARK: - Preview

#Preview("Variants") {
    @Previewable @State var previewStore = PreviewStore.make()
    VStack(spacing: 16) {
        ArtifactItemView(
            artifact: Artifact(name: "Product Requirements", icon: "doc.text", description: "PRD for the feature"),
            role: .productManager,
            roleDefinition: nil,
            showHeader: true,
            originTaskID: 1,
            workFolderURL: nil
        )
        ArtifactItemView(
            artifact: Artifact(name: "Implementation Plan", icon: "list.bullet.rectangle", description: "Technical plan"),
            role: .techLead,
            roleDefinition: nil,
            showHeader: true,
            originTaskID: 1,
            workFolderURL: nil
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(previewStore)
}
