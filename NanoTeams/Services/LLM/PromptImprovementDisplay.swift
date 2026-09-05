import Foundation
#if DEBUG
import Synchronization
#endif

/// Per-delta display pipeline of the improve stream. One home for three facts the session used to
/// derive per delta from its raw buffer (`PromptImprovementSession.displayText`, removed 2026-09-02):
/// the raw buffer, the text the field shows, and the opening-fence decision. Invariant after every `append`, pinned by `PromptImprovementDisplayTests`:
/// `text == Self.rendered(ModelTokenCleaner.stripTokens(raw)).text`
///
/// `nonisolated` for the same reason `ModelTokenCleaner` is: the app target defaults to
/// `@MainActor`, and tests are implicitly nonisolated and drive this value type synchronously.
nonisolated struct PromptImprovementDisplay {
    /// Raw deltas, untouched — `PromptImprovementService.postProcess` reads it at end of stream.
    private(set) var raw = ""
    /// What the field shows: `raw` with `<|…|>` tokens stripped and the opening fence line hidden.
    private(set) var text = ""
    private(set) var fence: OpeningFence = .undecided

    enum OpeningFence: Equatable {
        /// First non-blank line so far (trimmed) is "", "`" or "``" — may still become a fence.
        case undecided
        /// FINAL: the first non-blank line is not a fence (its trimmed text is not a prefix of "```",
        /// or the line is complete). Appending cannot change a decided prefix.
        case none
        /// Fence line hidden, its terminating "\n" not yet seen — the hidden segment is still growing.
        case hiddenOpen
        /// FINAL: fence line hidden and terminated; every later character is visible verbatim.
        case hiddenClosed

        var isFinal: Bool { self == .none || self == .hiddenClosed }
    }

    /// O(delta) on the common path. Whole-buffer work runs only when the RAW tail could have completed
    /// a token (`tailMayCompleteToken`, the same window `StreamingPreviewManager.append` gates on) or
    /// while the fence decision is not final — units of times per stream. `text += delta` still
    /// memcpy's N bytes when the host / `lastWritten` share its storage; that is the cost of handing
    /// the field a String per delta, not of this pipeline.
    ///
    /// Why `raw` is kept rather than stripping the shown buffer incrementally: gate-silent proves
    /// `stripTokens(raw + delta) == stripTokens(raw) + delta` (see `tailMayCompleteToken`), which is
    /// STRONGER than the `StreamingPreviewManager` contract (equivalence to re-stripping an
    /// already-stripped buffer). The two differ on an opener kept for its span — `<|` + 27×`a` +
    /// `<|e|>` then `|>` — where the incremental shape deletes what the whole-buffer strip keeps.
    mutating func append(_ delta: String) {
        raw += delta
        // Evaluated on EVERY delta (the work pin's anti-vacuum relies on the gate seeing each one).
        let tokenMayHaveCompleted = ModelTokenCleaner.tailMayCompleteToken(raw, newDeltaCount: delta.count)
        if tokenMayHaveCompleted || !fence.isFinal {
            (text, fence) = Self.rendered(ModelTokenCleaner.stripTokens(raw))
        } else {
            text += delta
        }
    }

    /// The fence rule: hide the first non-blank line when it opens a code fence, so mid-stream
    /// output reads clean, and report whether that decision can still change. Tokens are the
    /// caller's job — this takes an already-stripped buffer. The full pipeline (trim + closing-fence
    /// strip) runs once at end of stream via `PromptImprovementService.postProcess`.
    static func rendered(_ stripped: String) -> (text: String, fence: OpeningFence) {
        #if DEBUG
        _renderWork.wrappingAdd(stripped.count, ordering: .relaxed)
        #endif
        var lines = stripped.components(separatedBy: "\n")
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        // No non-blank line yet.
        guard index < lines.count else { return (stripped, .undecided) }
        let head = lines[index].trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("```") else {
            let mayStillBecomeFence = index == lines.count - 1 && "```".hasPrefix(head)
            return (stripped, mayStillBecomeFence ? .undecided : .none)
        }
        // A line after the fence exists ⟹ its "\n" arrived. Decided BEFORE the remove shifts count.
        let terminated = index < lines.count - 1
        lines.remove(at: index)
        return (lines.joined(separator: "\n"), terminated ? .hiddenClosed : .hiddenOpen)
    }

    #if DEBUG
    /// Work-bound seam: characters handed to the whole-buffer render since reset. Lives INSIDE the
    /// render, not beside the branch in `append` — a counter next to the call would pin a
    /// consequence, not the decision (CLAUDE.md #62; measured on `ModelTokenCleaner._gateWork`).
    /// Same shape as `ModelTokenCleaner._gateWork` / `_stripWork`.
    private static let _renderWork = Atomic<Int>(0)
    static func _testRenderWork() -> Int { _renderWork.load(ordering: .relaxed) }
    static func _testResetRenderWork() { _renderWork.store(0, ordering: .relaxed) }
    #endif
}
