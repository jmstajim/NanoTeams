import Foundation

/// Pure, stateless tokenizer that splits identifiers and text into a set of
/// searchable lowercase tokens.
///
/// Pipeline per raw whitespace/punctuation-split token:
/// 1. Lowercase via `en_US_POSIX` so non-ASCII scripts (Cyrillic) go through an
///    invariant lowercase path — avoids locale-dependent casing quirks.
/// 2. Split camelCase / PascalCase using a Unicode-aware regex that also covers
///    Cyrillic (`\p{Lu}` / `\p{Ll}` match Unicode letter classes).
/// 3. Split snake_case on `_` and dashes.
/// 4. Discard tokens shorter than 2 chars and tokens containing no Unicode
///    letter (this covers pure digits like `42`, punctuation-only runs like
///    `---` that come from Markdown horizontal rules, and mixed digit/dash
///    tokens like `-100000` or `-04-21` that have no semantic value as
///    vocabulary candidates).
enum TokenExtractor {
    /// Minimum token length we keep — 1-char tokens add cardinality without
    /// signal (users don't search for "k" or "x").
    static let minTokenLength = 2

    /// Returns the set of lowercase tokens extracted from `text`.
    static func extractTokens(from text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }

        var result: Set<String> = []
        for raw in text.unicodeScalars.split(whereSeparator: isSeparator) {
            let rawString = String(String.UnicodeScalarView(raw))
            guard rawString.count >= minTokenLength else { continue }

            let lowered = rawString.lowercased(with: Locale(identifier: "en_US_POSIX"))
            insert(lowered, into: &result)

            // snake / dash split on the lowered form
            for piece in lowered.split(whereSeparator: { $0 == "_" || $0 == "-" }) {
                insert(String(piece), into: &result)
            }

            // camelCase / PascalCase split on the *original* cased form so we
            // keep case boundaries. Cast `Substring` pieces to `String` before
            // lowercasing — the regex drops the runs as-is.
            for piece in splitCamel(rawString) {
                insert(piece.lowercased(with: Locale(identifier: "en_US_POSIX")), into: &result)
            }
        }

        return result
    }

    // MARK: - Private

    private static func insert(_ token: String, into set: inout Set<String>) {
        guard token.count >= minTokenLength else { return }
        guard containsLetter(token) else { return }
        set.insert(token)
    }

    /// True when the token contains at least one Unicode letter. Rejects pure
    /// digits (`42`), punctuation-only runs (`---`), and mixed digit/dash
    /// tokens (`-100000`, `-04-21`) in one check — all are indexing noise.
    private static func containsLetter(_ token: String) -> Bool {
        token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        // `_` and `-` are intentionally NOT separators here — we want the full
        // snake/dash form (`k_max_size`, `on-file-change`) in the token set for
        // exact-phrase recall. Sub-pieces are handled by the inner split in
        // `extractTokens` on the lowered form.
        if scalar == "_" || scalar == "-" { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        if CharacterSet.punctuationCharacters.contains(scalar) { return true }
        if CharacterSet.symbols.contains(scalar) { return true }
        return false
    }

    /// Splits camelCase / PascalCase runs (including mixed digit runs) into
    /// individual words. Uses NSRegularExpression with Unicode letter classes
    /// so it works for Cyrillic, Greek, etc.
    ///
    /// Pattern explained:
    /// - `\p{Lu}?\p{Ll}+` — optional leading uppercase + lowercase run (`Make`,
    ///   `прокрутка`).
    /// - `\p{Lu}+(?=\p{Lu}\p{Ll}|$|[^\p{Ll}])` — an uppercase run that either
    ///   ends the string, or precedes another capitalized word (e.g. `XMLParser`
    ///   → `XML` + `Parser`).
    /// - `\d+` — digit runs as standalone tokens.
    private static let camelSplitRegex: NSRegularExpression? = {
        let pattern = #"\p{Lu}?\p{Ll}+|\p{Lu}+(?=\p{Lu}\p{Ll}|$|[^\p{Ll}])|\d+"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func splitCamel(_ input: String) -> [String] {
        guard let regex = camelSplitRegex else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        var pieces: [String] = []
        regex.enumerateMatches(in: input, options: [], range: range) { match, _, _ in
            guard let match = match, let r = Range(match.range, in: input) else { return }
            pieces.append(String(input[r]))
        }
        return pieces
    }

    // MARK: - Filename Helpers

    /// Tokenizes a filename: drops the extension and runs `extractTokens` on
    /// the stem. Used alongside content tokens so search can match on name
    /// even when the file's body is unreadable (binary, extraction failed).
    ///
    /// Additionally attempts compound-word splitting against
    /// `knownFilenameStems` so well-known marker files with no delimiters
    /// (`Makefile`, `Dockerfile`, `Rakefile`, `Gemfile`, `Podfile`) still
    /// contribute the constituent words to the index. Precision is fine here
    /// — this path only runs on filenames, not content bodies.
    static func extractFilenameTokens(from url: URL) -> Set<String> {
        let stem = url.deletingPathExtension().lastPathComponent
        var tokens = extractTokens(from: stem)
        for token in Array(tokens) {
            splitKnownCompound(token, into: &tokens)
        }
        return tokens
    }

    /// Marker-filename stems only — not a general English segmenter.
    private static let knownFilenameStems: [String] = [
        "file", "make", "docker", "rake", "gem", "pod", "build",
    ]

    /// Try splitting `token` as `<known-stem> + <rest>` or `<rest> + <known-stem>`
    /// where `<rest>` is also ≥ `minTokenLength`. Inserts both halves on hit.
    private static func splitKnownCompound(_ token: String, into set: inout Set<String>) {
        for stem in knownFilenameStems {
            if token.hasPrefix(stem), token.count >= stem.count + minTokenLength {
                let rest = String(token.dropFirst(stem.count))
                insert(stem, into: &set)
                insert(rest, into: &set)
            }
            if token.hasSuffix(stem), token.count >= stem.count + minTokenLength {
                let rest = String(token.dropLast(stem.count))
                insert(stem, into: &set)
                insert(rest, into: &set)
            }
        }
    }
}
