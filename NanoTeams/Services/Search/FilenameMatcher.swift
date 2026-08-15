import Foundation

/// Stateless matcher that finds files whose name or relative path matches a
/// set of query terms. Used by both the plain `SearchTool` path (against the
/// FS-walked file roster) and the exploratory-search path (against
/// `SearchIndex.files`) so basename/path-match semantics live in exactly one
/// place.
///
/// Inputs are assumed pre-filtered by `WalkSkipRules` and the internal-dir
/// exclusion — both call sites already apply them upstream. Keeping this
/// matcher free of FS knowledge is what makes it trivially unit-testable.
nonisolated enum FilenameMatcher {

    /// For each candidate path, succeeds when ANY query term matches the
    /// basename or full relative path:
    /// - If the term contains `*` → case-insensitive glob anchored to the
    ///   candidate (basename first, then full path).
    /// - Otherwise → `localizedCaseInsensitiveContains` against basename then
    ///   full path.
    ///
    /// Returns at most `limit` results. Basename hits sort before path-only
    /// hits; ties broken lexicographically. Dedupes by path so a candidate
    /// matching multiple query terms only appears once.
    ///
    /// Empty / whitespace-only query terms are skipped — the expand pipeline
    /// passes the original literal query alongside its tokens, and a literal
    /// like `"team meeting"` would otherwise be a substring nobody types.
    static func match(
        candidates: [String],
        queries: [String],
        limit: Int
    ) -> [FilenameMatch] {
        guard limit > 0 else { return [] }
        let cleanQueries = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanQueries.isEmpty else { return [] }

        // Prepare each query ONCE. The old shape re-derived this per candidate: a `*`-bearing
        // query re-compiled an `NSRegularExpression` for every path, and a plain one went through
        // `localizedCaseInsensitiveContains` twice (basename, then full path) — 2 × candidates ×
        // queries ICU calls, ~44 ms per query on a 1500-file roster and ~1.2 s on the
        // exploratory path's 31 terms.
        let prepared: [PreparedQuery] = cleanQueries.map(PreparedQuery.init)
        let asciiFoldOK = LineScanner.asciiFoldMatchesLocale

        var seen: Set<String> = []
        var basenameHits: [FilenameMatch] = []
        var pathHits: [FilenameMatch] = []

        for path in candidates {
            guard !seen.contains(path) else { continue }

            // The basename is a contiguous suffix of the path, so its byte offset is enough —
            // no `NSString` bridge and no substring allocation.
            let basenameOffset = path.utf8.lastIndex(of: UInt8(ascii: "/"))
                .map { path.utf8.index(after: $0) } ?? path.utf8.startIndex
            let basenameStart = path.utf8.distance(from: path.utf8.startIndex, to: basenameOffset)

            var basenameMatched = false
            var pathMatched = false
            for query in prepared {
                if query.matches(path: path, fromByteOffset: basenameStart, asciiFoldOK: asciiFoldOK) {
                    basenameMatched = true
                    break
                }
                if !pathMatched,
                   query.matches(path: path, fromByteOffset: 0, asciiFoldOK: asciiFoldOK) {
                    pathMatched = true
                }
            }

            if basenameMatched {
                basenameHits.append(FilenameMatch(path: path, matched_on: .basename))
                seen.insert(path)
            } else if pathMatched {
                pathHits.append(FilenameMatch(path: path, matched_on: .path))
                seen.insert(path)
            }
        }

        basenameHits.sort { $0.path < $1.path }
        pathHits.sort { $0.path < $1.path }

        var combined = basenameHits
        combined.append(contentsOf: pathHits)
        if combined.count > limit {
            combined.removeLast(combined.count - limit)
        }
        return combined
    }

    /// Roster mode: return every candidate (deduped, lexicographically sorted,
    /// capped at `limit`) as a `.basename` match. Used by the empty-query "list
    /// files" path in `SearchExecutor`, where the walk has already glob-filtered
    /// the candidates and there is no query term to match against — so every
    /// visited path is, by construction, a hit.
    ///
    /// Kept separate from `match(...)` on purpose: that matcher's "skip empty
    /// query terms" contract (`:34-37`) is load-bearing for the exploratory
    /// path (which always carries a non-empty original query). Folding "empty
    /// query = match all" into `match` would silently widen it there.
    static func matchAll(candidates: [String], limit: Int) -> [FilenameMatch] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var hits: [FilenameMatch] = []
        for path in candidates {
            guard seen.insert(path).inserted else { continue }
            hits.append(FilenameMatch(path: path, matched_on: .basename))
        }
        hits.sort { $0.path < $1.path }
        if hits.count > limit {
            hits.removeLast(hits.count - limit)
        }
        return hits
    }

    // MARK: - Private

    /// One query term, with its glob compiled and its bytes folded up front.
    private struct PreparedQuery {
        let original: String
        /// Non-nil when the term contains `*`. Compiled once, not once per candidate.
        let glob: CompiledGlob?
        let needle: LineScanner.CompiledNeedle

        init(_ query: String) {
            original = query
            glob = query.contains("*")
                ? try? CompiledGlob(glob: query, caseInsensitive: true)
                : nil
            needle = LineScanner.CompiledNeedle(query)
        }

        /// Matches against `path` starting at `byteOffset` — 0 for the whole relative path, or
        /// the basename's offset to test just the last component.
        ///
        /// Same fast/slow split as the content scanner: the byte path is authoritative only when
        /// BOTH sides are pure ASCII, because ICU folds `ß`→`ss` and U+212A→`k` and treats
        /// `e`+combining-acute as a single non-`e` grapheme.
        func matches(path: String, fromByteOffset byteOffset: Int, asciiFoldOK: Bool) -> Bool {
            if let glob {
                // Globs stay on the regex path — anchoring makes a byte scan inapplicable.
                let candidate = byteOffset == 0 ? path : String(suffixBytes(of: path, from: byteOffset))
                return glob.matches(candidate)
            }
            if needle.isEmpty { return false }

            if needle.isASCII, asciiFoldOK {
                var matched: Bool?
                path.utf8.withContiguousStorageIfAvailable { buf in
                    guard let base = buf.baseAddress, byteOffset <= buf.count else { return }
                    // Non-ASCII anywhere in the compared region ⇒ defer to ICU. Asked through
                    // `LineScanner`, so the rule for "which bytes force ICU" has ONE owner and
                    // cannot drift from the content scanner's copy of the same decision.
                    var i = byteOffset
                    while i < buf.count {
                        if LineScanner.leadByteNeedsICU(base[i]) { return }
                        i += 1
                    }
                    matched = needle.foldedBytes.withUnsafeBufferPointer { nb in
                        LineScanner.asciiContains(
                            haystack: base + byteOffset, count: buf.count - byteOffset,
                            needle: nb.baseAddress!, needleCount: nb.count)
                    }
                }
                if let matched { return matched }
            }

            let candidate = byteOffset == 0 ? path : String(suffixBytes(of: path, from: byteOffset))
            return candidate.localizedCaseInsensitiveContains(original)
        }

        /// A path is always valid UTF-8 and `byteOffset` always lands just after a `/`, so the
        /// suffix is a well-formed scalar boundary.
        private func suffixBytes(of path: String, from byteOffset: Int) -> Substring {
            let idx = path.utf8.index(path.utf8.startIndex, offsetBy: byteOffset)
            return Substring(path.utf8[idx...])
        }
    }
}

