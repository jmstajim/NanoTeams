import SwiftUI

// MARK: - Attachment Item (unified file + clip for display)

/// Unifies file attachments and clipped text snippets for display in a single grid.
enum AttachmentItem: Identifiable {
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

// MARK: - Clip Popover Content

/// Shared popover for displaying clipped text with optional source context header.
struct ClipPopoverContent: View {
    let text: String
    @State private var contentHeight: CGFloat = .infinity

    var body: some View {
        let parsed = SourceContext.parse(text)
        let displayText = parsed?.body ?? text

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let source = parsed?.source {
                    Label(source, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(Colors.accent)
                        .lineLimit(2)
                }
                Text(displayText)
                    .font(.body)
                    .textSelection(.enabled)
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

/// Shared dismiss badge for attachment/clip cells (xmark circle, top-trailing).
struct RemoveBadgeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .offset(x: 4, y: -4)
    }
}
