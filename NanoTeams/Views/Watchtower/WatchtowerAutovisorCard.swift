import SwiftUI

/// Watchtower card for the Autovisor: an editable goal, editable live memory, and a
/// Quick Capture message composer (under a "Autovisor" section header). Renders only
/// while the manager is enabled — the on/off control is the Quick Actions row and the
/// "Open chat" entry is the sidebar nav item, so neither lives here. Self-gating +
/// its own subview so its snapshot reads (which churn while the manager is
/// "Reviewing…") re-render only this card, never the whole Watchtower body — see
/// CLAUDE.md #11.
struct WatchtowerAutovisorCard: View {
    @Environment(NTMSOrchestrator.self) private var store

    @State private var messageDraft = ""
    @State private var attachments: [StagedAttachment] = []
    @State private var composerDraftID = UUID()
    @State private var goalDraft = ""
    @State private var goalSaveTask: Task<Void, Never>?
    @State private var memoryDraft = ""
    @State private var memorySaveTask: Task<Void, Never>?

    private var isEnabled: Bool { store.workFolder?.settings.autovisorEnabled ?? false }

    private var canSubmit: Bool {
        !messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        if store.hasRealWorkFolder && isEnabled {
            VStack(alignment: .leading, spacing: Spacing.m) {
                MonoLabel(text: "Autovisor", rule: true)
                card
            }
            .onAppear(perform: seed)
            // The user edits goal here; nothing else writes it — but if it's
            // changed elsewhere (Settings), keep this editor in sync.
            .onChange(of: store.workFolder?.settings.autovisorGoal) { _, new in
                if let new, new != goalDraft { goalDraft = new }
            }
            // Memory is also written by the manager (update_scratchpad) and from
            // Settings; re-seed the editor when the persisted value diverges from the
            // draft. The `new != memoryDraft` guard breaks the commit→seed loop — it
            // does NOT detect an in-progress edit, so a manager write can still replace
            // an unsaved draft (same live-sync tradeoff Settings accepts).
            .onChange(of: store.workFolder?.settings.autovisorMemory) { _, new in
                if let new, new != memoryDraft { memoryDraft = new }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            goalSection
            memorySection
            composer
        }
        .padding(Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.surfaceCard)
        )
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            MonoLabel(text: "Goal", size: .xs)
            // Capped like MEMORY so a long goal scrolls internally instead of
            // ballooning the card inside the Watchtower ScrollView.
            TextEditor(text: $goalDraft)
                .font(Typography.termBase)
                .borderedTextEditorStyle(minHeight: 60)
                .frame(maxHeight: 180)
                .onChange(of: goalDraft) { _, newValue in commitGoal(newValue) }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            MonoLabel(text: "Memory", size: .xs)
            // Capped height so a long standing memory scrolls internally instead of
            // ballooning the card inside the Watchtower ScrollView.
            TextEditor(text: $memoryDraft)
                .font(Typography.termBase)
                .borderedTextEditorStyle(minHeight: 100)
                .frame(maxHeight: 180)
                .onChange(of: memoryDraft) { _, newValue in commitMemory(newValue) }
        }
    }

    private var composer: some View {
        MessageComposer(
            text: $messageDraft,
            attachments: $attachments,
            placeholder: "Message Autovisor…",
            canSubmit: canSubmit,
            isSubmitting: false,
            onSubmit: { send() },
            onStageAttachment: { url in store.stageAttachment(url: url, draftID: composerDraftID) },
            onRemoveAttachment: { attachment in store.removeStagedAttachment(attachment) }
        )
    }

    private func seed() {
        goalDraft = store.workFolder?.settings.autovisorGoal ?? ""
        memoryDraft = store.workFolder?.settings.autovisorMemory ?? ""
    }

    /// Debounced write-through to `settings.autovisorGoal` (mirrors the editor
    /// in AutovisorSettingsView). The change-guard prevents a commit→seed loop.
    private func commitGoal(_ newValue: String) {
        goalSaveTask?.cancel()
        goalSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if store.workFolder?.settings.autovisorGoal != newValue {
                await store.updateAutovisorGoal(newValue)
            }
        }
    }

    /// Debounced write-through to `settings.autovisorMemory`. The manager writes
    /// here too via `update_scratchpad`; both funnel through `updateAutovisorMemory`.
    private func commitMemory(_ newValue: String) {
        memorySaveTask?.cancel()
        memorySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if store.workFolder?.settings.autovisorMemory != newValue {
                await store.updateAutovisorMemory(newValue)
            }
        }
    }

    private func send() {
        // Clear + confirm ONLY when the message was actually queued (e.g. the manager
        // task must exist) — otherwise leave the draft + staged files intact. Gating
        // logic lives in the pure, unit-tested `AutovisorComposerSend`.
        let outcome = AutovisorComposerSend.evaluate(
            text: messageDraft,
            hasAttachments: !attachments.isEmpty,
            queue: { trimmed in store.sendMessageToAutovisor(trimmed, attachments: attachments) }
        )
        guard outcome == .cleared else { return }
        messageDraft = ""
        attachments = []
        composerDraftID = UUID()   // fresh staging dir for the next message
        // "queued", not "delivered": the manager drains the queue on its next
        // iteration (matches TeamActivityComposer's wording for the same mechanism).
        store.lastInfoMessage = "Message queued for Autovisor."
    }
}
