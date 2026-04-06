import Foundation

/// Utility for cleaning model-specific tokens that appear in LLM responses.
///
/// Some models (gpt-oss in LM Studio, DeepSeek) emit internal tokens like `<|channel|>`,
/// `<|constrain|>`, `<|message|>` as plain text when their tool calling mechanism fails
/// or in edge cases. This utility strips those tokens from content.
enum ModelTokenCleaner {
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

    private static func stripTokensInPlace(_ content: inout String) {
        while let start = content.range(of: "<|") {
            guard let end = content.range(of: "|>", range: start.upperBound..<content.endIndex) else {
                break
            }
            content.removeSubrange(start.lowerBound..<end.upperBound)
        }
    }

    /// Check if content contains model tokens that should be cleaned.
    ///
    /// - Parameter content: The raw LLM response content
    /// - Returns: True if the content contains `<|...|>` style tokens
    static func containsModelTokens(_ content: String) -> Bool {
        return content.contains("<|") && content.contains("|>")
    }
}
