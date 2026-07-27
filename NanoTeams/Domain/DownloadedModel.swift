import Foundation

/// One model download occupying disk space on the host that serves a given
/// LLM endpoint. Produced by `DownloadedModelStore.listDownloaded`.
///
/// Deliberately NOT the same thing as an entry in the model picker: the picker
/// lists what the server will *serve*, this lists what the server has *stored*.
/// They differ in ways that matter for deletion — an LM Studio GGUF folder can
/// hold several quantizations that the picker shows as separate models but that
/// share (and are deleted with) one directory.
nonisolated struct DownloadedModel: Identifiable, Sendable, Hashable {

    /// Stable identity for `ForEach` AND the argument `delete` resolves.
    /// Provider-specific by design:
    /// - Ollama: the `name:tag` its API deletes by.
    /// - LM Studio: the `<publisher>/<repoDir>` path relative to the models root.
    let id: String

    /// What the user reads in the row.
    let displayName: String

    /// Bytes on disk. `nil` = the provider didn't report a size and we couldn't
    /// measure one — render the row without a size rather than claiming zero.
    let sizeBytes: Int64?

    /// Optional second line: quantization, format, "2 quantizations", …
    let detail: String?

    /// Whether this model is resident in memory right now. Best-effort: a
    /// failed probe reports `false` only in the sense of "no badge", never as a
    /// positive claim that the model is unloaded.
    let isLoaded: Bool

    /// Candidate model identifiers this download could be referenced by in
    /// settings or team roles.
    ///
    /// Used ONLY to decorate the confirmation dialog and to decide whether to
    /// unload before deleting. It is never used to resolve the delete target —
    /// that is always `id`, which is exact. So a hint that over- or
    /// under-matches costs at most a spurious or missing warning, never a
    /// wrong deletion.
    let referenceHints: [String]

    init(
        id: String,
        displayName: String,
        sizeBytes: Int64? = nil,
        detail: String? = nil,
        isLoaded: Bool = false,
        referenceHints: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.detail = detail
        self.isLoaded = isLoaded
        self.referenceHints = referenceHints.isEmpty ? [id] : referenceHints
    }
}

/// What deleting means at a given endpoint.
///
/// One value drives both the button's enablement and the confirmation copy, so
/// the view needs no per-provider branching — the asymmetry between "the server
/// erases it" and "we move files to the Trash" is a fact about the provider and
/// belongs with the provider, not in the UI.
nonisolated enum DownloadedModelDeletion: Sendable, Equatable {

    /// Server-side and irreversible (Ollama `DELETE /api/delete`).
    case permanent

    /// The model's files are moved to the macOS Trash. Reversible, but the disk
    /// space is only reclaimed once the Trash is emptied — the UI must say so.
    case movesToTrash

    /// Deletion isn't possible from here. `reason` is shown to the user verbatim.
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Sentence appended to the confirmation dialog explaining what will happen.
    var confirmationDetail: String? {
        switch self {
        case .permanent:
            "This permanently deletes it from the server. You can download it again later."
        case .movesToTrash:
            "This moves its files to the Trash. Empty the Trash to reclaim the space."
        case .unavailable:
            nil
        }
    }
}
