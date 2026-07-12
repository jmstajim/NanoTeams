import SwiftUI

// MARK: - Attachment Item (unified file + clip for display)

/// Unifies file attachments and clipped text snippets for display in a single grid.
nonisolated enum AttachmentItem: Identifiable {
    case file(StagedAttachment)
    case clip(index: Int, text: String)

    var id: String {
        switch self {
        case .file(let a): return "file-\(a.id)"
        case .clip(let i, let text): return "clip-\(i)-\(text.prefix(40))"
        }
    }

    static func merge(clips: [String], files: [StagedAttachment]) -> [AttachmentItem] {
        clips.enumerated().map { .clip(index: $0.offset, text: $0.element) }
            + files.map { .file($0) }
    }
}

// MARK: - Clip Cell Presentation

/// Pure resolver deciding how a `clippedTexts` entry renders. A single branch
/// point shared by every clip cell (`MessageComposer.clipCell`,
/// `ReadOnlyAttachmentGrid.ClipCell`, `ClipPopoverContent`) so skill vs
/// source-enriched vs plain clips look consistent everywhere. `SkillClip`
/// is tried first (distinct sentinel prefix), then `SourceContext`.
nonisolated enum ClipCellPresentation {
    enum Kind: Equatable {
        case skill(SkillClip)
        case sourced(source: String, body: String)
        case plain(String)
    }

    static func resolve(_ text: String) -> Kind {
        if let skill = SkillClip.parse(text) { return .skill(skill) }
        if let parsed = SourceContext.parse(text) { return .sourced(source: parsed.source, body: parsed.body) }
        return .plain(text)
    }
}

// MARK: - Clip Popover Content

/// Shared popover for displaying a clipped text / skill with its header.
struct ClipPopoverContent: View {
    let text: String
    @State private var contentHeight: CGFloat = .infinity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                switch ClipCellPresentation.resolve(text) {
                case .skill(let skill):
                    HStack(spacing: Spacing.xs) {
                        Label("/\(skill.name)", systemImage: "terminal")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.accent)
                            .lineLimit(1)
                        if let origin = skill.origin {
                            TerminalStatusBadge(
                                glyph: TerminalGlyph.prompt,
                                label: origin.badgeLabel,
                                color: origin == .project ? Colors.accent : Colors.info,
                                bordered: false
                            )
                        }
                    }
                    if let agent = skill.agentLabel {
                        Text(agent)
                            .font(Typography.caption2)
                            .foregroundStyle(Colors.textSecondary)
                    }
                    Text(skill.body)
                        .font(Typography.termBase)
                        .textSelection(.enabled)
                case .sourced(let source, let body):
                    Label(source, systemImage: "doc.text")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.accent)
                        .lineLimit(2)
                    Text(body)
                        .font(Typography.termBase)
                        .textSelection(.enabled)
                case .plain(let body):
                    Text(body)
                        .font(Typography.termBase)
                        .textSelection(.enabled)
                }
            }
            .padding(Spacing.m)
            .frame(width: 280, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                if abs(newHeight - contentHeight) > 1 { contentHeight = newHeight }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, 200))
    }
}

// MARK: - Remove Badge Button

/// Shared dismiss badge for attachment/clip cells. Visually distinct from
/// `CloseButton` (panel close) so the user can tell single-item removal
/// from closing the surface at a glance: an accent-tinted chip rather than
/// a neutral chrome tile. Same `xmark` glyph, but white-on-purple at 16×16
/// keys it as "interactive purple action chip" — the same vocabulary the
/// panel already uses for `+` and the send button — whereas `CloseButton`
/// stays in the `surfaceElevated` chrome family.
struct RemoveBadgeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(Typography.term2xs.weight(.bold))
                .foregroundStyle(Colors.textOnAccent)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
    }
}
