import Foundation

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
        var ascii = 0
        var nonAscii = 0
        for scalar in s.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonAscii += 1 }
        }
        let tokens = Double(ascii) / charsPerTokenASCII + Double(nonAscii) / charsPerTokenNonASCII
        return Int(tokens.rounded(.up))
    }

    // MARK: - Budget derivation

    /// Token budget available for the USER message (file list + excerpts),
    /// after reserving the system prompt and the model's output.
    /// - Parameters:
    ///   - contextTokens: Probed model context window; `nil` → conservative fallback.
    ///   - systemPromptChars: Character count of the system prompt (subtracted).
    ///   - maxOutputTokens: The role's response limit; `<= 0` means "server decides".
    static func inputTokenBudget(
        contextTokens: Int?,
        systemPromptChars: Int,
        maxOutputTokens: Int
    ) -> Int {
        let context = contextTokens ?? fallbackContextTokens
        let outReserve = maxOutputTokens <= 0
            ? outputReserveTokens
            : min(maxOutputTokens, outputReserveTokens)
        let systemTokens = Int((Double(systemPromptChars) / charsPerTokenASCII).rounded(.up))
        let budget = Int(Double(context) * utilization) - outReserve - systemTokens
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

    private static func shapeFileList(_ input: WorkFolderContextInput, budget: Int) -> ListResult {
        guard !input.fileList.isEmpty else {
            return ListResult(lines: [], tokenCost: 0, collapsedDirs: [], truncatedFileCount: 0)
        }

        var entries = input.fileList.map { ListEntry(text: "- \($0)", fileCount: 1) }
        var collapsedDirs: [String] = []

        func cost(_ entries: [ListEntry]) -> Int {
            estimateTokens((["File snapshot:"] + entries.map(\.text)).joined(separator: "\n"))
        }

        // Collapse large directories, largest first, until it fits.
        if cost(entries) > budget {
            for dir in collapseCandidates(input.fileList) {
                if cost(entries) <= budget { break }
                guard let collapsed = collapse(entries, dir: dir, paths: input.fileList) else { continue }
                entries = collapsed
                collapsedDirs.append(dir)
            }
        }

        // Still over → tail-truncate with an exact-count marker.
        var truncatedFileCount = 0
        if cost(entries) > budget {
            let markerReserve = estimateTokens("- … and 000000 more files (truncated to fit the model's context window)")
            var kept: [ListEntry] = []
            var running = estimateTokens("File snapshot:")
            for entry in entries {
                let next = running + estimateTokens("\n" + entry.text)
                if next + markerReserve > budget { break }
                kept.append(entry)
                running = next
            }
            truncatedFileCount = entries[kept.count...].reduce(0) { $0 + $1.fileCount }
            kept.append(ListEntry(
                text: "- … and \(truncatedFileCount) more files (truncated to fit the model's context window)",
                fileCount: 0
            ))
            entries = kept
        }

        return ListResult(
            lines: ["File snapshot:"] + entries.map(\.text),
            tokenCost: cost(entries),
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

    private static func collapse(
        _ entries: [ListEntry],
        dir: String,
        paths: [String]
    ) -> [ListEntry]? {
        // Direct children: "<dir>/<name>" with no further slash.
        let children = paths.filter { immediateParent(of: $0) == dir }
        guard !children.isEmpty else { return nil }

        let aggregate = ListEntry(text: aggregateLine(dir: dir, children: children), fileCount: children.count)

        var result: [ListEntry] = []
        var inserted = false
        for entry in entries {
            let path = String(entry.text.dropFirst(2)) // strip "- "
            if entry.fileCount == 1, immediateParent(of: path) == dir {
                if !inserted {
                    result.append(aggregate)
                    inserted = true
                }
                continue
            }
            result.append(entry)
        }
        // If the direct children weren't plain entries (already collapsed), skip.
        guard inserted else { return nil }
        return result
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
