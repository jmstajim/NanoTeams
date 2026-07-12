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

        var seen: Set<String> = []
        var basenameHits: [FilenameMatch] = []
        var pathHits: [FilenameMatch] = []

        for path in candidates {
            guard !seen.contains(path) else { continue }

            let basename = (path as NSString).lastPathComponent

            var basenameMatched = false
            var pathMatched = false
            for query in cleanQueries {
                if matches(query: query, against: basename) {
                    basenameMatched = true
                    break
                }
                if !pathMatched, matches(query: query, against: path) {
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

    private static func matches(query: String, against candidate: String) -> Bool {
        if query.contains("*") {
            return GlobMatcher.matches(name: candidate, glob: query, caseInsensitive: true)
        }
        return candidate.localizedCaseInsensitiveContains(query)
    }
}

/// Anchored `*`-only glob compiler shared by `FilenameMatcher` and
/// `SearchExecutor`'s `file_glob` filter. Lifted out of `SearchExecutor` so
/// the case-insensitive variant has one home and behavior is consistent
/// across both call sites.
nonisolated enum GlobMatcher {

    /// Sentinel that intentionally fails to compile — reserved for tests
    /// that need to exercise the regex-failure branch deterministically.
    /// Leading null byte trips `NSRegularExpression(pattern:options:)`.
    #if DEBUG
    static let _testUncompilableGlobSentinel = "\0__bad_glob__"
    #endif

    /// Returns `true` when `name` fully matches `glob`. Only `*` is treated
    /// as a wildcard; every other metacharacter is escaped, so a user-
    /// supplied `Foo.swift` matches literally and `*.swift` matches by
    /// extension.
    ///
    /// Uncompilable patterns return `false` (fail-closed) — a malformed glob
    /// must not silently widen the search. Callers can recover by supplying
    /// a valid pattern.
    static func matches(name: String, glob: String, caseInsensitive: Bool) -> Bool {
        #if DEBUG
        if glob == _testUncompilableGlobSentinel { return false }
        #endif
        let escaped = NSRegularExpression.escapedPattern(for: glob)
        let pattern = escaped.replacingOccurrences(of: "\\*", with: ".*")
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: options) else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Validates that `glob` is compileable. Throws
    /// `SearchExecutorError.invalidFileGlob` if not — used by `SearchExecutor`
    /// at the start of each run so a bad pattern surfaces as a typed error
    /// instead of an empty result set.
    static func validate(glob: String) throws {
        #if DEBUG
        if glob == _testUncompilableGlobSentinel {
            throw SearchExecutorError.invalidFileGlob(
                pattern: glob, message: "test sentinel — pattern intentionally rejected"
            )
        }
        #endif
        let escaped = NSRegularExpression.escapedPattern(for: glob)
        let pattern = escaped.replacingOccurrences(of: "\\*", with: ".*")
        do {
            _ = try NSRegularExpression(pattern: "^\(pattern)$", options: [])
        } catch {
            throw SearchExecutorError.invalidFileGlob(
                pattern: glob, message: error.localizedDescription
            )
        }
    }
}
