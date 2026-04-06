import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Reusable attachment area for supervisor answer input.
/// Owns the file picker, drop destination, drop overlay, and thumbnail grid.
/// The + button lives in the parent's action row and triggers the file picker via `isShowingFilePicker`.
struct SupervisorAnswerAttachmentArea: View {
    @Binding var attachments: [StagedAttachment]
    @Binding var isShowingFilePicker: Bool
    @Binding var isDropTargeted: Bool
    var onStage: (URL) -> StagedAttachment?
    var onRemove: (StagedAttachment) -> Void

    @State private var importErrorMessage: String?
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let error = importErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Colors.error)
                    .lineLimit(1)
            }

            if !attachments.isEmpty {
                attachmentGrid
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                stageURLs(urls)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Drop Zone Modifier

    /// Applies `.dropDestination` + conditional dashed-border overlay to the given content.
    /// Use: `content.modifier(area.dropZone())`
    func dropZone() -> DropZoneModifier {
        DropZoneModifier(
            isDropTargeted: $isDropTargeted,
            onDrop: { urls in stageURLs(urls) }
        )
    }

    // MARK: - Grid

    private var attachmentGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 52, maximum: 60))],
            spacing: Spacing.xs
        ) {
            ForEach(attachments) { attachment in
                attachmentCell(attachment)
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceOverlay)
        )
    }

    private func attachmentCell(_ attachment: StagedAttachment) -> some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: attachment.thumbnail(size: 48))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                    .onTapGesture { quickLookURL = attachment.url }

                RemoveBadgeButton {
                    onRemove(attachment)
                    withAnimation(Animations.quick) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }

            Text(attachment.fileName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52)
        }
    }

    // MARK: - Helpers

    private func stageURLs(_ urls: [URL]) {
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            if let attachment = onStage(url), !attachments.contains(attachment) {
                attachments.append(attachment)
            }
        }
    }
}

// MARK: - Drop Zone Modifier

/// Shared drop destination + dashed overlay for supervisor answer attachment areas.
struct DropZoneModifier: ViewModifier {
    @Binding var isDropTargeted: Bool
    var onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                onDrop(urls)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle.squircle(CornerRadius.small)
                        .strokeBorder(
                            Colors.accent,
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                        .background(
                            RoundedRectangle.squircle(CornerRadius.small)
                                .fill(Colors.accentTint)
                        )
                        .overlay {
                            HStack(spacing: Spacing.s) {
                                Image(systemName: "arrow.down.doc")
                                    .foregroundStyle(.tertiary)
                                Text("Drop files here")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}
