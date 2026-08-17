import Foundation

/// Per-step tool-call tracker. Records every executed tool call so
/// `ToolCallLoopDetector` (via `recentCalls`) and the identical-write guard
/// (via `writeFingerprints`) can read recent state. Not a result cache —
/// every authorized non-duplicate-write call hits `ToolRuntime`.
nonisolated final class ToolCallTracker: @unchecked Sendable {

    private typealias TN = ToolNames

    struct TrackedCall {
        let toolName: String
        let argumentsSummary: String
        /// Hash of the CANONICAL arguments JSON — the loop detector's identity key.
        ///
        /// Deliberately not `argumentsSummary`: that string is produced by
        /// `ToolCallSummarizer`, whose job is a one-line DISPLAY label, and which returns
        /// `""` for every tool absent from its table — all ten Autovisor tools,
        /// `ask_supervisor`, most git-read tools, the delegation follow-ups — plus
        /// `create_artifact`, which is mapped to `""` outright. Grouping on it therefore
        /// collapsed calls with completely different arguments into one "identical
        /// arguments" bucket, which is the exact false positive the detector's own comment
        /// claims to have fixed.
        ///
        /// Hashed rather than stored: identity is only ever compared inside ONE tracker
        /// (per step), so a process-randomized hash is sound — the same argument
        /// `WriteFingerprint` below already relies on — and it keeps a 50 KB
        /// `create_artifact` payload from being retained 30 times over.
        let argumentsIdentity: Int
        let resultSummary: String
        let resultJSON: String
        let wasSuccessful: Bool
        /// Which INFORMATION EPOCH this call was made in — how many times information had
        /// been PUSHED at the model, that no tool call of its own asked for, by the moment
        /// the call was recorded. Bumped by a queued Supervisor turn delivered mid-loop
        /// (human steering, the Autovisor's mid-review event notice, `message_task`).
        ///
        /// An ORDINAL rather than a "this call opened an epoch" flag, and the difference is
        /// load-bearing twice over. (1) The detector's run break becomes a comparison
        /// against the run's own tail, so a boundary that lands on a call the detector
        /// cannot see — an excluded `update_scratchpad`, the likeliest move right after
        /// news, or a failed call — is carried across for free instead of by hand.
        /// (2) `loopWarningSignature` can ask which epoch the DETECTED RUN lives in rather
        /// than which epoch the tracker is in: with a flag those diverge, and an arrival
        /// that had not yet reached a single visible call still changed the signature,
        /// re-arming the once-per-condition gate and appending a second identical nudge
        /// about a run made entirely before the news.
        ///
        /// The in-step half is armed at exactly ONE seam — `injectQueuedSupervisorMessage`
        /// reporting a delivery — so it covers the queue and nothing else. `forward_to_team`
        /// reaches a child by direct injection plus `resumeRun`, never through the child's
        /// queue, so that arrival is seen only by the committed half
        /// (`ConversationInformationBoundary`), which reads the persisted turn.
        ///
        /// Deliberately no default in the memberwise init. There is exactly one production
        /// producer (`record`), so the compiler asking costs nothing, and "which epoch was
        /// this decided in" has no spelling that is right for a caller who did not think
        /// about it.
        let informationEpoch: Int
    }

    /// Canonical identity of a tool call's arguments: key-sorted JSON of the SPELLING-
    /// NORMALIZED payload when it parses, the trimmed raw text otherwise (a malformed
    /// payload is still identical to its own byte-for-byte repeat, which is the case the
    /// detector cares about).
    static func argumentsIdentity(forJSON argumentsJSON: String) -> Int {
        var hasher = Hasher()
        if let dict = ToolCallDataUtils.parseJSON(argumentsJSON),
           let canonical = ToolCallParsingHelpers.stableJSONString(
               from: normalizeSpelling(dict)) {
            hasher.combine(canonical)
        } else {
            hasher.combine(argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return hasher.finalize()
    }

    /// Collapses the spellings the ARGUMENT LAYER already treats as one, so identity
    /// answers "would the runtime do the same thing twice?" rather than "did the model
    /// type the same characters twice?".
    ///
    /// `ToolArgumentHelpers` accepts `"501"` wherever it accepts `501` and `"true"`
    /// wherever it accepts `true` (small models quote numbers freely — the documented
    /// `read_lines` pagination case). Two calls a model spells differently therefore
    /// execute identically, and a detector that missed that would under-report a real
    /// spin. Deliberately narrow: only quoted numbers and quoted booleans fold, and only
    /// when the round-trip is exact, so `"0501"` stays distinct from `501` and no two
    /// genuinely different values are ever merged — the direction that matters, since a
    /// false "you are looping" is what made an engineer abandon a correct scaffolding
    /// streak in run EA190834.
    private static func normalizeSpelling(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues(normalizeSpelling)
        }
        if let array = value as? [Any] {
            return array.map(normalizeSpelling)
        }
        guard let text = value as? String else { return value }
        if let int = Int(text), String(int) == text { return int }
        if text == "true" { return true }
        if text == "false" { return false }
        return text
    }

    // MARK: - State

    private var calls: [TrackedCall] = []
    private let maxTrackedCalls: Int = LLMConstants.maxTrackedToolCalls
    private var lastScratchpadContentHash: Int?
    /// How many information epochs this step has entered. Stamped onto every call
    /// `record` appends, so the epoch travels with the call rather than being re-read
    /// later from a tracker that has moved on.
    ///
    /// Read by the loop-warning gate (via the epoch of the DETECTED RUN, not this
    /// value) so its once-per-condition signature is scoped to the epoch: without that
    /// scoping a role warned once is never warned again for that tool, so the boundary
    /// could only ever change the FIRST warning and a model that loops, is told
    /// something, and loops again passes in silence. Bounded by construction — a
    /// boundary alone emits nothing, and each warning still costs three identical calls
    /// in a row after it.
    private(set) var informationEpoch = 0
    /// Fingerprints of `write_file` calls already attempted in this step.
    /// Used by the runtime to reject a second `write_file` with identical content to the same path
    /// — the most common failure mode observed with smaller LLMs (Gemma-4 wrote `script.js` 14×
    /// with the exact same 3945 B content). Reset implicitly because `ToolCallTracker` is per-step.
    private var writeFingerprints: Set<WriteFingerprint> = []

    /// Structured fingerprint of a `write_file` call. Encoding (`path|utf8Length|hash(content)`)
    /// stays internal — callers reason about the triple, not a stringly-typed key.
    /// `Hasher` is process-randomized; fingerprints are only meaningful within this tracker's
    /// per-step lifetime, which is the only scope the dedup invariant applies to anyway.
    private struct WriteFingerprint: Hashable {
        let path: String
        let utf8Length: Int
        let contentHash: Int

        init?(argumentsJSON: String) {
            guard let dict = ToolCallDataUtils.parseJSON(argumentsJSON),
                  let path = dict["path"] as? String,
                  let content = dict["content"] as? String else { return nil }
            var hasher = Hasher()
            hasher.combine(content)
            self.path = path
            self.utf8Length = content.utf8.count
            self.contentHash = hasher.finalize()
        }
    }

    /// Canonicalize at every ingress point so the loop-detector fingerprints
    /// treat `repo_browser.read_file`, `functions.read_file`, and `read_file`
    /// as one and the same call.
    private func canonical(_ toolName: String) -> String {
        ToolRegistry.resolveToolName(toolName)
    }

    // MARK: - Recording

    /// Records that information reached the model without any tool call of its own
    /// producing it — today the only source is a delivered queued-Supervisor turn
    /// (`LLMExecutionService.injectQueuedSupervisorMessage` returning `true`).
    ///
    /// The window is NOT cleared: clearing would also erase a genuine run that the new
    /// information does not excuse, and would re-arm the detector's own 6-call minimum,
    /// suppressing detection for six more calls. Advancing the epoch instead keeps every
    /// call and lets `ToolCallLoopDetector` stop counting AT the change — so a model that
    /// gets an event and keeps repeating the same call still fires, three calls later.
    ///
    /// Idempotence is deliberately NOT provided: two arrivals with no call between them
    /// legitimately produce two epochs, and nothing downstream counts epochs — the
    /// detector compares them and the warning gate keys on the one its run carries.
    func noteExternalInformationArrived() {
        informationEpoch += 1
    }

    func record(toolName: String, argumentsJSON: String, resultJSON: String, isError: Bool) {
        let toolName = canonical(toolName)
        if toolName == ToolNames.updateScratchpad, !isError {
            if let dict = ToolCallDataUtils.parseJSON(argumentsJSON),
               let content = resolveContentString(dict) {
                let contentHash = content.hashValue
                if contentHash == lastScratchpadContentHash { return }
                lastScratchpadContentHash = contentHash
            }
        }

        // `summarizeArguments`, deliberately NOT `cardSummary`. That one refines a
        // successful `edit_file` into the line range it touched, which is right for a
        // display surface and wrong here: this summary is what the loop-warning text quotes
        // back to the MODEL, and a line range is a fact the model cannot act on — it
        // anchors edits by text, not by position. The anchor preview is what distinguishes
        // successive edits to one file in that warning, which is the whole reason the
        // `edit_file` entry summarizes the anchor at all.
        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        let resultSummary = ToolCallSummarizer.summarizeResult(toolName: toolName, json: resultJSON)

        calls.append(TrackedCall(
            toolName: toolName,
            argumentsSummary: argSummary,
            argumentsIdentity: Self.argumentsIdentity(forJSON: argumentsJSON),
            resultSummary: resultSummary,
            resultJSON: resultJSON,
            wasSuccessful: !isError,
            informationEpoch: informationEpoch
        ))

        if calls.count > maxTrackedCalls {
            calls.removeFirst(calls.count - maxTrackedCalls)
        }
    }

    // MARK: - Snapshots for loop detector

    /// Returns the most recent `limit` tracked calls. Used by `ToolCallLoopDetector`
    /// to spot 6-in-a-row patterns. (It also fed a first-iteration gate in the
    /// one-shot planning phase; that gate is gone — `PlanningPhasePolicy` keys on
    /// `scratchpadIsNil` instead, since a phase built to read things first must
    /// survive its own first `read_file`.)
    func recentCalls(limit: Int) -> [TrackedCall] {
        Array(calls.suffix(limit))
    }

    // MARK: - Identical-write loop guard

    /// Returns `true` if `write_file` with this exact `(path, content)` pair has already been
    /// attempted in this step. Caller should reject the duplicate with an `identical_write_loop`
    /// error envelope rather than re-executing.
    func isDuplicateIdenticalWrite(toolName: String, argumentsJSON: String) -> Bool {
        guard canonical(toolName) == TN.writeFile,
              let fp = WriteFingerprint(argumentsJSON: argumentsJSON) else { return false }
        return writeFingerprints.contains(fp)
    }

    /// Records that a `write_file` call with this `(path, content)` was attempted. Subsequent
    /// identical calls in the same step will be flagged by `isDuplicateIdenticalWrite`.
    func recordWriteFingerprint(toolName: String, argumentsJSON: String) {
        guard canonical(toolName) == TN.writeFile,
              let fp = WriteFingerprint(argumentsJSON: argumentsJSON) else { return }
        writeFingerprints.insert(fp)
    }

    /// Atomic check-and-record: returns `true` if this `write_file` `(path, content)` was
    /// already attempted in this step (caller must reject with `identical_write_loop`),
    /// otherwise records the fingerprint and returns `false` (caller proceeds with execution).
    /// Fuses the two-step `isDuplicateIdenticalWrite` + `recordWriteFingerprint` dance so
    /// the ordering invariant lives in the type rather than a caller comment — two identical
    /// `write_file` calls in one batch are guaranteed to trip on the second pass regardless
    /// of how the caller arranges its loop.
    @discardableResult
    func checkAndRecordWrite(toolName: String, argumentsJSON: String) -> Bool {
        if isDuplicateIdenticalWrite(toolName: toolName, argumentsJSON: argumentsJSON) {
            return true
        }
        recordWriteFingerprint(toolName: toolName, argumentsJSON: argumentsJSON)
        return false
    }

    nonisolated deinit {}
}
