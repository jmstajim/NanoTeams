import Foundation
import Observation

/// The Work Folder Context editor's draft for the app session — held by the app
/// (`NanoTeamsApp`), not by the Settings page, for `benchmarkSweep`'s reason: `SettingsView`
/// swaps its content on every tab switch, and closing Settings must not drop it either. Until
/// 2026-11-13 the page held it in `@State`, and the edits behind the "replaced while you were
/// editing" banner — the autosave waits for the person's choice — were gone the moment the person
/// went to another tab, to turn the agent's switch off say, with nothing to say so (review,
/// 2026-11-13).
///
/// The page reports what it shows (`show`) and forwards the person's edits and choices; the
/// draft's decisions stay in `WorkFolderContextDraftSync`. The autosave sends the revision of the
/// text the editor knows is stored (`ProjectSettings.contextRevision(of:)`), so a write it has
/// not seen — one that landed while the page was away, or between the debounce and the page's
/// next view update — refuses it, and that text is offered instead of overwritten.
@MainActor @Observable
final class WorkFolderContextEditor {
    typealias Save = @MainActor (_ text: String, _ expectedRevision: String) async
        -> NTMSOrchestrator.WorkFolderContextWrite
    typealias OpenFolder = @MainActor () -> (id: UUID, stored: String)?

    /// The shown folder's draft against its stored text.
    private(set) var sync = WorkFolderContextDraftSync(stored: "")

    @ObservationIgnored private var folderID: UUID?
    /// Drafts of folders not shown, each with something unsaved or a choice waiting, kept until
    /// their page shows again: edits left when the folder changed are never written into another.
    @ObservationIgnored private var parked: [UUID: WorkFolderContextDraftSync] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let save: Save
    @ObservationIgnored private let openFolder: OpenFolder
    @ObservationIgnored private let debounce: Duration

    init(save: @escaping Save, openFolder: @escaping OpenFolder, debounce: Duration = .milliseconds(500)) {
        self.save = save
        self.openFolder = openFolder
        self.debounce = debounce
    }

    /// The app's editor: writes through `updateWorkFolderContext` with the revision it knew.
    convenience init(store: NTMSOrchestrator) {
        self.init(
            save: { [weak store] text, revision in
                await store?.updateWorkFolderContext(text, expectedRevision: revision) ?? .noFolder
            },
            openFolder: { [weak store] in
                store?.workFolder.map { (id: $0.id, stored: $0.settings.context) }
            })
    }

    /// The autosave in flight, if any — what a caller awaits to know it has settled.
    var pendingSave: Task<Void, Never>? { saveTask }

    /// The page shows `folderID`, whose stored text is `stored`: it appeared, or the folder or its
    /// text changed. Another folder parks the shown draft and takes up its own; the same folder
    /// measures the change against what it knows is stored (`storedTextChanged`). A draft that
    /// comes back with edits still unsaved is saved.
    func show(folderID: UUID?, stored: String) {
        if folderID != self.folderID {
            saveTask?.cancel()
            if let shown = self.folderID, sync.hasUnsavedEdits || sync.replacement != nil {
                parked[shown] = sync
            }
            self.folderID = folderID
            sync = folderID.flatMap { parked.removeValue(forKey: $0) } ?? WorkFolderContextDraftSync(stored: stored)
        }
        sync.storedTextChanged(to: stored)
        if sync.textToSave != nil { scheduleSave() }
    }

    /// The person typed.
    func edit(_ text: String) {
        sync.edit(text)
        scheduleSave()
    }

    /// The person took the text that replaced theirs: it is the one stored, so nothing is saved.
    func useReplacement() {
        saveTask?.cancel()
        sync.takeReplacement()
    }

    /// The person kept their own text: saved over the replacement, against its revision.
    func keepMine() {
        sync.keepDraft()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard let folder = folderID else { return }
        saveTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.saveDraft(of: folder)
        }
    }

    /// Writes the shown draft while `folder` is the one shown and the one open — the same text
    /// in another folder would pass the revision — and records what came of it.
    private func saveDraft(of folder: UUID) async {
        guard folderID == folder, openFolder()?.id == folder, let text = sync.textToSave else { return }
        let outcome = await save(text, ProjectSettings.contextRevision(of: sync.stored))
        guard folderID == folder else { return }
        switch outcome {
        case .written:
            sync.saved(text)
        case .changedSinceRead:
            // Another writer got there first: its text is offered, as the page offers one it sees.
            if let now = openFolder(), now.id == folder { sync.storedTextChanged(to: now.stored) }
        case .noFolder, .failed:
            break
        }
    }
}
