import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Unified message/answer composer used by all four message-entry surfaces:
/// ActivityFeed (`SupervisorInputCard`), Watchtower banner, QuickCapture answer mode,
/// and QuickCapture task creation.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────┐
/// │ [clips + attachment cards]       │
/// ├──────────────────────────────────┤
/// │ TextField("Send a message...")   │
/// ├──────────────────────────────────┤
/// │ (+)  (⚙)              (↑ send)  │
/// └──────────────────────────────────┘
/// ```
///
/// During an active file drag the entire composer is tinted with a subtle accent
/// background + solid accent border. Content stays fully visible — no modal label.
struct MessageComposer<SettingsMenu: View>: View {
    @Binding var text: String
    @Binding var attachments: [StagedAttachment]
    var clips: Binding<[String]>?
    let placeholder: String
    let canSubmit: Bool
    let isSubmitting: Bool
    var onSubmit: () -> Void
    var onStageAttachment: (URL) -> StagedAttachment?
    var onRemoveAttachment: (StagedAttachment) -> Void

    /// File picker state — owned by the Composer by default.
    /// Parents that need to control the file picker externally (e.g., NSPanel)
    /// can pass a binding via `filePickerBinding`.
    var filePickerBinding: Binding<Bool>?

    /// When true, the composer grabs focus on appear via `.task`. Default false so
    /// answer-mode surfaces (which show a question first) don't steal the cursor.
    var autofocusOnAppear: Bool = false

    // Declared last so QuickCapture's trailing-closure call sites bind to
    // `settingsMenu` via SE-0286 forward-scan. Other surfaces use the
    // `EmbedFilesSettingsButton<EmptyView>` convenience init below.
    @ViewBuilder var settingsMenu: SettingsMenu

    @Environment(StoreConfiguration.self) private var config
    @Environment(DictationService.self) private var dictation
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var popoverClipIndex: Int?
    @State private var importErrorMessage: String?
    @FocusState private var internalFocus: Bool
    @State private var internalShowingFilePicker = false

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
        // Only install the composer's own `.fileImporter` when no external binding
        // was supplied. When the parent owns the picker (QuickCapture inside an
        // NSPanel — nested `.fileImporter` does not fire there), the parent installs
        // its own importer against the same binding. Installing both would double-stage
        // every selected file.
        Group {
            if filePickerBinding == nil {
                composerBody.fileImporter(
                    isPresented: $internalShowingFilePicker,
                    allowedContentTypes: [.item],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        stageURLs(urls)
                    case .failure(let error):
                        appendImportError(error.localizedDescription)
                    }
                }
            } else {
                composerBody
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

    private var composerBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if hasAttachments {
                attachmentGrid
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .accessibilityLabel("Message input")
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .strokeBorder(Colors.borderSubtle, lineWidth: 0.5)
                )
                .focused($internalFocus)
                .enterSendsMessage(
                    config.enterSendsMessage,
                    canSubmit: canSubmit,
                    isSubmitting: isSubmitting,
                    onSubmit: handleSubmit
                )

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

                MessageSendButton(
                    canSubmit: canSubmit,
                    isSubmitting: isSubmitting,
                    onSubmit: handleSubmit
                )
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
                    .fill(Colors.accentTint)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.down.doc")
                    Text("Drop to attach")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Colors.accent)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .background(
                    Capsule(style: .continuous)
                        .fill(Colors.surfaceElevated)
                )
                .allowsHitTesting(false)
            }
        }
        .animation(Animations.quick, value: isDropTargeted)
        .task {
            if autofocusOnAppear { internalFocus = true }
        }
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

    private func handleSubmit() { dictation.flushAndThen(onSubmit) }

    private func stageURLs(_ urls: [URL]) {
        var rejectedNames: [String] = []
        for url in urls {
            // Directories can't be staged — reject explicitly so the drop doesn't
            // look successful while producing nothing in the attachment grid.
            if url.hasDirectoryPath {
                rejectedNames.append(url.lastPathComponent)
                continue
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard let attachment = onStageAttachment(url) else {
                // `onStageAttachment` already set `lastErrorMessage` on the store for
                // the specific failure; collect the filename so we can aggregate a
                // single banner covering the whole batch.
                rejectedNames.append(url.lastPathComponent)
                continue
            }
            if !attachments.contains(attachment) {
                attachments.append(attachment)
            }
        }
        if !rejectedNames.isEmpty {
            appendImportError("Could not attach: \(rejectedNames.joined(separator: ", "))")
        }
    }

    // Aggregates so a second failure doesn't silently overwrite the first.
    private func appendImportError(_ message: String) {
        if let existing = importErrorMessage, !existing.isEmpty {
            importErrorMessage = existing + "\n" + message
        } else {
            importErrorMessage = message
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

extension MessageComposer where SettingsMenu == EmbedFilesSettingsButton<EmptyView> {
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
        onRemoveAttachment: @escaping (StagedAttachment) -> Void,
        autofocusOnAppear: Bool = false
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
        self.autofocusOnAppear = autofocusOnAppear
        self.settingsMenu = EmbedFilesSettingsButton()
    }
}
