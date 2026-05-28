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
        let resultSummary: String
        let resultJSON: String
        let timestamp: Date
        let wasSuccessful: Bool
    }

    // MARK: - State

    private var calls: [TrackedCall] = []
    private let maxTrackedCalls: Int = LLMConstants.maxTrackedToolCalls
    private var lastScratchpadContentHash: Int?
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

        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        let resultSummary = ToolCallSummarizer.summarizeResult(toolName: toolName, json: resultJSON)

        calls.append(TrackedCall(
            toolName: toolName,
            argumentsSummary: argSummary,
            resultSummary: resultSummary,
            resultJSON: resultJSON,
            timestamp: MonotonicClock.shared.now(),
            wasSuccessful: !isError
        ))

        if calls.count > maxTrackedCalls {
            calls.removeFirst(calls.count - maxTrackedCalls)
        }
    }

    // MARK: - Snapshots for loop detector / contextualizer

    /// Returns an immutable copy of all tracked calls for consumers that need the
    /// full history (`ToolCallContextualizer.generateSummary` / `generateStateContext`).
    /// Swift `Array` is a value type with copy-on-write, so this is O(1) until the
    /// caller mutates — and callers never do; they iterate / map / filter.
    func snapshot() -> [TrackedCall] {
        calls
    }

    /// Returns the most recent `limit` tracked calls. Used by `ToolCallLoopDetector`
    /// to spot 6-in-a-row patterns and by the planning-phase first-iteration gate.
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
