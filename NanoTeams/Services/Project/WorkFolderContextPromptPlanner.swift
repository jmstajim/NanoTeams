import Foundation
import Synchronization

/// Pure, `nonisolated` policy that sizes the one-shot work-folder-context
/// prompt to the loaded model's context window. Owns BOTH the token-budget
/// math AND the user-message formatting (moved here out of
/// `WorkFolderContextService`) so the budget is always measured against the
/// exact string that ships — the format and the trimming can never drift.
///
/// House pattern: `PlanningPhasePolicy` / `TeamSwitchPlanner` — pure static
/// funcs, no UI, unit-tested without rendering. Constants live here next to
/// their single consumer (Information Expert).
///
/// Reduction order when the full input overflows the budget:
///   1. Header (`Work folder name`, `File types`) — never trimmed.
///   2. File list — collapse large directories into aggregate lines, then
///      tail-truncate with an exact-count marker (no silent drops).
///   3. Excerpts — trim each to its first N lines (floor 50, the user's
///      verbatim primitive), then drop whole excerpts from the end.
nonisolated enum WorkFolderContextPromptPlanner {

    // MARK: - Tuning (single consumer)

    /// Conservative chars-per-token for ASCII (real tokenizers land ~4; 3.5
    /// over-estimates tokens slightly so we under-fill and avoid overflow).
    private static let charsPerTokenASCII = 3.5
    /// Chars-per-token for non-ASCII scalars (Cyrillic/CJK tokenize denser,
    /// so each such char is weighted as MORE token than an ASCII char).
    private static let charsPerTokenNonASCII = 1.5
    /// Assumed context window when the probe is undeterminable — deliberately
    /// small (LM Studio's common default load size) so the no-probe first
    /// guess rarely overflows.
    private static let fallbackContextTokens = 4096
    /// Fraction of the context window we allow the whole request to occupy —
    /// leaves headroom for tokenizer estimation error and server-side overhead.
    private static let utilization = 0.85
    /// Tokens reserved for the model's OWN output. The context doc is a short
    /// summary, so we never reserve the user's full response limit.
    private static let outputReserveTokens = 1024
    /// Hard floor for the derived input budget — even a tiny context gets a
    /// minimal working budget (the excerpt floor may still overshoot it, which
    /// is surfaced via `Composition.atFloor`).
    private static let minInputTokenBudget = 1024
    /// Share of the post-header budget the file list may occupy; the rest goes
    /// to excerpts, and any list under-use flows to excerpts.
    private static let listBudgetShare = 0.35
    /// A directory needs at least this many direct-child file-list entries to
    /// be worth collapsing into a single aggregate line.
    private static let collapseMinFiles = 10
    /// The user's verbatim floor: an excerpt is trimmed to its first N lines,
    /// never fewer than this (or the whole file when it is shorter).
    private static let minExcerptLines = 50
    /// Priority excerpts (README / manifest / entry point) get this multiple
    /// of a fair share of the excerpt budget.
    private static let priorityExcerptWeight = 2.0

    // MARK: - Result

    nonisolated struct Composition: Equatable {
        /// The fully-formatted user message ready to send.
        var userMessage: String
        /// True when the composition is already at its irreducible minimum —
        /// header alone exceeds the budget, or an excerpt had to be emitted at
        /// its line floor beyond its budget share. Halving the budget again
        /// cannot shrink it, so the service must NOT retry; it surfaces the
        /// real context-window error instead.
        var atFloor: Bool
        var trim: TrimSummary
    }

    nonisolated struct TrimSummary: Equatable {
        var collapsedDirs: [String] = []
        /// Exact number of file entries dropped by the tail-truncation marker.
        var truncatedFileCount: Int = 0
        var trimmedExcerptPaths: [String] = []
        var droppedExcerptPaths: [String] = []
    }

    // MARK: - Token estimation

    /// Two-class char→token estimate. ASCII and non-ASCII scalars are weighted
    /// separately so Cyrillic/CJK content is not under-counted. Deterministic;
    /// used for both budget derivation and section measurement so the two agree.
    static func estimateTokens(_ s: String) -> Int {
        let counts = scalarCounts(s)
        return estimateTokens(ascii: counts.ascii, nonAscii: counts.nonAscii)
    }

    /// The single scalar-walking home. The file-list shaper counts each entry
    /// ONCE through here and prices every later decision from the counts via
    /// `estimateTokens(ascii:nonAscii:)` — pricing must never re-walk what it
    /// already counted (the collapse pass used to re-join the whole list per
    /// candidate directory, O(dirs × total chars)).
    static func scalarCounts(_ s: String) -> (ascii: Int, nonAscii: Int) {
        var ascii = 0
        var nonAscii = 0
        for scalar in s.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonAscii += 1 }
        }
        #if DEBUG
        _estimateScalarWork.wrappingAdd(ascii + nonAscii, ordering: .relaxed)
        #endif
        return (ascii, nonAscii)
    }

    #if DEBUG
    /// Work-bound seam for `WorkFolderContextPromptPlannerTests`: total scalars
    /// walked by `scalarCounts` since the last reset. Same shape as
    /// `HarmonyToolCallParsingHelpers._repairFireCount`.
    private static let _estimateScalarWork = Atomic<Int>(0)
    static func _testScalarWork() -> Int { _estimateScalarWork.load(ordering: .relaxed) }
    static func _testResetScalarWork() { _estimateScalarWork.store(0, ordering: .relaxed) }
    #endif

    /// Price a base64 payload WITHOUT walking it.
    ///
    /// The two-class estimate needs the scalar classes, and base64's alphabet
    /// (`A-Z a-z 0-9 + / =`) is ASCII-only by construction — so `ascii` is the
    /// stored UTF-8 length and `nonAscii` is zero, both O(1) on a native String.
    /// No `scalarCounts` walk, and therefore no re-walk (this file's own rule at
    /// `scalarCounts`: pricing must never re-walk what it already counted).
    ///
    /// This exists as ONE function rather than the same two lines at each call
    /// site because the ASCII premise is the load-bearing part: two copies would
    /// be two places for it to be forgotten (CLAUDE.md #91). Its callers are the
    /// two surfaces that price a conversation on every wire request —
    /// `PromptPrefixFingerprint.chainAndTokens` and
    /// `ContextBudgetPolicy.estimateTokens` — where walking a multi-megabyte
    /// screenshot was Θ(requests × payload) across a run.
    ///
    /// Pinned by `PromptPrefixFingerprintTests.testImagePayloadIsPricedWithoutWalkingIt`,
    /// which asserts the ASCII premise as well as the cost.
    static func estimateTokensForBase64(_ base64: String) -> Int {
        estimateTokens(ascii: base64.utf8.count, nonAscii: 0)
    }

    /// The same two-class estimate from pre-counted scalar classes — the formula's
    /// single home. `PromptPrefixFingerprint.chainAndTokens` counts the classes
    /// during its FNV fold (scalars = non-continuation UTF-8 bytes) so pricing and
    /// fingerprinting share one traversal of the conversation instead of three.
    static func estimateTokens(ascii: Int, nonAscii: Int) -> Int {
        let tokens = Double(ascii) / charsPerTokenASCII + Double(nonAscii) / charsPerTokenNonASCII
        return Int(tokens.rounded(.up))
    }

    // MARK: - Budget derivation

    /// Token budget available for the USER message (file list + excerpts),
    /// after reserving the system prompt and the model's output
    /// (`outputReserveTokens` — the server decides the actual generation cap).
    /// - Parameters:
    ///   - contextTokens: Probed model context window; `nil` → conservative fallback.
    ///   - systemPromptChars: Character count of the system prompt (subtracted).
    static func inputTokenBudget(
        contextTokens: Int?,
        systemPromptChars: Int
    ) -> Int {
        let context = contextTokens ?? fallbackContextTokens
        let systemTokens = Int((Double(systemPromptChars) / charsPerTokenASCII).rounded(.up))
        let budget = Int(Double(context) * utilization) - outputReserveTokens - systemTokens
        return max(minInputTokenBudget, budget)
    }

    // MARK: - Compose

    /// Formats the user message, trimming to fit `tokenBudget`. When the full
    /// input fits, the output is byte-identical to the legacy formatter.
    static func compose(input: WorkFolderContextInput, tokenBudget: Int) -> Composition {
        var trim = TrimSummary()

        // 1. Header — always ships.
        let headerLines = headerLines(input)
        let headerTokens = estimateTokens(headerLines.joined(separator: "\n"))

        // Fast path: does everything fit as-is? Keep byte-identical legacy output.
        let fullLines = headerLines + fullListLines(input) + fullExcerptLines(input)
        let fullMessage = fullLines.joined(separator: "\n")
        if estimateTokens(fullMessage) <= tokenBudget {
            return Composition(userMessage: fullMessage, atFloor: false, trim: trim)
        }

        let remaining = tokenBudget - headerTokens
        guard remaining > 0 else {
            // Header alone exceeds the budget — irreducible.
            return Composition(
                userMessage: headerLines.joined(separator: "\n"),
                atFloor: true,
                trim: trim
            )
        }

        // 2. File list within its share; under-use flows to excerpts.
        let listBudget = Int(Double(remaining) * listBudgetShare)
        let listResult = shapeFileList(input, budget: listBudget)
        trim.collapsedDirs = listResult.collapsedDirs
        trim.truncatedFileCount = listResult.truncatedFileCount

        // 3. Excerpts get the remainder (list under-use included).
        let excerptBudget = remaining - listResult.tokenCost
        let excerptResult = shapeExcerpts(input.excerpts, budget: excerptBudget)
        trim.trimmedExcerptPaths = excerptResult.trimmedPaths
        trim.droppedExcerptPaths = excerptResult.droppedPaths

        var lines = headerLines
        lines += listResult.lines
        lines += excerptResult.lines

        return Composition(
            userMessage: lines.joined(separator: "\n"),
            atFloor: excerptResult.atFloor,
            trim: trim
        )
    }

    // MARK: - Header

    private static func headerLines(_ input: WorkFolderContextInput) -> [String] {
        var lines = ["Work folder name: \(input.rootName)"]
        if !input.fileTypeCounts.isEmpty {
            let sorted = input.fileTypeCounts.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            let top = sorted.prefix(8).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            if !top.isEmpty {
                lines.append("File types: \(top)")
            }
        }
        return lines
    }

    // MARK: - Full (legacy) sections

    private static func fullListLines(_ input: WorkFolderContextInput) -> [String] {
        guard !input.fileList.isEmpty else { return [] }
        return ["File snapshot:"] + input.fileList.map { "- \($0)" }
    }

    private static func fullExcerptLines(_ input: WorkFolderContextInput) -> [String] {
        guard !input.excerpts.isEmpty else { return [] }
        var lines = ["", "Excerpts:"]
        for excerpt in input.excerpts {
            lines.append("File: \(excerpt.path)")
            lines.append("```")
            lines.append(excerpt.content)
            lines.append("```")
        }
        return lines
    }

    // MARK: - File list shaping

    private nonisolated struct ListEntry {
        var text: String
        /// Number of real files this line represents (1 for a plain entry,
        /// N for a collapsed-directory aggregate).
        var fileCount: Int
    }

    private nonisolated struct ListResult {
        var lines: [String]
        var tokenCost: Int
        var collapsedDirs: [String]
        var truncatedFileCount: Int
    }

    /// Shapes the file list to the budget. Each line's scalars are counted ONCE;
    /// every later pricing decision is O(1) arithmetic over the counts — the old
    /// shape re-joined and re-walked the WHOLE list per collapse candidate
    /// (O(dirs × total chars)) and rebuilt the entry array per collapse, and the
    /// "file-list snapshot cap upstream" its acceptance leaned on never existed.
    ///
    /// Two rounding schemes, both historical and both load-bearing for the
    /// byte-identical pins: the collapse loop and `tokenCost` price the list as
    /// ONE `estimateTokens` call over the join (single rounding, maintained as
    /// running class totals); the tail-truncation pass prices each line with its
    /// OWN `estimateTokens` call (per-line rounding), reproduced through the
    /// `(ascii:nonAscii:)` overload — value-identical to
    /// `estimateTokens("\n" + text)`, the newline being one ASCII scalar.
    private static func shapeFileList(_ input: WorkFolderContextInput, budget: Int) -> ListResult {
        guard !input.fileList.isEmpty else {
            return ListResult(lines: [], tokenCost: 0, collapsedDirs: [], truncatedFileCount: 0)
        }

        let lineTexts = input.fileList.map { "- \($0)" }
        let lineCounts = lineTexts.map { scalarCounts($0) }
        let headerCounts = scalarCounts("File snapshot:")

        // Running class totals of the CURRENT list: header + "\n"-joined lines.
        var ascii = headerCounts.ascii
        var nonAscii = headerCounts.nonAscii
        for counts in lineCounts {
            ascii += 1 + counts.ascii
            nonAscii += counts.nonAscii
        }
        func currentCost() -> Int { estimateTokens(ascii: ascii, nonAscii: nonAscii) }

        // Collapse large directories, largest first, until it fits — DECISIONS
        // only; the entry array is materialized once afterwards. Children of
        // distinct directories are disjoint (each path has one immediate
        // parent), which is why the old per-collapse `inserted` guard holds for
        // free here.
        let childrenByParent = Dictionary(
            grouping: input.fileList.indices, by: { immediateParent(of: input.fileList[$0]) })
        var collapsedDirs: [String] = []
        var collapsedSet: Set<String> = []
        var aggregates: [String: (text: String, counts: (ascii: Int, nonAscii: Int), fileCount: Int)] = [:]
        if currentCost() > budget {
            for dir in collapseCandidates(input.fileList) {
                if currentCost() <= budget { break }
                guard let childIndices = childrenByParent[dir], !childIndices.isEmpty else { continue }
                let text = aggregateLine(dir: dir, children: childIndices.map { input.fileList[$0] })
                let aggCounts = scalarCounts(text)
                for i in childIndices {
                    ascii -= 1 + lineCounts[i].ascii
                    nonAscii -= lineCounts[i].nonAscii
                }
                ascii += 1 + aggCounts.ascii
                nonAscii += aggCounts.nonAscii
                collapsedDirs.append(dir)
                collapsedSet.insert(dir)
                aggregates[dir] = (text, aggCounts, childIndices.count)
            }
        }

        // Materialize once — each aggregate lands at its FIRST child's position,
        // exactly where the old per-collapse rebuild inserted it.
        var entries: [ListEntry] = []
        var entryCounts: [(ascii: Int, nonAscii: Int)] = []
        entries.reserveCapacity(input.fileList.count)
        entryCounts.reserveCapacity(input.fileList.count)
        var emitted: Set<String> = []
        for (i, path) in input.fileList.enumerated() {
            let parent = immediateParent(of: path)
            if collapsedSet.contains(parent) {
                guard emitted.insert(parent).inserted, let agg = aggregates[parent] else { continue }
                entries.append(ListEntry(text: agg.text, fileCount: agg.fileCount))
                entryCounts.append(agg.counts)
            } else {
                entries.append(ListEntry(text: lineTexts[i], fileCount: 1))
                entryCounts.append(lineCounts[i])
            }
        }

        // Still over → tail-truncate with an exact-count marker (per-line rounding).
        var truncatedFileCount = 0
        if currentCost() > budget {
            let markerReserve = estimateTokens("- … and 000000 more files (truncated to fit the model's context window)")
            var kept: [ListEntry] = []
            var running = estimateTokens(ascii: headerCounts.ascii, nonAscii: headerCounts.nonAscii)
            var keptAscii = headerCounts.ascii
            var keptNonAscii = headerCounts.nonAscii
            for (entry, counts) in zip(entries, entryCounts) {
                let next = running + estimateTokens(ascii: 1 + counts.ascii, nonAscii: counts.nonAscii)
                if next + markerReserve > budget { break }
                kept.append(entry)
                keptAscii += 1 + counts.ascii
                keptNonAscii += counts.nonAscii
                running = next
            }
            truncatedFileCount = entries[kept.count...].reduce(0) { $0 + $1.fileCount }
            let marker = "- … and \(truncatedFileCount) more files (truncated to fit the model's context window)"
            let markerCounts = scalarCounts(marker)
            kept.append(ListEntry(text: marker, fileCount: 0))
            entries = kept
            ascii = keptAscii + 1 + markerCounts.ascii
            nonAscii = keptNonAscii + markerCounts.nonAscii
        }

        return ListResult(
            lines: ["File snapshot:"] + entries.map(\.text),
            tokenCost: currentCost(),
            collapsedDirs: collapsedDirs,
            truncatedFileCount: truncatedFileCount
        )
    }

    /// Directories (non-root) with `>= collapseMinFiles` direct-child entries,
    /// ordered by child count descending, path ascending for ties.
    private static func collapseCandidates(_ paths: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for path in paths {
            let parent = immediateParent(of: path)
            guard !parent.isEmpty else { continue }
            counts[parent, default: 0] += 1
        }
        return counts
            .filter { $0.value >= collapseMinFiles }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private static func aggregateLine(dir: String, children: [String]) -> String {
        var extCounts: [String: Int] = [:]
        for child in children {
            extCounts[ext(of: child), default: 0] += 1
        }
        let named = extCounts
            .filter { !$0.key.isEmpty }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
        let shown = Array(named.prefix(3))
        let shownFiles = shown.reduce(0) { $0 + $1.value }
        let otherFiles = children.count - shownFiles

        var text = "- \(dir)/ — \(children.count) files"
        if !shown.isEmpty {
            text += ": " + shown.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            if otherFiles > 0 { text += ", +\(otherFiles) other" }
        }
        return text
    }

    // MARK: - Excerpt shaping

    private nonisolated struct ExcerptResult {
        var lines: [String]
        var trimmedPaths: [String]
        var droppedPaths: [String]
        var atFloor: Bool
    }

    private static func shapeExcerpts(
        _ excerpts: [WorkFolderContextInput.FileExcerpt],
        budget: Int
    ) -> ExcerptResult {
        guard !excerpts.isEmpty else {
            return ExcerptResult(lines: [], trimmedPaths: [], droppedPaths: [], atFloor: false)
        }

        var blocks: [[String]] = []
        var trimmedPaths: [String] = []
        var droppedPaths: [String] = []
        var atFloor = false
        var remainingBudget = budget

        for (index, excerpt) in excerpts.enumerated() {
            let isFirst = index == 0
            // Drop the rest once the budget is spent (never emit sub-floor stubs).
            if !isFirst && remainingBudget <= 0 {
                droppedPaths.append(excerpt.path)
                continue
            }

            let allLines = excerpt.content.components(separatedBy: "\n")
            let totalLines = allLines.count
            let fullBlockTokens = estimateTokens(excerptBlock(excerpt, lines: allLines, marker: nil).joined(separator: "\n"))

            let remainingCount = excerpts.count - index
            let fairShare = remainingBudget / max(1, remainingCount)
            let weight = excerpt.isPriority ? priorityExcerptWeight : 1.0
            let allowed = min(fullBlockTokens, Int(Double(fairShare) * weight))

            // How many whole lines fit within `allowed` tokens?
            var takenLines = 0
            var runningTokens = estimateTokens(excerptBlock(excerpt, lines: [], marker: nil).joined(separator: "\n"))
            for line in allLines {
                let next = runningTokens + estimateTokens(line + "\n")
                if next > allowed { break }
                takenLines += 1
                runningTokens = next
            }

            // Floor: first N lines, never fewer than 50 (or the whole file).
            let floorLines = min(minExcerptLines, totalLines)
            if takenLines < floorLines {
                takenLines = floorLines
                atFloor = true // floor overshoots its share — halving budget won't help.
            }

            let selected = Array(allLines.prefix(takenLines))
            let marker: String?
            if takenLines < totalLines {
                trimmedPaths.append(excerpt.path)
                marker = excerpt.wasReadCapped
                    ? "… [truncated: first \(takenLines) lines; file continues]"
                    : "… [truncated: first \(takenLines) of \(totalLines) lines]"
            } else if excerpt.wasReadCapped {
                trimmedPaths.append(excerpt.path)
                marker = "… [truncated: first \(takenLines) lines; file continues]"
            } else {
                marker = nil
            }

            let block = excerptBlock(excerpt, lines: selected, marker: marker)
            blocks.append(block)
            remainingBudget -= estimateTokens(block.joined(separator: "\n"))
        }

        guard !blocks.isEmpty else {
            return ExcerptResult(lines: [], trimmedPaths: trimmedPaths, droppedPaths: droppedPaths, atFloor: atFloor)
        }

        var lines = ["", "Excerpts:"]
        for block in blocks { lines += block }
        if !droppedPaths.isEmpty {
            let note = "Note: \(droppedPaths.count) more excerpts omitted to fit the model's context window: "
                + droppedPaths.joined(separator: ", ")
            lines.append(note)
        }
        return ExcerptResult(lines: lines, trimmedPaths: trimmedPaths, droppedPaths: droppedPaths, atFloor: atFloor)
    }

    private static func excerptBlock(
        _ excerpt: WorkFolderContextInput.FileExcerpt,
        lines: [String],
        marker: String?
    ) -> [String] {
        var block = ["File: \(excerpt.path)", "```"]
        block += lines
        if let marker { block.append(marker) }
        block.append("```")
        return block
    }

    // MARK: - Path helpers

    private static func immediateParent(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }

    private static func lastComponent(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: idx)...])
    }

    private static func ext(of path: String) -> String {
        let name = lastComponent(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}
