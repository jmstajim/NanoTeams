import Foundation

/// Append-only history of benchmark runs, in two JSONL files.
///
/// **Why JSONL.** The shape `NetworkLogger` carried until 2026-08-21 decoded the whole array,
/// appended, and re-encoded it on every write — O(n²) — and its `try? decode ?? []` silently
/// truncated the entire file when one byte went wrong. Fatal for a history that must accumulate
/// for months: here one corrupt line costs one row. (That logger has since been converted too —
/// all three now append through `JSONLFileLog`, the single home of the `seekToEnd` body this
/// store originally copied from `ToolCallLogger`.)
///
/// **Why two files.** `results.jsonl` is a row per sample; `provenance.jsonl` is a row per run.
/// Provenance is what makes a row from six months ago interpretable, and repeating it on every
/// sample would multiply the file for no new fact. Same split as
/// `benchmark_prompt_processing.sh`, and the same on-disk format — so its output and this app's
/// are mutually readable.
///
/// **Why Application Support and not the work folder.** Generation speed is a fact about the
/// machine and the model; it has nothing to do with which folder is open, and it must survive
/// switching folders.
nonisolated final class BenchmarkHistoryStore: @unchecked Sendable {

    /// `~/Library/Application Support/NanoTeams/benchmarks/`.
    ///
    /// Deliberately BESIDE `.nanoteams/`, not inside it: `~/Library/Application Support/NanoTeams/`
    /// is itself the default WORK FOLDER (`NTMSOrchestrator.defaultStorageURL`) and carries a full
    /// `.nanoteams/internal/` tree. Filing benchmark history under that tree would tie a
    /// machine-scoped fact to one work folder — the exact coupling this store exists to avoid —
    /// and would put it behind `NTMSPaths`, which is rooted in a work folder and has no opinion
    /// about app-level data.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoTeams", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
    }

    let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.nanoteams.benchmarkhistory")

    var samplesURL: URL { directory.appendingPathComponent("results.jsonl", isDirectory: false) }
    var runsURL: URL { directory.appendingPathComponent("provenance.jsonl", isDirectory: false) }

    init(directory: URL = BenchmarkHistoryStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONCoderFactory.makeJSONLEncoder()
        self.decoder = JSONCoderFactory.makeDateDecoder()
    }

    // MARK: - Append

    func append(run: GenerationBenchmarkRun) {
        queue.sync { appendLine(for: run, to: runsURL) }
    }

    func append(samples: [GenerationBenchmarkSample]) {
        guard !samples.isEmpty else { return }
        queue.sync {
            for sample in samples { appendLine(for: sample, to: samplesURL) }
        }
    }

    // MARK: - Load

    /// Rows in file order (oldest first). A line that fails to decode is skipped and costs only
    /// itself — never the file.
    func loadRuns() -> [GenerationBenchmarkRun] {
        queue.sync { decodeLines(at: runsURL) }
    }

    func loadSamples() -> [GenerationBenchmarkSample] {
        queue.sync { decodeLines(at: samplesURL) }
    }

    // MARK: - Prune

    /// Keeps the newest `limit` runs and the samples belonging to them.
    ///
    /// Rewrites through a temp file plus `replaceItemAt`, NOT through the append handle: a
    /// truncate-and-rewrite in place leaves the history empty if the process dies mid-write, and
    /// the whole point of this file is that it survives.
    func prune(limit: Int = BenchmarkMetricsPolicy.historyRowLimit) {
        queue.sync {
            let runs = decodeLines(at: runsURL) as [GenerationBenchmarkRun]
            guard runs.count > limit else { return }
            let keep = runs.sorted { $0.startedAt < $1.startedAt }.suffix(limit)
            let keepIDs = Set(keep.map(\.id))
            let samples = (decodeLines(at: samplesURL) as [GenerationBenchmarkSample])
                .filter { keepIDs.contains($0.runID) }
            atomicRewrite(Array(keep), to: runsURL)
            atomicRewrite(samples, to: samplesURL)
        }
    }

    // MARK: - Delete

    /// What a delete did, in the only three shapes a caller renders differently.
    ///
    /// Not `Void`. Appending is best-effort by design — a measurement must never fail because its
    /// record could not be written — but a DELETE is the user's own instruction, confirmed against
    /// a sentence promising a count. A write that failed silently there leaves the rows on screen
    /// and the user clicking again forever.
    nonisolated enum DeleteOutcome: Equatable, Sendable {
        /// Everything asked for is gone. Also the answer when nothing matched: both leave the
        /// history in the state the caller asked for.
        case removed
        /// The runs file could not be rewritten, so nothing was — the samples pass never ran.
        case nothingWritten(reason: String)
        /// The runs are gone; `rows` sample lines are not. Still CONSISTENT rather than corrupt:
        /// every reader joins from runs to samples, so those rows are invisible, not wrong.
        case samplesLeftBehind(rows: Int, reason: String)
    }

    /// Removes the named runs and every sample belonging to them.
    ///
    /// Both files are rewritten inside ONE queue hop, so no reader can catch the history
    /// half-deleted — a run whose samples are already gone would summarise as a failure and read
    /// as a measurement that went wrong rather than as one the user removed.
    ///
    /// Unlike `prune`, this filters LINES rather than decoded rows: a line this build cannot
    /// decode is a line it cannot identify either, so it is kept. Deleting one model's runs must
    /// not silently purge a corrupt neighbour — the whole reason this file is JSONL is that one
    /// bad line costs one row.
    ///
    /// A file nothing matched is not rewritten at all, so an unrelated delete never touches its
    /// mtime and never risks its contents.
    /// Runs are rewritten FIRST, and the samples pass does not run if that failed. The order
    /// decides which torn state a failure can leave, and only one of the two is survivable: every
    /// reader joins runs → samples, so a sample whose run is gone is invisible, while a run whose
    /// samples are gone still renders — as a measurement that produced nothing, which is a lie
    /// about a run the user asked to remove.
    @discardableResult
    func delete(runIDs: Set<UUID>) -> DeleteOutcome {
        guard !runIDs.isEmpty else { return .removed }
        return queue.sync {
            let runs = removeLines(at: runsURL) { (run: GenerationBenchmarkRun) in
                runIDs.contains(run.id)
            }
            if let reason = runs.failure { return .nothingWritten(reason: reason) }

            let samples = removeLines(at: samplesURL) { (sample: GenerationBenchmarkSample) in
                runIDs.contains(sample.runID)
            }
            if let reason = samples.failure {
                return .samplesLeftBehind(rows: samples.matched, reason: reason)
            }
            return .removed
        }
    }

    /// Removes the entire history — both files, corrupt lines and all.
    ///
    /// Deletes rather than truncates: an absent file is the state a fresh install is in, and it is
    /// the one state every path here already handles (`loadRuns` returns `[]`, `append` recreates).
    /// Leaving two empty files behind would invent a fourth state nothing else in this type knows.
    /// The directory stays: it carries owner-only permissions this app set, and re-creating it is
    /// the one part of the layout that can fail.
    @discardableResult
    func clear() -> DeleteOutcome {
        queue.sync {
            // Same order and the same reason as `delete`: runs first, so a failure between the two
            // leaves samples nothing joins to rather than runs that render as empty measurements.
            do {
                if fileManager.fileExists(atPath: runsURL.path) {
                    try fileManager.removeItem(at: runsURL)
                }
            } catch {
                return .nothingWritten(reason: error.localizedDescription)
            }
            do {
                if fileManager.fileExists(atPath: samplesURL.path) {
                    try fileManager.removeItem(at: samplesURL)
                }
            } catch {
                return .samplesLeftBehind(
                    rows: lineCount(at: samplesURL), reason: error.localizedDescription)
            }
            return .removed
        }
    }

    // MARK: - Internals


    private func appendLine<T: Encodable>(for value: T, to url: URL) {
        // Best-effort, and shared: the body this store's doc admits copying from
        // `ToolCallLogger` now has ONE home (`JSONLFileLog`), which also owns the
        // per-file serialization.
        JSONLFileLog.append(
            value, to: url, encoder: encoder, fileManager: fileManager,
            directoryAttributes: NTMSRepository.internalDirAttributes)
    }

    private func decodeLines<T: Decodable>(at url: URL) -> [T] {
        JSONLFileLog.decodeLines(T.self, from: url, decoder: decoder, fileManager: fileManager)
    }

    private func atomicRewrite<T: Encodable>(_ values: [T], to url: URL) {
        do {
            var body = Data()
            for value in values {
                body.append(try encoder.encode(value))
                body.append(0x0A)
            }
            try atomicWrite(body, to: url)
        } catch {
            #if DEBUG
            print("[BenchmarkHistoryStore] rewrite failed: \(error)")
            #endif
        }
    }

    /// Drops the lines whose decoded value matches, keeping every line that does NOT decode.
    ///
    /// The undecodable branch is the point: `decodeLines` (and therefore `prune`) treats a line it
    /// cannot read as absent, which is right for an eviction policy ranked by date and wrong for a
    /// delete by identity — a row this build cannot parse is not the row the user asked to remove.
    /// How one file's pass went: how many lines matched, and why the rewrite failed if it did.
    private struct LinePass {
        var matched = 0
        var failure: String?
    }

    private func removeLines<T: Decodable>(
        at url: URL, matching shouldRemove: (T) -> Bool
    ) -> LinePass {
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return LinePass() }

        var kept: [Substring] = []
        var pass = LinePass()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let value = try? decoder.decode(T.self, from: Data(line.utf8)) else {
                kept.append(line)
                continue
            }
            if shouldRemove(value) { pass.matched += 1 } else { kept.append(line) }
        }
        guard pass.matched > 0 else { return pass }

        var body = Data()
        for line in kept {
            body.append(Data(line.utf8))
            body.append(0x0A)
        }
        do {
            try atomicWrite(body, to: url)
        } catch {
            pass.failure = error.localizedDescription
        }
        return pass
    }

    /// Lines currently in a file, for a failure message that has to say how many rows were left.
    private func lineCount(at url: URL) -> Int {
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Temp file plus `replaceItemAt`, never a truncate-in-place: a process that dies mid-write
    /// must leave the previous history intact, not an empty file.
    ///
    /// No directory bootstrap here: `JSONLFileLog.append` owns directory creation,
    /// and every rewrite path (`prune`, `delete`) early-returns unless rows exist —
    /// rows imply an append happened, which implies the directory does.
    private func atomicWrite(_ body: Data, to url: URL) throws {
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try body.write(to: temp, options: [.atomic])
        do {
            _ = try fileManager.replaceItemAt(
                url, withItemAt: temp, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            // `replaceItemAt` refuses a target it cannot write; fall back the same way
            // `AtomicJSONStore` does rather than leaving an orphan temp behind.
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    nonisolated deinit {}
}
