import Foundation

/// Process-global writer/reader for per-step `step_log.jsonl` files — the disk
/// home of a step's four stream collections since 2026-08-21, split out of
/// `task.json` so `updateTaskOnly` appends O(delta) instead of re-serializing
/// every run's whole conversation per mutation (measured ≈39 GB written to
/// produce one 18.3 MB task).
///
/// **Why repository-side diffing, not domain-side counters.** The flush must
/// reflect everything accumulated since the LAST FLUSH, not what one closure
/// changed: `mutateTaskInMemory` (streaming commits) bypasses disk entirely and
/// is persisted lazily by whatever `mutateTask` runs next; a counter on
/// `StepExecution` would also have to be written back after the detached write
/// — exactly the lost-update window CLAUDE.md invariant #6 forbids. So each
/// file's registry entry retains the LAST-FLUSHED arrays and diffs the incoming
/// ones against them. The retained copies are COW-shared with the live task, so
/// the memory cost is pointers, and unchanged elements compare `==` through
/// identical storage.
///
/// **Serialization is per FILE** (registry of serial queues keyed by canonical
/// path — the `JSONLFileLog` rule): parallel roles of one run write different
/// step files with zero contention; two writers of ONE step serialize here.
///
/// **Compaction** is garbage collection: replace-by-id and truncate records
/// leave dead lines behind; when the dead-record count exceeds
/// `max(64, live records)`, the file is atomically rewritten from the current
/// arrays. Amortized O(step): every dead record was paid for once when written.
nonisolated enum TaskStreamStore {

    /// The four stream collections — the unit the diff, the log and the replay
    /// all work on.
    struct StepStreams: Equatable {
        var conversation: [LLMMessage] = []
        var wire: [ChatMessage] = []
        var toolCalls: [StepToolCall] = []
        var messages: [StepMessage] = []

        var isEmpty: Bool {
            conversation.isEmpty && wire.isEmpty && toolCalls.isEmpty && messages.isEmpty
        }
    }

    private final class Entry {
        let queue = DispatchQueue(label: "com.nanoteams.taskstreamstore")
        var nextSeq = 1
        var liveRecords = 0
        var deadRecords = 0
    }

    /// Last-flushed state — the diff baseline — plus the stamp that state
    /// produced. `nil` = cold (nothing known about the file in this process).
    ///
    /// Deliberately NOT a field on `Entry`: `splittingStreams` must be able to
    /// ask "did this step change at all" WITHOUT the per-file queue hop, and a
    /// field written inside the queue cannot be read outside it. Guarded by
    /// `registryLock` alone, so `cachedCommitIfUnchanged` needs exactly one
    /// uncontended lock and no `DispatchQueue.sync`. One home for the fact, not
    /// two (CLAUDE.md #91): the queue block reads and writes it through the same
    /// two accessors.
    private struct Baseline {
        var streams: StepStreams
        var commit: StepLogCommit
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var baselines: [String: Baseline] = [:]

    private static func key(for url: URL) -> String { url.standardizedFileURL.path }

    private static func entry(forKey key: String) -> Entry {
        registryLock.withLock {
            if let existing = entries[key] { return existing }
            let fresh = Entry()
            entries[key] = fresh
            return fresh
        }
    }

    private static func baseline(forKey key: String) -> Baseline? {
        registryLock.withLock { baselines[key] }
    }

    private static func setBaseline(_ streams: StepStreams, commit: StepLogCommit, forKey key: String) {
        registryLock.withLock { baselines[key] = Baseline(streams: streams, commit: commit) }
    }

    private static func clearBaseline(forKey key: String) {
        registryLock.withLock { baselines[key] = nil }
    }

    /// The stamp a step already has, when its four streams are PROVABLY the ones
    /// last flushed — a copy-on-write storage-identity test, O(1), no queue hop,
    /// no URL.
    ///
    /// Sound in one direction only, deliberately. The store retains the
    /// last-flushed arrays, so a shared buffer address means no in-place edit can
    /// have happened since: any mutation through `_modify`
    /// (`updateToolCallResult`, `commitStreamingContent`, `applyRetryNotice` —
    /// the three writers that change CONTENT while leaving every count equal)
    /// must copy first, and a retained buffer's address cannot be reused by a
    /// different live array. The converse is not claimed: a replaced-but-equal
    /// array (`saveLLMConversation` rebuilds the whole conversation) fails the
    /// test and falls through to the real diff, which finds nothing and returns
    /// the same stamp through `records.isEmpty`. The gate can only ever be
    /// conservative, which is why a counts-based test — the shape DEBTS.md
    /// proposed — was rejected: counts cannot see those three writers at all,
    /// and skipping them would silently drop tool results from the log.
    static func cachedCommitIfUnchanged(
        _ streams: StepStreams, forKey key: String
    ) -> StepLogCommit? {
        guard let base = baseline(forKey: key) else { return nil }
        guard sharesStorage(base.streams.conversation, streams.conversation),
              sharesStorage(base.streams.wire, streams.wire),
              sharesStorage(base.streams.toolCalls, streams.toolCalls),
              sharesStorage(base.streams.messages, streams.messages)
        else { return nil }
        return base.commit
    }

    /// True when both arrays are backed by the same copy-on-write buffer (or are
    /// both empty). Never a value comparison — that is the cost being avoided.
    private static func sharesStorage<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress }
        }
    }

    private static let encoder = JSONCoderFactory.makeJSONLEncoder()
    private static let decoder = JSONCoderFactory.makeDateDecoder()

    // MARK: - Flush (write path)

    /// Persists `streams` as a delta against the last flushed state and returns
    /// the commit stamp for `task.json`. A COLD entry (first touch this
    /// process) rewrites the file wholesale from memory — always correct, and
    /// exactly one amortized full write per step, ever (this is also how a
    /// legacy task's embedded arrays migrate on their first mutation).
    /// Returns nil when the write failed; the caller must then keep the OLD
    /// `logCommit` so the next flush retries.
    static func flush(
        _ streams: StepStreams,
        to url: URL,
        fileManager: FileManager = .default,
        directoryAttributes: [FileAttributeKey: Any]? = nil
    ) -> StepLogCommit? {
        let key = key(for: url)
        let e = entry(forKey: key)
        return e.queue.sync {
            guard let base = baseline(forKey: key)?.streams else {
                return rewriteWholeFile(streams, e: e, key: key, url: url,
                                        fileManager: fileManager,
                                        directoryAttributes: directoryAttributes)
            }
            var records: [StepLogRecord] = []
            var dead = 0
            diffByID(old: base.conversation, new: streams.conversation,
                     stream: .conversation, wrap: StepLogRecord.conversation,
                     into: &records, dead: &dead)
            diffByID(old: base.toolCalls, new: streams.toolCalls,
                     stream: .toolCalls, wrap: StepLogRecord.toolCall,
                     into: &records, dead: &dead)
            diffByID(old: base.messages, new: streams.messages,
                     stream: .messages, wrap: StepLogRecord.message,
                     into: &records, dead: &dead)
            diffPositional(old: base.wire, new: streams.wire,
                           into: &records, dead: &dead)

            guard !records.isEmpty else {
                // Nothing changed — the commit stamp is the current state. Re-seat
                // the baseline on THIS value so the next flush's storage-identity
                // gate can answer without a diff (a replaced-but-equal array
                // arrives here, and only this assignment makes it cheap next time).
                let stamp = commit(for: streams, e: e)
                setBaseline(streams, commit: stamp, forKey: key)
                return stamp
            }

            let compactionDue = (e.deadRecords + dead) > max(64, liveCount(streams))
            if compactionDue {
                return rewriteWholeFile(streams, e: e, key: key, url: url,
                                        fileManager: fileManager,
                                        directoryAttributes: directoryAttributes)
            }

            var payload = Data()
            for record in records {
                guard let line = try? encoder.encode(StepLogEntry(seq: e.nextSeq, record: record))
                else { return nil }
                payload.append(line)
                payload.append(0x0A)
                e.nextSeq += 1
            }
            #if DEBUG
            countBytes(payload.count)
            #endif
            guard appendRaw(payload, to: url, fileManager: fileManager,
                            directoryAttributes: directoryAttributes) else {
                // The seq counter advanced for records that may not have landed —
                // go cold so the next flush rewrites from memory.
                clearBaseline(forKey: key)
                return nil
            }
            e.deadRecords += dead
            e.liveRecords = liveCount(streams)
            let stamp = commit(for: streams, e: e)
            setBaseline(streams, commit: stamp, forKey: key)
            return stamp
        }
    }

    // MARK: - Hydrate (read path)

    /// Replays the step's log into stream arrays and seeds the diff baseline so
    /// the next flush is a true delta. `expected` is the `logCommit` the
    /// metadata carries; disagreement resolves per the `StepLogCommit` table
    /// (the LOG is the authority in both directions) and the returned commit is
    /// the repaired stamp. Returns nil when the file does not exist — the
    /// caller falls back to the embedded arrays (legacy task) or empty streams.
    static func hydrate(
        from url: URL,
        expected: StepLogCommit?,
        fileManager: FileManager = .default
    ) -> (streams: StepStreams, commit: StepLogCommit)? {
        let key = key(for: url)
        let e = entry(forKey: key)
        return e.queue.sync {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let entries = JSONLFileLog.decodeLines(
                StepLogEntry.self, from: url, decoder: decoder, fileManager: fileManager)
            #if DEBUG
            countHydrate(entries.count)
            #endif
            var streams = StepStreams()
            var convIndex: [UUID: Int] = [:]
            var callIndex: [UUID: Int] = [:]
            var msgIndex: [UUID: Int] = [:]
            var live = 0
            for entry in entries {
                switch entry.record {
                case .conversation(let m):
                    replayByID(m, into: &streams.conversation, index: &convIndex)
                case .toolCall(let t):
                    replayByID(t, into: &streams.toolCalls, index: &callIndex)
                case .message(let m):
                    replayByID(m, into: &streams.messages, index: &msgIndex)
                case .wire(let w):
                    streams.wire.append(w)
                case .truncate(let stream, let keep):
                    switch stream {
                    case .conversation:
                        streams.conversation = Array(streams.conversation.prefix(keep))
                        convIndex = rebuildIndex(streams.conversation)
                    case .wire:
                        streams.wire = Array(streams.wire.prefix(keep))
                    case .toolCalls:
                        streams.toolCalls = Array(streams.toolCalls.prefix(keep))
                        callIndex = rebuildIndex(streams.toolCalls)
                    case .messages:
                        streams.messages = Array(streams.messages.prefix(keep))
                        msgIndex = rebuildIndex(streams.messages)
                    }
                }
                live = liveCount(streams)
            }
            let lastSeq = entries.last?.seq ?? 0
            if let expected, expected.seq != lastSeq {
                // Crash window: log ahead = real work after the last metadata
                // write (trust the log); log behind = torn tail (accept the
                // log; loss ≤ one flush). Either way the repaired stamp below
                // reflects the LOG and the next flush persists it.
                print("[TaskStreamStore] WARNING: \(url.lastPathComponent) seq \(lastSeq) "
                    + "vs metadata \(expected.seq) — resolving from the log")
            }
            e.nextSeq = lastSeq + 1
            e.liveRecords = live
            e.deadRecords = max(0, entries.count - live)
            let stamp = StepLogCommit(
                seq: lastSeq,
                conversation: streams.conversation.count,
                wire: streams.wire.count,
                toolCalls: streams.toolCalls.count,
                messages: streams.messages.count)
            setBaseline(streams, commit: stamp, forKey: key)
            return (streams, stamp)
        }
    }

    #if DEBUG
    /// Test isolation: forget everything about `url` (fresh-process behavior).
    static func _testResetEntry(for url: URL) {
        let key = key(for: url)
        registryLock.withLock {
            _ = entries.removeValue(forKey: key)
            _ = baselines.removeValue(forKey: key)
        }
    }

    /// Work-bound seam: total log bytes written (appends + rewrites) since reset.
    nonisolated(unsafe) private static var _bytesWritten = 0
    static func _testBytesWritten() -> Int { registryLock.withLock { _bytesWritten } }
    static func _testResetBytesWritten() { registryLock.withLock { _bytesWritten = 0 } }
    private static func countBytes(_ n: Int) { registryLock.withLock { _bytesWritten += n } }

    /// Work-bound seam: log files actually READ back, and the entries replayed out of
    /// them, since reset. The read twin of `_bytesWritten`, added 2026-08-30 because the
    /// write side had a counter and the read side had none — so "the narrow work-folder
    /// writers re-hydrate the whole conversation history on every call" was arguable from
    /// the code and provable by nothing. Counted INSIDE `hydrate`, past the
    /// file-exists guard, for CLAUDE.md #62's reason: a counter at the call site would
    /// report intent, not work.
    nonisolated(unsafe) private static var _hydrateReads = 0
    nonisolated(unsafe) private static var _hydrateEntries = 0
    static func _testHydrateReads() -> Int { registryLock.withLock { _hydrateReads } }
    static func _testHydrateEntries() -> Int { registryLock.withLock { _hydrateEntries } }
    static func _testResetHydrateCounters() {
        registryLock.withLock { _hydrateReads = 0; _hydrateEntries = 0 }
    }
    private static func countHydrate(_ entries: Int) {
        registryLock.withLock { _hydrateReads += 1; _hydrateEntries += entries }
    }

    /// Work-bound seam: stream ELEMENTS examined by the diff passes since reset.
    ///
    /// Bytes cannot see this defect — an unchanged step emits no records and
    /// writes nothing, yet still pays a full comparison pass over its history.
    /// The counter lives inside the diff loops rather than beside `flush`'s call
    /// site for the reason CLAUDE.md #62 records: a counter outside would report
    /// what the caller intended to diff, not what the diff actually walked.
    nonisolated(unsafe) private static var _diffWork = 0
    static func _testDiffWork() -> Int { registryLock.withLock { _diffWork } }
    static func _testResetDiffWork() { registryLock.withLock { _diffWork = 0 } }
    private static func countDiffWork(_ n: Int) { registryLock.withLock { _diffWork += n } }
    #endif

    // MARK: - Private

    private static func commit(for streams: StepStreams, e: Entry) -> StepLogCommit {
        StepLogCommit(
            seq: e.nextSeq - 1,
            conversation: streams.conversation.count,
            wire: streams.wire.count,
            toolCalls: streams.toolCalls.count,
            messages: streams.messages.count)
    }

    private static func liveCount(_ s: StepStreams) -> Int {
        s.conversation.count + s.wire.count + s.toolCalls.count + s.messages.count
    }

    /// Whole-file atomic rewrite from the current arrays — the cold-entry path,
    /// the compaction path, and the recovery path after a failed append. One
    /// implementation on purpose.
    private static func rewriteWholeFile(
        _ streams: StepStreams, e: Entry, key: String, url: URL,
        fileManager: FileManager,
        directoryAttributes: [FileAttributeKey: Any]?
    ) -> StepLogCommit? {
        var payload = Data()
        var seq = 0
        func emit(_ record: StepLogRecord) -> Bool {
            seq += 1
            guard let line = try? encoder.encode(StepLogEntry(seq: seq, record: record))
            else { return false }
            payload.append(line)
            payload.append(0x0A)
            return true
        }
        for m in streams.conversation { guard emit(.conversation(m)) else { return nil } }
        for w in streams.wire { guard emit(.wire(w)) else { return nil } }
        for t in streams.toolCalls { guard emit(.toolCall(t)) else { return nil } }
        for m in streams.messages { guard emit(.message(m)) else { return nil } }
        #if DEBUG
        countBytes(payload.count)
        #endif
        guard JSONLFileLog.rewrite(url, with: payload, fileManager: fileManager,
                                   directoryAttributes: directoryAttributes) else {
            clearBaseline(forKey: key)
            return nil
        }
        e.nextSeq = seq + 1
        e.liveRecords = seq
        e.deadRecords = 0
        let stamp = commit(for: streams, e: e)
        setBaseline(streams, commit: stamp, forKey: key)
        return stamp
    }

    private static func appendRaw(
        _ payload: Data, to url: URL,
        fileManager: FileManager,
        directoryAttributes: [FileAttributeKey: Any]?
    ) -> Bool {
        do {
            let parent = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(
                    at: parent, withIntermediateDirectories: true,
                    attributes: directoryAttributes)
            }
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            return true
        } catch {
            #if DEBUG
            print("[TaskStreamStore] append to \(url.lastPathComponent) failed: \(error)")
            #endif
            return false
        }
    }

    /// Diff an id-bearing stream. Fast path: same length, same ids positionally
    /// → one record per CHANGED element (`updateToolCallResult`,
    /// `commitStreamingContent`). General path: longest common prefix by
    /// (id, ==), a truncate when the old tail is gone, then append the new
    /// tail. Pure append (`lcp == old.count`) emits no truncate.
    private static func diffByID<T: Identifiable & Equatable>(
        old: [T], new: [T],
        stream: StepLogStream,
        wrap: (T) -> StepLogRecord,
        into records: inout [StepLogRecord],
        dead: inout Int
    ) where T.ID == UUID {
        #if DEBUG
        countDiffWork(max(old.count, new.count))
        #endif
        if old.count == new.count, zip(old, new).allSatisfy({ $0.id == $1.id }) {
            for (o, n) in zip(old, new) where o != n {
                records.append(wrap(n))
                dead += 1
            }
            return
        }
        var lcp = 0
        while lcp < old.count && lcp < new.count
            && old[lcp].id == new[lcp].id && old[lcp] == new[lcp] {
            lcp += 1
        }
        if lcp < old.count {
            records.append(.truncate(stream: stream, keep: lcp))
            dead += old.count - lcp
        }
        for i in lcp..<new.count {
            records.append(wrap(new[i]))
        }
    }

    private static func diffPositional(
        old: [ChatMessage], new: [ChatMessage],
        into records: inout [StepLogRecord],
        dead: inout Int
    ) {
        #if DEBUG
        countDiffWork(max(old.count, new.count))
        #endif
        var lcp = 0
        while lcp < old.count && lcp < new.count && old[lcp] == new[lcp] {
            lcp += 1
        }
        if lcp < old.count {
            records.append(.truncate(stream: .wire, keep: lcp))
            dead += old.count - lcp
        }
        for i in lcp..<new.count {
            records.append(.wire(new[i]))
        }
    }

    private static func replayByID<T: Identifiable>(
        _ element: T, into array: inout [T], index: inout [T.ID: Int]
    ) {
        if let at = index[element.id] {
            array[at] = element
        } else {
            index[element.id] = array.count
            array.append(element)
        }
    }

    private static func rebuildIndex<T: Identifiable>(_ array: [T]) -> [T.ID: Int] {
        var index: [T.ID: Int] = [:]
        for (i, element) in array.enumerated() { index[element.id] = i }
        return index
    }
}
