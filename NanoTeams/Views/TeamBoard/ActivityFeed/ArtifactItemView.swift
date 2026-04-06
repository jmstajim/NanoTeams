import SwiftUI

/// Renders a single artifact card with expandable content and context menu.
struct ArtifactItemView: View {
    let artifact: Artifact
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    let content: String?
    let workFolderURL: URL?
    var onAvatarTap: (() -> Void)? = nil
    @Binding var artifactsExpanded: Set<String>
    var onExpand: (Artifact) -> Void

    // MARK: - Derived

    private var roleName: String { roleDefinition?.name ?? role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? role.tintColor }
    private var isExpanded: Bool { artifactsExpanded.contains(artifact.id) }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedRoleAvatar(role: role, roleDefinition: roleDefinition, onTap: showHeader ? onAvatarTap : nil)
                .opacity(showHeader ? 1 : 0)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                if showHeader {
                    HStack(spacing: 6) {
                        Text(roleName).font(.caption.weight(.semibold)).foregroundStyle(tintColor)
                        Text("produced artifact").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(artifact.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                artifactCard
            }
        }
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    artifactsExpanded.insert(artifact.id)
                    onExpand(artifact)
                }
            } label: {
                Label("View Content", systemImage: "doc.text.magnifyingglass")
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
        VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
            HStack(spacing: ActivityCardTokens.contentSpacing) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(Colors.artifact)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name).font(.subheadline.weight(.medium))
                    Text(artifact.mimeType).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if isExpanded {
                contentView
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.leading, Spacing.s)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: CornerRadius.accent, style: .continuous)
                .fill(Colors.artifact)
                .frame(width: 2)
                .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    artifactsExpanded.remove(artifact.id)
                } else {
                    artifactsExpanded.insert(artifact.id)
                    onExpand(artifact)
                }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let content {
            ScrollView {
                if isMarkdown {
                    Text(.init(content))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(content)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: ActivityCardTokens.artifactContentMaxHeight)
            .padding(ActivityCardTokens.innerPadding)
            .background(
                RoundedRectangle(cornerRadius: ActivityCardTokens.innerCornerRadius, style: .continuous)
                    .fill(Colors.surfaceOverlay)
            )
        } else {
            HStack {
                NTMSLoader(.small)
                Text("Loading content...").font(.caption).foregroundStyle(.secondary)
            }
            .padding(ActivityCardTokens.innerPadding)
        }
    }

    // MARK: - Helpers

    private var isMarkdown: Bool {
        artifact.mimeType == "text/markdown" || artifact.name.lowercased().hasSuffix(".md")
    }

    private func copyContent() {
        if let content {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
        } else if let relativePath = artifact.relativePath,
                  let projectURL = workFolderURL {
            let fileURL = projectURL.appendingPathComponent(".nanoteams")
                .appendingPathComponent(relativePath)
            if let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fileContent, forType: .string)
            }
        }
    }
}

// MARK: - Preview

#Preview("Collapsed") {
    @Previewable @State var expanded: Set<String> = []
    ArtifactItemView(
        artifact: Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD for the feature"),
        role: .productManager,
        roleDefinition: nil,
        showHeader: true,
        content: "# Product Requirements\n\n## Overview\nBuild a notification system for real-time alerts.",
        workFolderURL: nil,
        artifactsExpanded: $expanded,
        onExpand: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Expanded") {
    @Previewable @State var expanded: Set<String> = [Artifact.slugify("Implementation Plan")]
    ArtifactItemView(
        artifact: Artifact(name: "Implementation Plan", icon: "list.bullet.rectangle", description: "Technical plan"),
        role: .techLead,
        roleDefinition: nil,
        showHeader: true,
        content: "# Implementation Plan\n\n## Architecture\n- Use WebSocket for real-time delivery\n- Redis pub/sub for message routing\n- PostgreSQL for persistence\n\n## Milestones\n1. Core notification service\n2. WebSocket gateway\n3. Client SDK\n4. Admin dashboard",
        workFolderURL: nil,
        artifactsExpanded: $expanded,
        onExpand: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Loading") {
    @Previewable @State var expanded: Set<String> = [Artifact.slugify("Design Spec")]
    ArtifactItemView(
        artifact: Artifact(name: "Design Spec", icon: "paintbrush", description: "UX design specification"),
        role: .uxDesigner,
        roleDefinition: nil,
        showHeader: true,
        content: nil,
        workFolderURL: nil,
        artifactsExpanded: $expanded,
        onExpand: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
