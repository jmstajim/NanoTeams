import AppKit
import Carbon.HIToolbox
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Unified message/answer composer used by all message-entry surfaces:
/// ActivityFeed dock (`TeamActivityComposer`), Watchtower banner, QuickCapture
/// answer mode, and QuickCapture task creation.
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
    var onSubmit: @MainActor @Sendable () -> Void
    var onStageAttachment: (URL) -> StagedAttachment?
    var onRemoveAttachment: (StagedAttachment) -> Void

    /// File picker state — owned by the Composer by default.
    /// Parents that need to control the file picker externally (e.g., NSPanel)
    /// can pass a binding via `filePickerBinding`.
    var filePickerBinding: Binding<Bool>?

    /// When true, the composer grabs focus on appear via `.task`. Default false so
    /// answer-mode surfaces (which show a question first) don't steal the cursor.
    var autofocusOnAppear: Bool = false

    /// Minimum visible line count when the field is empty. Threaded through
    /// to `EditableMessageTextView` which clamps its intrinsic height to
    /// `lineHeight * minLineCount + insets`. Must be ≥ 1 — clamped by
    /// `clampMinLines(_:)` because negative / zero values would otherwise
    /// collapse the field to nothing.
    var minLineCount: Int = 1

    /// Pixel cap for the message field. Past the cap the underlying
    /// `EditableMessageTextView` (native `NSTextView` inside an `NSScrollView`)
    /// scrolls internally and NSTextView's native `scrollRangeToVisible` keeps
    /// the caret visible no matter where the user is editing.
    ///
    /// Defaults to `MessageComposerLayout.defaultMaxTextFieldHeight`. Surfaces
    /// with a known pane height (`TeamActivityComposer`, `QuickCaptureFormView`)
    /// override with a computed value that tracks their pane.
    var maxTextFieldHeight: CGFloat = MessageComposerLayout.defaultMaxTextFieldHeight

    /// Work-folder root used by the "/" skills picker to discover project-level
    /// agent skills. `nil` (default storage / no folder) → global skills only.
    /// Threaded in by hosts that have the orchestrator so the shared composer
    /// stays orchestrator-free. The picker shows only when a `clips` pipe exists.
    var skillsProjectRoot: URL?

    /// Editor-field mode: the composer becomes a plain multi-line text editor
    /// with the QC affordance row (`+` attach / `/` skills / gear / … / sparkles
    /// / mic) but **no send button and no keyhint chip** — used by the Autovisor
    /// Goal editors, where there is nothing to "send". Return always inserts a
    /// newline (the `enterSendsMessage` preference is ignored). Default `false`
    /// keeps every existing message-surface call site byte-identical.
    var isEditorField: Bool = false

    /// Optional host mirror of the internal `ImprovePromptButton` streaming state.
    /// Editor-mode hosts (the Autovisor Goal editors) pass one to lock their Enable
    /// button + suspend goal autosave while the rewrite streams. Precedent:
    /// `filePickerBinding`.
    var externalIsImproving: Binding<Bool>?

    // Declared last so QuickCapture's trailing-closure call sites bind to
    // `settingsMenu` via SE-0286 forward-scan. Other surfaces use the
    // `EmbedFilesSettingsButton<EmptyView>` convenience init below.
    @ViewBuilder var settingsMenu: SettingsMenu

    @Environment(StoreConfiguration.self) private var config
    @Environment(DictationService.self) private var dictation
    /// Handed to `SettingsNavigation`, which owns the tab write — an environment action
    /// can only be read from the view that declares it.
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var popoverClipIndex: Int?
    @State private var importErrorMessage: String?

    /// Bridges AppKit first-responder state into SwiftUI so
    /// `.onChange(of: isFocused)` can gate the Cmd+V paste-monitor
    /// lifecycle. Native caret focus is handled by the responder chain
    /// directly.
    @State private var isFocused: Bool = false
    @State private var internalShowingFilePicker = false
    @State private var pasteMonitorOwnerID = UUID()
    @State private var hasRegisteredMonitor: Bool = false

    /// True while `ImprovePromptButton` streams a rewrite into `text`. Gates
    /// every submit path and locks the field so a half-streamed prompt can't
    /// be sent, edited, or dictated over.
    @State private var isImprovingPrompt = false

    /// Submit is blocked while the improve stream is mutating `text` — the
    /// host's `canSubmit` can't know about the in-flight rewrite, so the gate
    /// lives here (feeds the return-key policy, the send button, and the
    /// keyhint chip alike).
    private var effectiveCanSubmit: Bool { canSubmit && !isImprovingPrompt }

    private var clipTexts: [String] {
        clips?.wrappedValue ?? []
    }

    private var hasAttachments: Bool {
        !attachments.isEmpty || !clipTexts.isEmpty
    }

    /// Clamps a caller-supplied `minLineCount` to the SwiftUI-safe floor of 1.
    /// `.lineLimit(0...)` / `.lineLimit(-1...)` are undefined; clamping degrades
    /// invalid input to a defined 1-line floor without crashing the app.
    /// Static so tests can pin the clamp without rendering the view.
    nonisolated static func clampMinLines(_ value: Int) -> Int {
        max(1, value)
    }

    /// Pure Return-key decision. In editor-field mode the key ALWAYS inserts a
    /// newline (there is nothing to submit, so the `enterSendsMessage` preference
    /// is bypassed); otherwise it delegates to the shared `MessageKeyPolicy`.
    /// Static so tests pin it without rendering the view.
    nonisolated static func returnAction(
        isEditorField: Bool,
        enterSendsMessage: Bool,
        hasShift: Bool,
        hasCommand: Bool,
        canSubmit: Bool,
        isSubmitting: Bool
    ) -> MessageKeyPolicy.KeyAction {
        guard !isEditorField else { return .insertNewline }
        return MessageKeyPolicy.resolveReturnKey(
            enterSendsMessage: enterSendsMessage,
            hasShift: hasShift,
            hasCommand: hasCommand,
            canSubmit: canSubmit,
            isSubmitting: isSubmitting
        )
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
            // Editor-field surfaces (Autovisor Goal) put the text first and the
            // attachment/clip cards BELOW it — the goal prose is primary, its
            // references secondary. Message surfaces keep cards on top (the caption
            // is what you're about to send, so the attachments preview above it).
            if !isEditorField && hasAttachments {
                attachmentGrid
            }

            messageField

            if isEditorField && hasAttachments {
                attachmentGrid
            }

            HStack {
                Button {
                    presentOpenPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.termBase.weight(.medium))
                        .foregroundStyle(Colors.accent)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach files")

                if let clips {
                    SkillsPickerButton(projectRoot: skillsProjectRoot, clips: clips)
                }

                settingsMenu

                Spacer()

                // `⌘⏎` (or `⏎`) keyhint chip — terminal-idiom shortcut nudge
                // pulled from `QuickCapture.jsx` (`marginLeft: auto` keyhint
                // span before the dictate button). Visible only when there's
                // something submittable so it doesn't compete with the empty
                // resting state. Tracks `enterSendsMessage` so the glyph stays
                // in lockstep with the active key binding.
                if !isEditorField && effectiveCanSubmit && !isSubmitting {
                    Text(config.enterSendsMessage ? "⏎" : "⌘⏎")
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textQuaternary)
                        .padding(.trailing, Spacing.xs)
                        .accessibilityHidden(true)
                }

                ImprovePromptButton(text: $text, isImproving: $isImprovingPrompt)

                DictationMicButton(text: $text)
                    .disabled(isImprovingPrompt)

                // Editor-field mode has nothing to send — the row is a pure
                // affordance strip (attach / skills / gear / improve / dictate).
                if !isEditorField {
                    MessageSendButton(
                        canSubmit: effectiveCanSubmit,
                        isSubmitting: isSubmitting,
                        onSubmit: handleSubmit
                    )
                }
            }
        }
        .onChange(of: isImprovingPrompt) { _, improving in
            externalIsImproving?.wrappedValue = improving
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
                .font(Typography.subheadlineMedium)
                .foregroundStyle(Colors.accent)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceElevated)
                )
                .allowsHitTesting(false)
            }
        }
        .animation(Animations.quick, value: isDropTargeted)
        .onChange(of: isFocused) { _, focused in
            if focused {
                installPasteMonitor()
            } else {
                removePasteMonitor()
            }
        }
        .onDisappear {
            removePasteMonitor()
        }
    }

    // MARK: - Message Field

    /// Message field. Return-key policy delegates to `MessageKeyPolicy`;
    /// focus is bridged through `$isFocused` so the paste-monitor lifecycle
    /// above sees AppKit-driven transitions.
    private var messageField: some View {
        // `.background` and `.clipShape` are deliberately omitted — they
        // pulled SwiftUI into every CoreAnimation frame the inner scroll
        // view emitted (`.clipShape` requires an offscreen rounded-rect
        // mask pass per frame; `.background` adds another SwiftUI-managed
        // layer per frame). The field's background is transparent — the
        // parent panel's `surfacePrimary` shows through, matching the
        // intended visual. Only `.overlay` for the border survives: it's
        // a single SwiftUI layer above the representable with no clip
        // mask, no offscreen pass, and SwiftUI treats it as static
        // (doesn't re-evaluate per CA frame).
        EditableMessageTextView(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            maxHeight: maxTextFieldHeight,
            minLineCount: Self.clampMinLines(minLineCount),
            autofocusOnAppear: autofocusOnAppear,
            onReturnKey: { hasShift, hasCommand in
                let action = Self.returnAction(
                    isEditorField: isEditorField,
                    enterSendsMessage: config.enterSendsMessage,
                    hasShift: hasShift,
                    hasCommand: hasCommand,
                    canSubmit: effectiveCanSubmit,
                    isSubmitting: isSubmitting
                )
                switch action {
                case .submit:
                    handleSubmit()
                    return true
                case .insertNewline:
                    return false
                case .ignore:
                    return true
                }
            },
            isInputLocked: isImprovingPrompt
        )
        .overlay(
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(Colors.borderSubtle, lineWidth: 1)
        )
        .accessibilityLabel("Message input")
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
        let kind = ClipCellPresentation.resolve(text)

        return VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                clipTile(kind: kind)
                    .onTapGesture { popoverClipIndex = index }

                RemoveBadgeButton {
                    withAnimation(Animations.quick) {
                        guard index < (clips?.wrappedValue.count ?? 0) else { return }
                        _ = clips?.wrappedValue.remove(at: index)
                    }
                }
            }

            Text(clipLabel(kind: kind))
                .font(Typography.caption2)
                .foregroundStyle(clipLabelIsTinted(kind) ? Colors.textPrimary : Colors.textSecondary)
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

    /// Skill clips get a distinct `/`-glyph tile with a SOLID accent border;
    /// clipboard clips keep the body-preview tile with a dashed border.
    @ViewBuilder
    private func clipTile(kind: ClipCellPresentation.Kind) -> some View {
        switch kind {
        case .skill:
            Text("/")
                .font(Typography.termLg)
                .foregroundStyle(Colors.accent)
                .frame(width: 40, height: 40)
                .background(Colors.surfacePrimary)
                .overlay {
                    RoundedRectangle.squircle(CornerRadius.micro)
                        .strokeBorder(Colors.accentBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
        case .sourced(_, let body):
            clipBodyTile(text: body, border: Colors.accentBorder)
        case .plain(let body):
            clipBodyTile(text: body, border: Colors.borderSubtle)
        }
    }

    private func clipBodyTile(text: String, border: Color) -> some View {
        Text(text)
            .font(.system(size: 6, weight: .ultraLight))
            .foregroundStyle(Colors.textSecondary)
            .lineLimit(5)
            .lineSpacing(0)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Spacing.xs)
            .frame(width: 40, height: 40)
            .background(Colors.surfacePrimary)
            .overlay {
                RoundedRectangle.squircle(CornerRadius.micro)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
    }

    private func clipLabel(kind: ClipCellPresentation.Kind) -> String {
        switch kind {
        case .skill(let skill): return "/\(skill.name)"
        case .sourced(let source, _): return source
        case .plain(let body): return String(body.prefix(20))
        }
    }

    private func clipLabelIsTinted(_ kind: ClipCellPresentation.Kind) -> Bool {
        if case .plain = kind { return false }
        return true
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
                            Button {
                                // Routed through the shared seam: this composer is also
                                // hosted in the QuickCapture NSPanel, where a bare
                                // `openWindow` opens Settings BEHIND the frontmost app —
                                // measured, see `SettingsNavigation`.
                                SettingsNavigation.open(tab: .vision, using: openWindow)
                            } label: {
                                Image(systemName: "eye.trianglebadge.exclamationmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Colors.warning)
                                    .padding(Spacing.xxs)
                                    .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceCard))
                            }
                            .buttonStyle(.plain)
                            .help("Vision not configured — click to set up")
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
                .font(Typography.caption2)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52)
        }
    }

    // MARK: - Helpers

    private func handleSubmit() { dictation.flushAndThen(onSubmit) }

    private func presentOpenPanel() {
        guard let urls = FilePickerWarmup.present(), !urls.isEmpty else { return }
        stageURLs(urls)
    }

    private func stageURLs(_ urls: [URL]) {
        // Directory rejection / dedup / rejection-collection is pure (MessageComposerFileStaging);
        // only the security-scoped access + the actual stage call are the view's side effect,
        // injected via the `stage` closure. `onStageAttachment` already set `lastErrorMessage`
        // on the store for any specific failure; we aggregate one banner for the batch.
        let result = MessageComposerFileStaging.validateAndStage(
            urls: urls,
            existing: attachments,
            stage: { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return onStageAttachment(url)
            }
        )
        attachments.append(contentsOf: result.staged)
        if !result.rejected.isEmpty {
            appendImportError("Could not attach: \(result.rejected.joined(separator: ", "))")
        }
    }

    // Aggregates so a second failure doesn't silently overwrite the first.
    private func appendImportError(_ message: String) {
        importErrorMessage = MessageComposerFileStaging.aggregateErrorMessage(
            existing: importErrorMessage, new: message)
    }

    // MARK: - Paste Monitor

    /// Local NSEvent monitor is the only way to intercept Cmd+V before the
    /// TextField's field editor consumes it. Slack-style image+caption: pass
    /// the event through when the pasteboard also carries text.
    private func installPasteMonitor() {
        guard !hasRegisteredMonitor else { return }
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.modifierFlags.contains(.command),
                  event.keyCode == UInt16(kVK_ANSI_V) else { return event }
            return handlePasteEvent(event)
        }) else {
            #if DEBUG
            assertionFailure("MessageComposer: NSEvent.addLocalMonitorForEvents returned nil")
            #endif
            appendImportError("Paste interception unavailable in this context — drag-and-drop and the + button still work.")
            return
        }
        let ownerID = pasteMonitorOwnerID
        PasteMonitorRegistry.shared.register(ownerID: ownerID, remove: {
            NSEvent.removeMonitor(monitor)
        })
        hasRegisteredMonitor = true
    }

    private func removePasteMonitor() {
        guard hasRegisteredMonitor else { return }
        PasteMonitorRegistry.shared.release(ownerID: pasteMonitorOwnerID)
        hasRegisteredMonitor = false
    }

    private func handlePasteEvent(_ event: NSEvent) -> NSEvent? {
        let action = MessageComposerPasteHandler.dispatch(pasteboard: NSPasteboard.general)
        switch action {
        case .stageFiles(let urls):
            stageURLs(urls)
            return nil
        case .stageImages(let result, let alsoHasText):
            if !result.failures.isEmpty {
                appendImportError("Could not paste image: \(result.failures.joined(separator: "; "))")
            }
            guard !result.urls.isEmpty else { return event }
            stageURLs(result.urls)
            for url in result.urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    #if DEBUG
                    print("MessageComposer: paste temp cleanup failed for \(url.lastPathComponent): \(error.localizedDescription)")
                    #endif
                }
            }
            return alsoHasText ? event : nil
        case .passThrough:
            return event
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
                .font(Typography.termBase)
                .foregroundStyle(Colors.textTertiary)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                extraContent
                Toggle("Embed files in prompt", isOn: $config.embedFilesInPrompt)
                    .toggleStyle(.terminal)
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
        onSubmit: @MainActor @Sendable @escaping () -> Void,
        onStageAttachment: @escaping (URL) -> StagedAttachment?,
        onRemoveAttachment: @escaping (StagedAttachment) -> Void,
        autofocusOnAppear: Bool = false,
        minLineCount: Int = 1,
        maxTextFieldHeight: CGFloat = MessageComposerLayout.defaultMaxTextFieldHeight,
        skillsProjectRoot: URL? = nil
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
        self.minLineCount = minLineCount
        self.maxTextFieldHeight = maxTextFieldHeight
        self.skillsProjectRoot = skillsProjectRoot
        self.settingsMenu = EmbedFilesSettingsButton()
    }

    /// Editor-field convenience init: the QC bottom panel WITHOUT the send button
    /// or keyhint chip. Used by the Autovisor Goal editors — a multi-line text
    /// field where Return inserts a newline and files/skills/dictation/improve all
    /// work. Keeps the default embed-files gear so the panel matches Quick Capture;
    /// the gear's "Embed files in prompt" toggle governs whether the attachments'
    /// text is inlined vs listed as paths in the manager's prompt.
    init(
        editorText: Binding<String>,
        attachments: Binding<[StagedAttachment]>,
        clips: Binding<[String]>? = nil,
        placeholder: String = "",
        onStageAttachment: @escaping (URL) -> StagedAttachment?,
        onRemoveAttachment: @escaping (StagedAttachment) -> Void,
        isImproving: Binding<Bool>? = nil,
        autofocusOnAppear: Bool = false,
        minLineCount: Int = 3,
        maxTextFieldHeight: CGFloat = MessageComposerLayout.defaultMaxTextFieldHeight,
        skillsProjectRoot: URL? = nil
    ) {
        self._text = editorText
        self._attachments = attachments
        self.clips = clips
        self.placeholder = placeholder
        self.canSubmit = false
        self.isSubmitting = false
        self.onSubmit = {}
        self.onStageAttachment = onStageAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.autofocusOnAppear = autofocusOnAppear
        self.minLineCount = minLineCount
        self.maxTextFieldHeight = maxTextFieldHeight
        self.skillsProjectRoot = skillsProjectRoot
        self.isEditorField = true
        self.externalIsImproving = isImproving
        self.settingsMenu = EmbedFilesSettingsButton()
    }
}
