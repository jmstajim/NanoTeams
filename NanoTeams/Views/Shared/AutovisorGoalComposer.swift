import SwiftUI

/// The Autovisor **Goal** editor field, shared by all three goal surfaces
/// (first-time Setup pane, Settings → Autovisor, Watchtower card). Wraps the
/// unified `MessageComposer` in editor mode — the Quick Capture bottom panel
/// (`+` attach / `/` skills / gear / … / ✨ improve / 🎤 dictate) **without** a
/// send button; Return inserts a newline.
///
/// Ownership split:
/// - **Goal text** (`text`) is host-owned — Setup persists it on Enable, while
///   Settings/Watchtower keep their own debounced autosave. This view never
///   writes the goal string.
/// - **Attachments + skill/clip cards** are owned HERE and persisted immediately
///   (uniform across all three surfaces) into the folder-level goal store via
///   the orchestrator. On every change the manager's brief is re-mirrored.
///
/// Attachments reach the manager through `syncAutovisorGoalToManagerBrief`:
/// their paths are listed in the `## Supervisor Goal` prompt (or their text is
/// inlined when the gear's "Embed files in prompt" toggle is on), and the
/// manager reads them with its file tools.
///
/// The capability warning that used to hang under this editor now lives beside
/// each host's **Goal** label as `AutovisorGoalLintTip`.
///
/// Hosts must not wrap this view in a `.background`/`.overlay` ViewBuilder
/// closure containing focusable or responder-participating content: the editor
/// is `NSScrollView`-backed, and such content anywhere in its ancestor chain
/// re-enters SwiftUI's display list on every CoreAnimation frame the scroll view
/// emits (CLAUDE.md #50).
struct AutovisorGoalComposer: View {
    @Environment(NTMSOrchestrator.self) private var store

    @Binding var text: String
    /// Optional host mirror of the improve-stream state — the Setup pane uses it
    /// to lock its Enable button + suspend goal autosave while a rewrite streams.
    var isImproving: Binding<Bool>? = nil
    var autofocus: Bool = false
    var placeholder: String = "Describe the Autovisor's goal…"
    var maxTextFieldHeight: CGFloat = MessageComposerLayout.defaultMaxTextFieldHeight

    @State private var attachments: [StagedAttachment] = []
    @State private var clips: [Clip] = []

    var body: some View {
        MessageComposer(
            editorText: $text,
            attachments: $attachments,
            clips: $clips,
            placeholder: placeholder,
            onStageAttachment: { store.stageAutovisorGoalAttachment(url: $0) },
            onRemoveAttachment: { store.removeAutovisorGoalFile($0) },
            isImproving: isImproving,
            autofocusOnAppear: autofocus,
            minLineCount: 3,
            maxTextFieldHeight: maxTextFieldHeight,
            skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
        )
        .onAppear { seed() }
        // Persist only real changes — the seed assignment matches what's already
        // persisted, so the equality guard keeps it from churning the store /
        // re-mirroring on every appear.
        .onChange(of: attachments) { _, new in
            let paths = new.map(\.stagedRelativePath)
            guard paths != store.workFolder?.settings.autovisorGoalAttachmentPaths else { return }
            Task { await store.setAutovisorGoalAttachmentPaths(paths) }
        }
        .onChange(of: clips) { _, new in
            guard new.texts != store.workFolder?.settings.autovisorGoalClips else { return }
            Task { await store.setAutovisorGoalClips(new.texts) }
        }
    }

    /// Seeds the cards from persisted settings. Idempotent: because every change
    /// is persisted immediately, local state always matches settings, so a re-seed
    /// on re-appear is a no-op.
    private func seed() {
        attachments = store.autovisorGoalAttachments
        clips = [Clip].minting(store.workFolder?.settings.autovisorGoalClips ?? [])
    }
}
