import Dispatch
import Foundation

/// Scanning several candidate files at once, while the OUTPUT stays byte-identical to the
/// sequential walk this replaced.
///
/// Measured on this work folder (18 logical cores): the walk without reading is 0.20 s, the same
/// walk with a per-file grep is 8.69 s. ~98% of a search is read-plus-scan, which is the part
/// that parallelises; a 12-way `xargs` run of the same greps takes 3.00 s.
///
/// **Why a sliding window, not batches.** Files are pulled one at a time to keep exactly
/// `concurrency` scans in flight, and each result is merged the moment every earlier candidate
/// has been. The obvious alternative — take N candidates, scan them, merge, repeat — pays a
/// barrier per batch, and worse, it speculates N-1 files deep on a search whose budget fills in
/// the first one. Here the read-ahead is bounded by the window: at most `concurrency - 1`
/// candidates are ever scanned and thrown away, and `Stats.speculativeScansDiscarded` says so
/// out loud rather than leaving "faster because it read ten times as much" invisible.
///
/// **Why the executor preference.** `withTaskExecutorPreference` puts the child scans on a
/// dispatch pool, which OVERCOMMITS when a thread blocks — and every scan blocks on `read(2)`.
/// Left on the cooperative pool, `concurrency` blocking readers would occupy a pool sized to the
/// core count, stalling every other task in the process behind file I/O. That is the reason the
/// three earlier drafts of this reached for `DispatchQueue.concurrentPerform` instead; that
/// primitive would also have given up compiler-checked `Sendable` capture and inherited
/// cancellation, and this gives up neither.
nonisolated enum BlockingIOTaskExecutor {

    /// A `TaskExecutor` backed by a concurrent dispatch queue.
    ///
    /// Apple ships `extension DispatchQueue: TaskExecutor`, and using it directly is what this
    /// started as — but the CONFORMANCE is `@available(macOS 15.4)` while the protocol is 15.0,
    /// and this project deploys to 15.0. The choice was between an `#available` fork whose old
    /// arm nothing would ever run, and the fifteen lines the conformance itself is; the fork
    /// loses, because an untested branch that only appears on a minority OS is worse than no
    /// branch. `runSynchronously(on:)` is the whole implementation, exactly as SE-0417 spells it.
    nonisolated final class Queue: TaskExecutor {
        private let queue: DispatchQueue

        init(label: String, qos: DispatchQoS) {
            queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
            queue.setSpecific(key: BlockingIOTaskExecutor.poolMarker, value: true)
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { [self] in job.runSynchronously(on: asUnownedTaskExecutor()) }
        }
    }

    /// One process-wide pool. Per-run instances would each spin up their own threads, and three
    /// sources can be searching at once (a role's tool batch, a meeting turn, the Autovisor).
    static let shared = Queue(label: "com.nanoteams.search.scan", qos: .userInitiated)

    /// Marks threads currently servicing the scan pool.
    ///
    /// Exists because the executor preference is otherwise INVISIBLE: without it every scan
    /// still returns the right answer, it just does its blocking `read(2)` calls on the
    /// cooperative pool, whose width is the core count and which the rest of the process's async
    /// work shares. A property that costs nothing when broken needs something that can see it —
    /// and thread NAMES are not it, since dispatch promises nothing about them.
    static let poolMarker = DispatchSpecificKey<Bool>()

    /// Whether the calling thread is currently servicing the scan pool.
    static func isOnScanPool() -> Bool { DispatchQueue.getSpecific(key: poolMarker) == true }
}

