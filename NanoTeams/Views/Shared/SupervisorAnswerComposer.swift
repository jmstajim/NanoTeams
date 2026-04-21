import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Unified supervisor answer input used by all answer surfaces:
/// ActivityFeed (`SupervisorInputCard`), Watchtower banner, and QuickCapture overlay/sheet.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────┐
/// │ TextField("Send a message...")   │
/// ├──────────────────────────────────┤
/// │ [clips + attachment cards]       │
/// ├──────────────────────────────────┤
/// │ (+)  (⚙)              (↑ send)  │
/// └──────────────────────────────────┘
/// ```
struct SupervisorAnswerComposer<SettingsMenu: View>: View {
    @Binding var text: String
    @Binding var attachments: [StagedAttachment]
    var clips: Binding<[String]>?
    let placeholder: String
    let canSubmit: Bool
    let isSubmitting: Bool
    var onSubmit: () -> Void
    var onStageAttachment: (URL) -> StagedAttachment?
    var onRemoveAttachment: (StagedAttachment) -> Void
    @ViewBuilder var settingsMenu: SettingsMenu

    @Environment(StoreConfiguration.self) private var config
    @Environment(DictationService.self) private var dictation
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var popoverClipIndex: Int?
    @State private var importErrorMessage: String?

    /// File picker state — owned by the Composer by default.
    /// Parents that need to control the file picker externally (e.g., NSPanel)
    /// can pass a binding via `filePickerBinding`.
    @State private var internalShowingFilePicker = false
    var filePickerBinding: Binding<Bool>?

    private var isShowingFilePicker: Binding<Bool> {
        filePickerBinding ?? $internalShowingFilePicker
    }

    private var clipTexts: [String] {
        clips?.wrappedValue ?? []
    }

    private var hasAttachments: Bool {
        !attachments.isEmpty || !clipTexts.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .accessibilityLabel("Answer to supervisor question")
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .strokeBorder(Colors.borderSubtle, lineWidth: 0.5)
                )
                .enterSendsMessage(
                    config.enterSendsMessage,
                    canSubmit: canSubmit,
                    isSubmitting: isSubmitting,
                    onSubmit: handleSubmit
                )

            if hasAttachments {
                attachmentGrid
            }

            HStack {
                Button {
                    isShowingFilePicker.wrappedValue = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .foregroundStyle(Colors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach files")

                settingsMenu

                if hasAttachments {
                    let count = attachments.count + clipTexts.count
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                DictationMicButton(text: $text)

                Button {
                    handleSubmit()
                } label: {
                    if isSubmitting {
                        NTMSLoader(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(!canSubmit ? Colors.textTertiary : Colors.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            stageURLs(urls)
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
        .fileImporter(
            isPresented: isShowingFilePicker,
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
        .alert("File Import Error", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            if let msg = importErrorMessage { Text(msg) }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Attachment Grid

    private var attachmentGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 52, maximum: 60))],
            spacing: Spacing.xs
        ) {
            // Clip cells
            ForEach(Array(clipTexts.enumerated()), id: \.offset) { index, clipText in
                clipCell(index: index, text: clipText)
            }
            // File cells
            ForEach(attachments) { attachment in
                fileCell(attachment)
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceOverlay)
        )
    }

    private func clipCell(index: Int, text: String) -> some View {
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
                    .frame(width: 40, height: 40)
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
                        guard index < (clips?.wrappedValue.count ?? 0) else { return }
                        _ = clips?.wrappedValue.remove(at: index)
                    }
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(parsed != nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52)
        }
        .popover(isPresented: Binding(
            get: { popoverClipIndex == index },
            set: { if !$0 { popoverClipIndex = nil } }
        )) {
            ClipPopoverContent(text: text)
        }
    }

    private func fileCell(_ attachment: StagedAttachment) -> some View {
        let isImage = VisionConstants.supportedExtensions.contains(
            attachment.url.pathExtension.lowercased()
        )

        return VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: attachment.thumbnail(size: 48))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                    .onTapGesture { quickLookURL = attachment.url }
                    .overlay(alignment: .bottomLeading) {
                        if isImage && !config.isVisionConfigured {
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .font(.system(size: 10))
                                .foregroundStyle(Colors.warning)
                                .padding(2)
                                .background(Circle().fill(Colors.surfaceCard))
                                .help("Enable Vision model in Settings to analyze images")
                        }
                    }

                RemoveBadgeButton {
                    onRemoveAttachment(attachment)
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

    // Flushes dictation so the last spoken words land before submit.
    private func handleSubmit() { dictation.flushAndThen(onSubmit) }

    private func stageURLs(_ urls: [URL]) {
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            if let attachment = onStageAttachment(url), !attachments.contains(attachment) {
                attachments.append(attachment)
            }
        }
    }
}

// MARK: - Embed Files Settings Button

/// Gear button with "Embed files in prompt" toggle + optional extra toggles.
/// QuickCapture adds "Keep open in chat mode"; other surfaces use the default (embed only).
struct EmbedFilesSettingsButton<Extra: View>: View {
    @ViewBuilder var extraContent: Extra
    @Environment(StoreConfiguration.self) private var config
    @State private var isShowing = false

    var body: some View {
        @Bindable var config = config
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.subheadline)
                .foregroundStyle(Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                extraContent
                Toggle("Embed files in prompt", isOn: $config.embedFilesInPrompt)
                    .toggleStyle(.checkbox)
            }
            .padding(Spacing.m)
        }
    }
}

extension EmbedFilesSettingsButton where Extra == EmptyView {
    init() {
        self.extraContent = EmptyView()
    }
}

extension SupervisorAnswerComposer where SettingsMenu == EmbedFilesSettingsButton<EmptyView> {
    /// Convenience init with the default embed-files settings button.
    init(
        text: Binding<String>,
        attachments: Binding<[StagedAttachment]>,
        clips: Binding<[String]>? = nil,
        placeholder: String = "Send a message...",
        canSubmit: Bool,
        isSubmitting: Bool = false,
        onSubmit: @escaping () -> Void,
        onStageAttachment: @escaping (URL) -> StagedAttachment?,
        onRemoveAttachment: @escaping (StagedAttachment) -> Void
    ) {
        self._text = text
        self._attachments = attachments
        self.clips = clips
        self.placeholder = placeholder
        self.canSubmit = canSubmit
        self.isSubmitting = isSubmitting
        self.onSubmit = onSubmit
        self.onStageAttachment = onStageAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.settingsMenu = EmbedFilesSettingsButton()
    }
}
