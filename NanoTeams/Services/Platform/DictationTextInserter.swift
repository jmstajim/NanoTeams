import Foundation

/// Pure logic for applying streaming dictation partials into a target text
/// buffer. Kept free of SwiftUI so the UTF-safe anchor/replace behavior is
/// unit-testable without bringing up a view hierarchy.
///
/// Model: a dictation session owns a range of the target text starting at
/// `anchor` (a `Character` offset fixed when the session starts). On each
/// partial, the range `[anchor ..< anchor + lastLength]` is replaced with the
/// new partial. Text typed BEFORE the anchor is untouched. If the user edits
/// text WITHIN the session range (e.g. deletes characters), the anchor/length
/// pair can become invalid — the function clamps both to `text.count` to avoid
/// crashing and reports whether clamping happened so callers can reset.
enum DictationTextInserter {

    /// Result of applying a partial. `newText` is the updated buffer;
    /// `newLength` is the Character count of the just-applied partial (caller
    /// persists it for the next call); `drifted` is `true` when the input
    /// anchor/lastLength pair had to be clamped — a signal that the user
    /// edited the tail and the caller should reset its anchor.
    struct Outcome: Equatable {
        let newText: String
        let newLength: Int
        let drifted: Bool
    }

    /// - Parameters:
    ///   - partial: the new partial transcript to write into the anchored range.
    ///   - text: the current buffer.
    ///   - anchor: Character offset where the session's inserted region begins.
    ///   - lastLength: Character count of the previously-applied partial
    ///                 (0 on the first call). Used to compute the old end.
    static func apply(
        partial: String,
        to text: String,
        anchor: Int,
        lastLength: Int
    ) -> Outcome {
        let textCount = text.count
        let clampedAnchor = min(max(anchor, 0), textCount)
        let rawOldEnd = clampedAnchor + max(lastLength, 0)
        let clampedOldEnd = min(rawOldEnd, textCount)

        let drifted = clampedAnchor != anchor || clampedOldEnd != rawOldEnd

        let startIdx = text.index(text.startIndex, offsetBy: clampedAnchor)
        let endIdx = text.index(text.startIndex, offsetBy: clampedOldEnd)
        var newText = text
        newText.replaceSubrange(startIdx..<endIdx, with: partial)

        return Outcome(newText: newText, newLength: partial.count, drifted: drifted)
    }
}
