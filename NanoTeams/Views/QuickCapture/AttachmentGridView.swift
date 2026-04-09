import QuickLook
import SwiftUI

// MARK: - Attachment Grid View

/// Displays staged attachments + clipped texts for Quick Capture — drop zone when empty,
/// horizontal scroll grid otherwise. Reads the correct state slice based on `mode` (task
/// draft vs answer draft) and exposes drag/drop + QuickLook interactions.
struct AttachmentGridView: View {
    @Bindable var formState: QuickCaptureFormState
    let mode: QuickCaptureMode
    let activeDraftID: UUID
    let isSheetMode: Bool
    let onRequestFilePicker: () -> Void

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var popoverClipIndex: Int?

    private var isAnswerMode: Bool {
        if case .supervisorAnswer = mode { return true }
        return false
    }

    private var attachments: [StagedAttachment] {
        isAnswerMode ? formState.answerAttachments : formState.attachments
    }

    private var clippedTexts: [String] {
        isAnswerMode ? formState.answerClippedTexts : formState.clippedTexts
    }

    private var allItems: [AttachmentItem] {
        AttachmentItem.merge(clips: clippedTexts, files: attachments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if isSheetMode {
                Text("Attachments")
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(.secondary)
            }

            if attachments.isEmpty && clippedTexts.isEmpty {
                dropZonePlaceholder
            } else {
                attachmentGrid
            }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Drop Zone

    private var dropZonePlaceholder: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isDropTargeted ? Colors.accentTint : Colors.surfaceCard)
        )
        .overlay {
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(
                    isDropTargeted ? Colors.accent : Colors.borderSubtle,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            stageAttachments(from: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    // MARK: - Grid

    private var attachmentGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(allItems) { item in
                    switch item {
                    case .file(let attachment):
                        attachmentCell(attachment)
                    case .clip(let index, let text):
                        clippedTextCell(text, at: index)
                    }
                }
            }
            .padding(Spacing.s)
        }
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceCard)
        )
        .dropDestination(for: URL.self) { urls, _ in
            stageAttachments(from: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private func attachmentCell(_ attachment: StagedAttachment) -> some View {
        let isImage = VisionConstants.supportedExtensions.contains(
            attachment.url.pathExtension.lowercased()
        )

        return VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: attachment.thumbnail())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                    .onTapGesture { quickLookURL = attachment.url }
                    .overlay(alignment: .bottomLeading) {
                        if isImage && !config.isVisionConfigured {
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .font(.system(size: 10))
                                .foregroundStyle(Colors.warning)
                                .padding(2)
                                .background(
                                    Circle().fill(Colors.surfaceCard)
                                )
                                .help("Enable Vision model in Settings to analyze images")
                        }
                    }

                RemoveBadgeButton {
                    store.removeStagedAttachment(attachment)
                    withAnimation(Animations.quick) {
                        if isAnswerMode {
                            formState.answerAttachments.removeAll { $0.id == attachment.id }
                        } else {
                            formState.attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }

            Text(attachment.fileName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .frame(width: 64)
    }

    private func clippedTextCell(_ text: String, at index: Int) -> some View {
        let parsed = SourceContext.parse(text)
        let displayText = parsed?.body ?? text
        let label = parsed?.source ?? String(text.prefix(20))

        return VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
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
                    .onTapGesture { popoverClipIndex = index }

                RemoveBadgeButton {
                    withAnimation(Animations.quick) {
                        removeClip(at: index)
                    }
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(parsed != nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .frame(width: 64)
        .popover(isPresented: Binding(
            get: { popoverClipIndex == index },
            set: { if !$0 { popoverClipIndex = nil } }
        )) {
            ClipPopoverContent(text: text)
        }
    }

    // MARK: - Mutations

    private func stageAttachments(from urls: [URL]) {
        for url in urls {
            if let attachment = store.stageAttachment(url: url, draftID: activeDraftID) {
                if isAnswerMode {
                    if !formState.answerAttachments.contains(attachment) {
                        formState.answerAttachments.append(attachment)
                    }
                } else {
                    if !formState.attachments.contains(attachment) {
                        formState.attachments.append(attachment)
                    }
                }
            }
        }
    }

    private func removeClip(at index: Int) {
        if isAnswerMode {
            guard index < formState.answerClippedTexts.count else { return }
            _ = formState.answerClippedTexts.remove(at: index)
        } else {
            guard index < formState.clippedTexts.count else { return }
            _ = formState.clippedTexts.remove(at: index)
        }
    }
}
