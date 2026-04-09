import SwiftUI
import QuickLook

// MARK: - Read-Only Attachment Grid

/// A horizontal grid of file thumbnails and clipped text cells — read-only (no remove badges).
/// Used in SupervisorTaskItemView to display task attachments visually.
struct ReadOnlyAttachmentGrid: View {
    let attachmentPaths: [String]
    let clippedTexts: [String]
    let workFolderURL: URL?

    @State private var resolvedFiles: [ResolvedFile]

    init(attachmentPaths: [String], clippedTexts: [String], workFolderURL: URL?) {
        self.attachmentPaths = attachmentPaths
        self.clippedTexts = clippedTexts
        self.workFolderURL = workFolderURL
        self._resolvedFiles = State(initialValue: Self.resolveFiles(paths: attachmentPaths, workFolderURL: workFolderURL))
    }

    var body: some View {
        let nonEmptyClips = clippedTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !resolvedFiles.isEmpty || !nonEmptyClips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Array(nonEmptyClips.enumerated()), id: \.offset) { _, text in
                        ClipCell(text: text)
                    }
                    ForEach(resolvedFiles, id: \.relativePath) { file in
                        FileCell(url: file.url, relativePath: file.relativePath, isImage: file.isImage)
                    }
                }
                .padding(Spacing.s)
            }
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Colors.surfaceCard)
            )
        }
    }

    // MARK: - Path Resolution

    struct ResolvedFile {
        let url: URL
        let relativePath: String
        let isImage: Bool
    }

    static func resolveFiles(paths: [String], workFolderURL: URL?) -> [ResolvedFile] {
        guard let base = workFolderURL else { return [] }
        return paths.compactMap { rel in
            let url = base.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let ext = url.pathExtension.lowercased()
            let isImage = VisionConstants.supportedExtensions.contains(ext)
            return ResolvedFile(url: url, relativePath: rel, isImage: isImage)
        }
    }
}

// MARK: - File Cell

private struct FileCell: View {
    let url: URL
    let relativePath: String
    let isImage: Bool

    @State private var quickLookURL: URL?
    @State private var cachedThumbnail: NSImage?

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            Image(nsImage: cachedThumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.micro, style: .continuous))
                .onTapGesture { quickLookURL = url }

            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .frame(width: 64)
        .quickLookPreview($quickLookURL)
        .task {
            if let attachment = try? StagedAttachment(url: url, stagedRelativePath: relativePath) {
                cachedThumbnail = attachment.thumbnail()
            }
        }
    }
}

// MARK: - Clip Cell

private struct ClipCell: View {
    let text: String

    @State private var isShowingPopover = false

    var body: some View {
        let parsed = SourceContext.parse(text)
        let displayText = parsed?.body ?? text
        let label = parsed?.source ?? String(text.prefix(20))

        VStack(spacing: Spacing.xxs) {
            Text(displayText)
                .font(.system(size: 6, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .lineSpacing(0)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(4)
                .frame(width: 48, height: 48)
                .background(Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle.squircle(CornerRadius.micro)
                        .strokeBorder(
                            parsed != nil ? Colors.accentBorder : Colors.borderSubtle,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
                .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                .onTapGesture { isShowingPopover = true }

            Text(label)
                .font(.caption2)
                .foregroundStyle(parsed != nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .frame(width: 64)
        .popover(isPresented: $isShowingPopover) {
            ClipPopoverContent(text: text)
        }
    }
}