/// Anchored `*`-only glob compiler shared by `FilenameMatcher` and
/// `SearchExecutor`'s `file_glob` filter. Lifted out of `SearchExecutor` so
/// the case-insensitive variant has one home and behavior is consistent
/// across both call sites.
/// A `*`-only glob compiled ONCE, then matched many times.
///
/// Exists because the removed `GlobMatcher.matches(name:glob:)` escaped, rewrote and
/// re-compiled an `NSRegularExpression` on every single call — and `SearchExecutor` called it once
/// per walked file (via `input.fileGlob ?? "*"`, so even when the caller supplied no glob at all),
/// while `FilenameMatcher` called it once per candidate per query.
nonisolated struct CompiledGlob {
    private let regex: NSRegularExpression

    /// Sentinel reserved for tests that need the invalid-glob path deterministically.
    ///
    /// The rejection comes from the explicit `throw` below and NOTHING else — that guard is
    /// load-bearing, not belt-and-braces. The doc here used to claim "a leading null byte trips
    /// `NSRegularExpression(pattern:options:)`"; measured on this toolchain it does not (nor do
    /// `\Q`/`\E`, 5000 stars, or U+FFFF — `escapedPattern(for:)` neutralises everything, so no
    /// glob string is known to fail the compile). Delete the guard on the strength of that old
    /// claim and the sentinel silently becomes a glob that COMPILES and matches nothing: every
    /// invalid-glob test would still pass while asserting nothing.
    /// The trailing `*` is load-bearing too, and for a different reason: `PreparedQuery.init`
    /// only compiles a glob when the term `contains("*")`, so a starless sentinel never reached
    /// this type from `FilenameMatcher.match` at all — `testGlob_uncompilablePattern_failsClosed`
    /// was passing because the substring needle happened to match nothing, i.e. for a reason
    /// unrelated to the branch it names.
    ///
    /// Pinned by `ESearchFilenameMatcherTailTests`.
    #if DEBUG
    static let _testUncompilableGlobSentinel = "\0__bad_glob__*"
    #endif

    /// Only `*` is a wildcard; every other metacharacter is escaped, so `Foo.swift` matches
    /// literally and `*.swift` matches by extension.
    init(glob: String, caseInsensitive: Bool) throws {
        #if DEBUG
        if glob == Self._testUncompilableGlobSentinel {
            throw SearchExecutorError.invalidFileGlob(
                pattern: glob, message: "test sentinel — pattern intentionally rejected"
            )
        }
        #endif
        let escaped = NSRegularExpression.escapedPattern(for: glob)
        let pattern = escaped.replacingOccurrences(of: "\\*", with: ".*")
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: "^\(pattern)$", options: options)
        } catch {
            throw SearchExecutorError.invalidFileGlob(
                pattern: glob, message: error.localizedDescription
            )
        }
    }

    func matches(_ name: String) -> Bool {
        regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) != nil
    }
}