nonisolated extension SearchExecutor {

    /// What the parallel drive produced besides the mutated `results`.
    struct ParallelScanOutcome {
        /// The roster, TRUNCATED to the point the sequential walk would have stopped at.
        let visitedPaths: [String]
    }

    /// Extensions that must not be scanned concurrently.
    ///
    /// `DocumentTextExtractor` routes `.rtf`/`.rtfd`/`.doc` through
    /// `NSAttributedString(url:options:documentAttributes:)`, and that file's own doc comment
    /// records the hazard: `.documentType` is a HINT, not an assertion, so a `.rtf` holding HTML
    /// silently starts AppKit's HTML importer, which is main-thread-only and, off-main,
    /// synchronises with the main thread and times out. Running these one at a time is not a
    /// regression — off-main is already where they run today, inside the tool batch's
    /// `Task.detached`; only the CONCURRENCY would be new.
    ///
    /// Sourced from `DocumentConstants.supportedReadExtensions` rather than a hand-listed subset:
    /// `scanFile` decides "document or raw UTF-8" from exactly that set, so a narrower list here
    /// would send a newly-supported format down the parallel lane the day it was added.
    static let sequentialLaneExtensions: Set<String> = DocumentConstants.supportedReadExtensions

    /// Whether this candidate belongs on the sequential lane. One home for the predicate, asked
    /// twice per candidate — once when deciding whether to dispatch it, once when the merge
    /// reaches it — and the two must never disagree, or a document would be both dispatched and
    /// re-scanned inline.
    static func requiresSequentialScan(_ url: URL) -> Bool {
        sequentialLaneExtensions.contains(url.pathExtension.lowercased())
    }

    /// Scans one candidate in isolation — against EMPTY buckets and a zero total.
    ///
    /// That isolation is the whole reason `SearchScanResults.canAdopt` exists: the result is only
    /// the sequential answer while neither shared limit would have bitten mid-file.
    static func scanCandidate(
        at url: URL, relativePath: String, plan: SearchScanPlan, queryCount: Int
    ) -> SearchScanResults {
        var isolated = SearchScanResults(queryCount: queryCount)
        scanFile(at: url, relativePath: relativePath, plan: plan, into: &isolated)
        return isolated
    }

    /// Drives the walk and the scan together, merging every side effect at its walk position.
    ///
    /// A width of one is NOT this pipeline with a window of one — it is the sequential walk, and
    /// that distinction is load-bearing rather than an optimisation. Even at a window of one,
    /// this pipeline scans each candidate against EMPTY buckets and reconciles afterwards, so a
    /// defect in `canAdopt` produces the same wrong answer at every width. Measured: with
    /// `canAdopt` stubbed to `true`, a width-1-versus-width-8 comparison stayed green — both
    /// sides were wrong in the same way. The sequential path below has no isolation and no
    /// reconciliation, which is what makes it usable as the reference the other is compared to.
    static func runScan(
        walker: inout SearchDirectoryWalker,
        plan: SearchScanPlan,
        queryCount: Int,
        concurrency: Int,
        into results: inout SearchScanResults
    ) async -> ParallelScanOutcome {
        guard concurrency > 1 else {
            return runSequentialScan(walker: &walker, plan: plan, into: &results)
        }
        return await runParallelScan(
            walker: &walker, plan: plan, queryCount: queryCount,
            concurrency: concurrency, into: &results)
    }

    /// The walk and the scan interleaved in one pass, sharing one accumulator — what
    /// `SearchExecutor.run` did before any of this, expressed against the extracted walker.
    static func runSequentialScan(
        walker: inout SearchDirectoryWalker,
        plan: SearchScanPlan,
        into results: inout SearchScanResults
    ) -> ParallelScanOutcome {
        var stopStep: SearchDirectoryWalker.Step?
        while let step = walker.next() {
            switch step.event {
            case .skip(let entry):
                results.skipped.append(entry)
            case .candidate(let url, let relativePath):
                scanFile(at: url, relativePath: relativePath, plan: plan, into: &results)
            }
            if results.budgetExhausted(plan) { stopStep = step; break }
        }
        return finish(walker: walker, stopStep: stopStep, dispatched: 0, adopted: 0,
                      into: &results)
    }

    private static func runParallelScan(
        walker: inout SearchDirectoryWalker,
        plan: SearchScanPlan,
        queryCount: Int,
        concurrency: Int,
        into results: inout SearchScanResults
    ) async -> ParallelScanOutcome {
        // Every step the walk has produced, in order. The merge replays this list; a step is
        // never acted on out of position, which is what keeps `skipped` interleaved correctly.
        var steps: [SearchDirectoryWalker.Step] = []
        var mergeCursor = 0
        // Scan results that arrived before their turn, keyed by step index.
        var arrived: [Int: SearchScanResults] = [:]
        var dispatched = 0
        var harvested = 0
        /// Parallel-lane candidates the merge has decided about — adopted, or rejected and
        /// re-scanned. This is what the window is measured against, NOT the in-flight count: a
        /// result that has arrived but is waiting its turn has already cost its read, so pacing
        /// on `dispatched - harvested` lets the read-ahead grow without bound whenever the merge
        /// stalls on one slow file. Measured before the fix: a 5-result page over 300 files
        /// discarded 9 scans at width 8.
        var settled = 0
        var adoptedFromParallel = 0
        var walkerExhausted = false
        var stopped = false
        // The step whose merge filled the budget — the rollback anchor. `nil` means the walk ran
        // to completion, in which case the walker's own counters are already the right answer.
        var stopStep: SearchDirectoryWalker.Step?

        await withTaskExecutorPreference(BlockingIOTaskExecutor.shared) {
            await withTaskGroup(of: (Int, SearchScanResults).self) { group in

                /// Pulls walk steps until the window is full. Only non-document candidates get a
                /// task; documents are scanned in the merge loop, in order, one at a time.
                func fillWindow() {
                    while !walkerExhausted, dispatched - settled < concurrency {
                        guard let step = walker.next() else { walkerExhausted = true; return }
                        let index = steps.count
                        steps.append(step)
                        guard case .candidate(let url, let relativePath) = step.event,
                              !requiresSequentialScan(url)
                        else { continue }
                        dispatched += 1
                        group.addTask {
                            (index, scanCandidate(
                                at: url, relativePath: relativePath,
                                plan: plan, queryCount: queryCount))
                        }
                    }
                }

                /// Merges every step whose result is already in hand, in walk order. Returns once
                /// it needs a scan that has not arrived, or once the budget is full.
                func mergeReady() {
                    while mergeCursor < steps.count {
                        let step = steps[mergeCursor]
                        switch step.event {
                        case .skip(let entry):
                            results.skipped.append(entry)
                        case .candidate(let url, let relativePath):
                            if requiresSequentialScan(url) {
                                scanFile(
                                    at: url, relativePath: relativePath,
                                    plan: plan, into: &results)
                            } else if let candidate = arrived.removeValue(forKey: mergeCursor) {
                                settled += 1
                                if results.canAdopt(candidate, plan: plan) {
                                    results.adopt(candidate)
                                    adoptedFromParallel += 1
                                } else {
                                    // The isolated scan would have diverged: a cap or the page
                                    // budget would have bitten mid-file. Re-run it against the
                                    // real accumulated state, which is by construction what the
                                    // sequential walk did. With one query this happens at most
                                    // once per run — on the candidate that fills the page.
                                    scanFile(
                                        at: url, relativePath: relativePath,
                                        plan: plan, into: &results)
                                }
                            } else {
                                return
                            }
                        }
                        mergeCursor += 1
                        if results.budgetExhausted(plan) {
                            stopped = true
                            stopStep = step
                            return
                        }
                    }
                }

                while true {
                    fillWindow()
                    mergeReady()
                    if stopped { break }
                    // The ONLY exit besides the budget: the walk is over and every step it
                    // produced has been merged. Not "nothing is in flight" — with a window of
                    // one, the merge catches up after every single candidate, and treating that
                    // as done ends the search on its first file.
                    if walkerExhausted && mergeCursor >= steps.count { break }
                    // Nothing outstanding means the merge is caught up and the window has room;
                    // the next `fillWindow` is what makes progress, so loop rather than wait.
                    guard dispatched > harvested else { continue }
                    // Otherwise `mergeReady` stopped on a candidate still in flight.
                    // `group.next()` yields in COMPLETION order, so the arrival may be a later
                    // index — it waits in `arrived` until its turn comes.
                    guard let (index, scanned) = await group.next() else { break }
                    harvested += 1
                    arrived[index] = scanned
                }
                group.cancelAll()
            }
        }

        return finish(walker: walker, stopStep: stopStep, dispatched: dispatched,
                      adopted: adoptedFromParallel, into: &results)
    }

    /// Settles the walk-level counters both drives share.
    private static func finish(
        walker: SearchDirectoryWalker,
        stopStep: SearchDirectoryWalker.Step?,
        dispatched: Int,
        adopted: Int,
        into results: inout SearchScanResults
    ) -> ParallelScanOutcome {
        // Waste = every scan dispatched to the parallel lane whose result the merge did not use.
        // That covers both shapes: a candidate re-scanned to honour a limit, and the read-ahead
        // past the stop. Counting DISPATCHES rather than completions keeps it deterministic —
        // whether a cancelled task got as far as opening its file is a timing question, and a
        // counter a pin asserts on must not have one of those in it. The sequential drive
        // dispatches nothing, so its waste is zero by construction rather than by measurement.
        results.stats.speculativeScansDiscarded = dispatched - adopted

        // Roll the speculative tail back to where the sequential walk would have stopped. The
        // parallel walker raced ahead by up to `concurrency` candidates, so its own counters
        // describe a walk that never happened; the stopping step's snapshot describes the one
        // that did. (The sequential drive stops ON the step, so the two agree there — which is
        // the property that lets one helper serve both.)
        if let stopStep {
            results.stats.dirsEnumerated = stopStep.dirsEnumerated
            return ParallelScanOutcome(
                visitedPaths: Array(walker.visitedPaths.prefix(stopStep.rosterCount)))
        }
        // Ran to completion: trailing directories the walk entered after its last event are real
        // enumerations the sequential version also performed, so take the walker's live count
        // rather than the last step's snapshot.
        results.stats.dirsEnumerated = walker.dirsEnumerated
        return ParallelScanOutcome(visitedPaths: walker.visitedPaths)
    }
}
