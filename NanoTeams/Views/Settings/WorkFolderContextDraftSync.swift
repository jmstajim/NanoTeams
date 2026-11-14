import Foundation

/// The Work Folder Context editor's draft against the stored text: what the Settings page does
/// when either side moves, kept out of the view so each decision is tested
/// (`WorkFolderContextDraftSyncTests`).
///
/// Two kinds of writer share the text: the person, through the page's debounced autosave, and
/// everything else — Generate, the built-in Autovisor, an external agent the person allowed to.
/// Until 2026-11-13 the page adopted every outside write into the draft at once: one landing while
/// the person typed replaced their text under the caret and cancelled the save of what they had
/// typed since the last one. It also told its own save from another writer's by comparing the
/// change with the last text it had saved, for good, so an outside write equal to that text was
/// taken for an echo and ignored, and the draft stayed apart from the stored text with the saving
/// indicator on.
///
/// The page no longer recognises its own save when it comes back: it records it when the write
/// returns (`saved`). The write is in the store by then, and the page sees the change only on a
/// later view update, so the change is no news. Whatever else changes the text is another
/// writer's, measured against what the page knows is stored.
nonisolated struct WorkFolderContextDraftSync: Equatable {
    /// What the editor shows and the person edits.
    private(set) var draft: String
    /// The stored text as the page last knew it: loaded, saved by the page, or seen changing.
    private(set) var stored: String
    /// A text another writer stored while the draft held unsaved edits. Offered, never adopted
    /// silently, and the autosave waits until the person chooses.
    private(set) var replacement: String?

    init(stored: String) {
        draft = stored
        self.stored = stored
    }

    /// Whether the draft holds edits the stored text does not. Compared as the writer stores
    /// text — trimmed — so a trailing space not yet followed by more is no edit to save.
    var hasUnsavedEdits: Bool {
        Self.trimmed(draft) != Self.trimmed(stored)
    }

    /// What the autosave writes when its debounce fires — trimmed, as the writer stores it — or
    /// `nil` when there is nothing to save or a replacement waits for the person's choice.
    var textToSave: String? {
        guard replacement == nil, hasUnsavedEdits else { return nil }
        return Self.trimmed(draft)
    }

    /// The person typed.
    mutating func edit(_ text: String) {
        draft = text
    }

    /// The page's own write stored `text` (`updateWorkFolderContext` returned `.written`). The
    /// draft is left as it is — what was typed while the write ran, and the whitespace the writer
    /// trimmed, stay under the caret.
    mutating func saved(_ text: String) {
        stored = text
    }

    /// The page saw the stored text change. Equal to what it knows is stored, the change is its
    /// own save, or none at all; otherwise another writer stored `text`.
    mutating func storedTextChanged(to text: String) {
        guard text != stored else { return }
        // Asked against the text stored BEFORE this change: the edits are unsaved relative to it.
        defer { stored = text }
        if Self.trimmed(text) == Self.trimmed(draft) {
            // The store now holds what the editor holds: nothing is unsaved, so nothing is offered.
            replacement = nil
        } else if hasUnsavedEdits {
            replacement = text
        } else {
            draft = text
        }
    }

    /// The person took the text that replaced theirs.
    mutating func takeReplacement() {
        guard let replacement else { return }
        draft = replacement
        self.replacement = nil
    }

    /// The person kept their own text: the next save writes it over the replacement.
    mutating func keepDraft() {
        replacement = nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
