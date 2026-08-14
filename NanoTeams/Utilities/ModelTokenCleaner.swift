import Foundation

/// Utility for cleaning model-specific tokens that appear in LLM responses.
///
/// Some models (gpt-oss in LM Studio, DeepSeek) emit internal tokens like `<|channel|>`,
/// `<|constrain|>`, `<|message|>` as plain text when their tool calling mechanism fails
/// or in edge cases. This utility strips those tokens from content.
nonisolated enum ModelTokenCleaner {
    /// Strip model-specific tokens (e.g. `<|channel|>`, `<|constrain|>`) from content.
    ///
    /// Removes all `<|...|>` style tokens, which are internal to the model and
    /// should never appear in the final output to the user or in tool arguments.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: Content with all `<|...|>` tokens removed, trimmed of whitespace
    static func clean(_ content: String) -> String {
        var c = content
        stripTokensInPlace(&c)
        return c.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip `<|...|>` tokens without trimming whitespace.
    ///
    /// Use during streaming where trailing whitespace must be preserved
    /// because more content is still arriving.
    static func stripTokens(_ content: String) -> String {
        var c = content
        stripTokensInPlace(&c)
        return c
    }

    // MARK: - Private

    /// Longest span a `<|…|>` token may occupy. A sentinel is a short label; the longest
    /// this app has seen is `<|channel|>` at 11. The cap only ever declines to delete.
    private static let maxTokenSpan = 32

    /// Single forward pass building a fresh string — deliberately NOT in-place
    /// `removeSubrange`: skipping a non-token `<|` requires carrying a cursor across the
    /// mutation, and `String.Index` is invalidated by it.
    private static func stripTokensInPlace(_ content: inout String) {
        guard content.contains("<|") else { return }

        var result = ""
        result.reserveCapacity(content.count)
        var cursor = content.startIndex

        while let start = content.range(of: "<|", range: cursor..<content.endIndex) {
            // No closer at all from here on: the original behaviour is to leave the
            // remainder untouched, and a partially-arrived token mid-stream is exactly
            // that case.
            guard let end = content.range(of: "|>", range: start.upperBound..<content.endIndex)
            else { break }

            // An opening `<|` whose own `|>` is missing (observed: gemma-4-e4b's
            // `<|tool_call>`) otherwise pairs with the NEXT token's closer and deletes
            // everything in between — which is how a whole `create_artifact` payload
            // vanished from a turn, leaving the model told it had submitted nothing.
            // A real sentinel is one short token: no payload brace, no line break.
            if isTokenSpan(content, from: start.lowerBound, to: end.upperBound) {
                result.append(contentsOf: content[cursor..<start.lowerBound])
                cursor = end.upperBound
            } else {
                // Keep the `<|` verbatim and resume after it, so a later genuine token in
                // the same string is still stripped — and so `HarmonySentinelNormalizer`
                // can still recognise the mangled sentinel it leaves behind.
                result.append(contentsOf: content[cursor..<start.upperBound])
                cursor = start.upperBound
            }
        }

        result.append(contentsOf: content[cursor...])
        content = result
    }

    /// Whether `[from, to)` is short enough and clean enough to be a sentinel, decided in
    /// at most `maxTokenSpan + 1` steps.
    ///
    /// `Substring.count` is O(length), and the length being compared against a 32-char
    /// bound is unbounded: an opening `<|` with no closer nearby spans the rest of the
    /// buffer, so answering a question decided within the first 33 characters cost a walk
    /// of the whole remainder, once per opener.
    ///
    /// This bounds the ANSWER, not the search. The `range(of: "|>")` above is still an
    /// unbounded forward scan per iteration, so a buffer of k openers sharing one distant
    /// closer remains O(k·n) — measurably cheaper, not asymptotically better. Left as is:
    /// the observed defect is k≈1 per reply (2 of 30, one mangled opener each), and closing
    /// it means bounding that search too, which changes which spans pair with which closer.
    private static func isTokenSpan(
        _ content: String, from: String.Index, to: String.Index
    ) -> Bool {
        var index = from
        var scanned = 0
        while index < to {
            if scanned >= maxTokenSpan { return false }
            let character = content[index]
            if character == "{" || character.isNewline { return false }
            index = content.index(after: index)
            scanned += 1
        }
        return true
    }

    /// Check if content contains model tokens that should be cleaned.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: True if the content contains `<|...|>` style tokens
    static func containsModelTokens(_ content: String) -> Bool {
        return content.contains("<|") && content.contains("|>")
    }
}
