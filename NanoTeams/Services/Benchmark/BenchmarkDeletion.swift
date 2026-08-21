import Foundation

/// What a delete would actually destroy, and how to say so before doing it.
///
/// Separate from `BenchmarkLeaderboard` because it answers a third question: that enum decides
/// what is comparable, `BenchmarkSearch` decides what is being looked for, and this one decides
/// what dies. Pure and `nonisolated` — it takes the history and returns a request plus the
/// sentences describing it, so the confirmation a user reads is unit-tested rather than typed into
/// a dialog.
///
/// The whole point is that the COUNT in the request and the count in the copy come from the same
/// place. A confirmation that says "7 runs" while the delete removes 9 is worse than no
/// confirmation: it teaches the reader to trust a number that is wrong.
nonisolated enum BenchmarkDeletion {

    // MARK: - The request

    struct Request: Identifiable, Equatable, Sendable {

        enum Scope: Equatable, Sendable {
            /// Everything on disk, including lines no build here can read.
            case everything
            /// One leaderboard row: this model, on this server.
            case model(name: String, endpoint: String)
            /// One row of the Runs tab.
            case run(model: String, startedAt: Date)
        }

        let scope: Scope
        /// Exactly the runs this request removes. Empty means there is nothing to do — a caller
        /// must not raise a confirmation for it.
        let runIDs: Set<UUID>
        /// How many of `runIDs` the leaderboard never shows because they were measured with an
        /// older prompt. Named in the copy: those runs are invisible on the tab the delete was
        /// started from, and a count that includes them would otherwise look wrong.
        let olderPromptCount: Int
        /// Runs a filter is currently hiding. Only meaningful for `.everything`, where the button
        /// destroys more than the screen is showing — the one case where the visible table cannot
        /// be used to check the number.
        let hiddenByFilter: Int

        var id: String {
            switch scope {
            case .everything: "everything"
            case .model(let name, let endpoint): "model|\(endpoint)|\(name)"
            case .run(let model, let startedAt):
                "run|\(model)|\(startedAt.timeIntervalSince1970)"
            }
        }

        var isEmpty: Bool { runIDs.isEmpty }
    }

    // MARK: - Building

    /// Wipe the lot.
    ///
    /// `runIDs` is filled even though the caller clears the FILES rather than the ids: the count is
    /// what the copy states, and it must come from the same history the table drew itself from.
    static func everything(
        in runs: [GenerationBenchmarkRun],
        currentPromptVersion: Int,
        hiddenByFilter: Int = 0
    ) -> Request {
        Request(
            scope: .everything,
            runIDs: Set(runs.map(\.id)),
            olderPromptCount: runs.count { $0.promptVersion != currentPromptVersion },
            hiddenByFilter: hiddenByFilter)
    }

    /// One leaderboard row — every run sharing its model-and-server identity.
    ///
    /// Wider than the figures the row shows, deliberately: see
    /// `BenchmarkLeaderboard.runIDs(forRow:in:)`. A delete that spared the runs the row held back
    /// would leave the row on screen after the user removed it.
    static func model(
        row: BenchmarkLeaderboard.Row,
        in runs: [GenerationBenchmarkRun],
        currentPromptVersion: Int
    ) -> Request {
        let ids = BenchmarkLeaderboard.runIDs(forRow: row.id, in: runs)
        return Request(
            scope: .model(name: row.modelName, endpoint: row.baseURLString.endpointHostLabel),
            runIDs: ids,
            olderPromptCount: runs.count {
                ids.contains($0.id) && $0.promptVersion != currentPromptVersion
            },
            hiddenByFilter: 0)
    }

    /// One run of the Runs tab, and nothing else — not the model's other runs, not its row.
    static func run(_ run: GenerationBenchmarkRun, currentPromptVersion: Int) -> Request {
        Request(
            scope: .run(model: run.modelName, startedAt: run.startedAt),
            runIDs: [run.id],
            olderPromptCount: run.promptVersion == currentPromptVersion ? 0 : 1,
            hiddenByFilter: 0)
    }

    // MARK: - Copy

    static func title(for request: Request) -> String {
        switch request.scope {
        case .everything: "Delete every benchmark result?"
        case .model(let name, _): "Delete every result for \(name)?"
        case .run: "Delete this run?"
        }
    }

    /// The confirm button says the NUMBER, not just "Delete": the dialog's title names the subject,
    /// and the button is the last thing read before the history is gone.
    static func confirmLabel(for request: Request) -> String {
        let count = request.runIDs.count
        switch request.scope {
        case .everything: return count == 1 ? "Delete the run" : "Delete all \(count) runs"
        case .model: return count == 1 ? "Delete the run" : "Delete \(count) runs"
        case .run: return "Delete run"
        }
    }

    static func message(for request: Request) -> String {
        switch request.scope {
        case .everything:
            var text = "Removes \(runPhrase(request.runIDs.count)) and every sample behind "
                + "\(request.runIDs.count == 1 ? "it" : "them"), for every model and every server."
            if request.hiddenByFilter > 0 {
                text += " That includes \(request.hiddenByFilter) the filter is hiding."
            }
            return text + " " + irreversible
        case .model(let name, let endpoint):
            var text = "Removes \(runPhrase(request.runIDs.count)) of \(name) measured against "
                + "\(endpoint), and every sample behind "
                + "\(request.runIDs.count == 1 ? "it" : "them")."
            text += olderPromptClause(request)
            return text + " The same model on another server keeps its own row. " + irreversible
        case .run(let model, _):
            var text = "Removes this one run of \(model) and its samples. The model's other runs "
                + "stay, and so does its leaderboard row if they can still rank it."
            text += olderPromptClause(request)
            return text + " " + irreversible
        }
    }

    /// What to tell the user when the store could not do what the confirmation promised.
    ///
    /// `nil` on success — a delete that worked needs no sentence; the row is gone, which is the
    /// whole message. The two failure shapes get different sentences because they leave the
    /// history in different states, and only one of them is actionable.
    static func failureMessage(_ outcome: BenchmarkHistoryStore.DeleteOutcome) -> String? {
        switch outcome {
        case .removed:
            return nil
        case .nothingWritten(let reason):
            return "Nothing was deleted — the history file could not be rewritten. \(reason)"
        case .samplesLeftBehind(let rows, let reason):
            return "The runs are gone, but \(rows) sample \(rows == 1 ? "row" : "rows") could not "
                + "be removed. No table here reads them; Delete all clears the file entirely. "
                + reason
        }
    }

    /// Stated every time. The history is two JSONL files this app rewrites in place; nothing here
    /// keeps a copy, and a measurement is only recoverable by measuring again.
    static let irreversible =
        "This cannot be undone — the only way back is to run the benchmark again."

    /// Named because those runs are invisible on the leaderboard: without this the count reads as
    /// too high to anyone checking it against the rows on screen.
    private static func olderPromptClause(_ request: Request) -> String {
        guard request.olderPromptCount > 0 else { return "" }
        if request.runIDs.count == request.olderPromptCount {
            return request.olderPromptCount == 1
                ? " It was measured with an older prompt, so it appears under Runs only."
                : " All of them were measured with an older prompt, so they appear under Runs only."
        }
        return " \(request.olderPromptCount) of them were measured with an older prompt and "
            + "appear under Runs only."
    }

    private static func runPhrase(_ count: Int) -> String {
        count == 1 ? "1 run" : "\(count) runs"
    }
}
