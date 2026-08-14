import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - write_file

nonisolated struct WriteFileTool: ToolHandler {
    static let name = TN.writeFile
    static let schema = ToolSchema(
        name: TN.writeFile,
        description: "Write content to a file, replacing the entire file (partial content loses the rest). Creates parent directories if needed.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "content": JS.string("Content to write"),
            ],
            required: ["path", "content"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let content = try requiredString(args, "content")
            let createDirs = optionalBool(args, "create_dirs", default: true)

            let fileURL = try resolver.resolveFileURL(relativePath: path)
            let parentDir = fileURL.deletingLastPathComponent()

            var isDir: ObjCBool = false
            let parentExists = fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)

            if !parentExists {
                if createDirs {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                } else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .notADirectory, message: "Parent directory does not exist: \(parentDir.path)"
                    )
                }
            } else if !isDir.boolValue {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notADirectory, message: "Parent path is not a directory"
                )
            }

            let fileExisted = fileManager.fileExists(atPath: fileURL.path)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            struct WriteFileData: Codable {
                var path: String
                var size: Int
                var created: Bool
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: WriteFileData(
                    path: path,
                    size: content.utf8.count,
                    created: !fileExisted
                )
            )
        }
    }
}

// MARK: - edit_file

nonisolated struct EditFileTool: ToolHandler {
    static let name = TN.editFile
    static let schema = ToolSchema(
        name: TN.editFile,
        description: "Replace exact text in a file. `old_text` must match byte-for-byte (whitespace + indentation included).",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "old_text": JS.string("Text to find."),
                "new_text": JS.string("Replacement text."),
                "replace_all": JS.boolean("Replace every occurrence."),
            ],
            required: ["path", "old_text", "new_text"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            // Both stay on `requiredString`, for DIFFERENT reasons. `new_text`
            // because replacing a span with nothing is how a deletion is spelled.
            // `old_text` because the fallback below already diagnoses an empty
            // anchor better than a generic emptiness guard could — measured, the
            // envelope carries `old_text is whitespace-only — anchor on adjacent
            // non-blank lines instead`, which prescribes the recovery. Adding
            // "must not be empty" ahead of it would replace a specific diagnosis
            // with a vaguer one.
            let oldText = try requiredString(args, "old_text")
            let newText = try requiredString(args, "new_text")
            let replaceAll = optionalBool(args, "replace_all", default: false)

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound, message: "File not found: \(path)"
                )
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)

            // Each repair is paired with the replacement it belongs to, and a repaired
            // anchor is only ever used together with its repaired replacement.
            // A model that pasted the `read_lines` gutter (or JSON-escaped its slashes)
            // into `old_text` pasted it into `new_text` too — that is the same habit,
            // one call apart — so repairing only the anchor located the right region
            // and then wrote the gutter INTO the file under `ok:true`. The pairing is
            // also why the repair stays conditional: a replacement that legitimately
            // contains `│` or `\/` and needed no repair to match is spliced verbatim.
            let stripped = Self.stripLineNumberPrefixes(oldText)
            let unescaped = Self.unescapeJSONSequences(oldText)
            var candidates = [EditCandidate(old: oldText, new: newText)]
            if !stripped.isEmpty && stripped != oldText {
                candidates.append(EditCandidate(old: stripped, new: Self.stripLineNumberPrefixes(newText)))
            }
            if unescaped != oldText {
                candidates.append(EditCandidate(old: unescaped, new: Self.unescapeJSONSequences(newText)))
            }

            let newContent: String
            let count: Int
            var matchedIgnoringTrailingWhitespace = false
            // Selection goes through range(of:) — the same primitive the
            // single-replacement arm splices with — so "located but could not be
            // replaced" is unrepresentable. The previous shape selected via
            // contains() and re-searched, which needed a defensive arm for the two
            // primitives disagreeing; measured (macOS 26, NFC anchor over NFD
            // content) they agree, and if a future Foundation ever splits them,
            // a range miss now falls through to the tolerant path's honest
            // anchorNotFound instead of an unactionable "Internal error".
            var selected: (winner: EditCandidate, range: Range<String.Index>)?
            for candidate in candidates {
                if let range = content.range(of: candidate.old) {
                    selected = (candidate, range)
                    break
                }
            }
            if let (winner, range) = selected {
                if replaceAll {
                    count = content.components(separatedBy: winner.old).count - 1
                    newContent = content.replacingOccurrences(of: winner.old, with: winner.new)
                } else {
                    count = 1
                    newContent = content.replacingCharacters(in: range, with: winner.new)
                }
            } else {
                switch Self.whitespaceTolerantEdit(
                    content: content, candidates: candidates, replaceAll: replaceAll
                ) {
                case .replaced(let replacedContent, let replacedCount):
                    newContent = replacedContent
                    count = replacedCount
                    matchedIgnoringTrailingWhitespace = true
                case .ambiguous(let matchCount):
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .anchorAmbiguous,
                        message: "old_text matches \(matchCount) regions when ignoring trailing whitespace — include more surrounding lines to disambiguate."
                    )
                case .notFound(let hint):
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .anchorNotFound,
                        message: hint.map { Self.anchorNotFoundMessage + " " + $0 } ?? Self.anchorNotFoundMessage,
                        details: hint.map { ["hint": $0] }
                    )
                }
            }

            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)

            struct EditFileData: Codable {
                var path: String
                var replacements_made: Int
                // Disclosed only when the fuzzy fallback fired, so the model knows
                // the file's bytes differed from its anchor (nil → omitted from JSON).
                var matched_ignoring_trailing_whitespace: Bool?
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: EditFileData(
                    path: path, replacements_made: count,
                    matched_ignoring_trailing_whitespace: matchedIgnoringTrailingWhitespace ? true : nil
                )
            )
        }
    }

    /// Matches the `read_lines` gutter forms: `6\t`, `6   │ `, `6  | `.
    /// Compiled once — the pattern is a literal, so `try!` either always succeeds
    /// or fails every test run; it cannot ship broken. NSRegularExpression is
    /// immutable and documented thread-safe (same idiom as the shared
    /// ISO8601DateFormatter statics).
    nonisolated(unsafe) private static let lineNumberPrefixPattern = try! NSRegularExpression(
        pattern: #"^\d+(\t|\s*[\x{2502}|]\s?)"#
    )

    /// Strips line-number prefixes from each line of text.
    /// Handles formats: `6\t`, `6   │ `, `6  | ` (from read_lines output).
    /// Only strips if ALL non-empty lines match the prefix pattern to avoid false
    /// positives — one pass: build the stripped lines while checking, and bail
    /// with the original text on the first non-matching non-empty line.
    private static func stripLineNumberPrefixes(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var sawNonEmptyLine = false
        var stripped: [String] = []
        stripped.reserveCapacity(lines.count)
        for line in lines {
            guard !line.isEmpty else {
                stripped.append(line)
                continue
            }
            sawNonEmptyLine = true
            let range = NSRange(line.startIndex..., in: line)
            guard let match = lineNumberPrefixPattern.firstMatch(in: line, range: range) else {
                return text
            }
            stripped.append(String(line[Range(match.range, in: line)!.upperBound...]))
        }
        guard sawNonEmptyLine else { return text }
        return stripped.joined(separator: "\n")
    }

    /// Unescapes common JSON escape sequences that LLMs copy from read_file output.
    private static func unescapeJSONSequences(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: Whitespace-tolerant fallback

    /// An anchor spelling paired with the replacement that belongs to it.
    ///
    /// The two anchor repairs (`stripLineNumberPrefixes`, `unescapeJSONSequences`) are applied to
    /// BOTH sides or neither, so a repair that located the region can never leave its own artefact
    /// in the file. Keeping them in one value is what makes that inseparable — the tolerant path
    /// picks its winner by index, several frames away from the caller that built the list, and a
    /// bare `[String]` of anchors beside a single `newText` is exactly how the two came apart.
    nonisolated struct EditCandidate {
        let old: String
        let new: String
    }

    enum TolerantEditOutcome {
        /// `count` is always >= 1 — a zero-match scan returns `.notFound` instead.
        case replaced(newContent: String, count: Int)
        /// The anchor trailing-trim-matched `count` (> 1) regions with replace_all off:
        /// it needs MORE surrounding lines, not a character-level correction.
        case ambiguous(count: Int)
        /// No window matched; `hint` carries a specific diagnosis when one exists
        /// (leading-whitespace (indentation) mismatch, whitespace-only anchor,
        /// anchor longer than file).
        case notFound(hint: String?)
    }

    static let anchorNotFoundMessage = "old_text not found in file. Make sure it matches exactly including whitespace and indentation. Do not include line numbers from read_lines output."

    /// Last-resort anchor matching for old_text that differs from the file only in
    /// trailing whitespace (including the CR of CRLF line endings) — in either
    /// direction: whitespace dirt in the file is invisible in read output, and
    /// whitespace the model hallucinated into its own anchor is equally invisible
    /// to it. Whole-line windows only; leading whitespace stays significant (a
    /// leading-whitespace (indentation) mismatch is diagnosed in the hint, never
    /// auto-edited). A trailing newline on the anchor is a line terminator (see
    /// `splitAnchorLines`) and the same semantics are mirrored onto `newText` —
    /// notably, an empty `newText` then deletes the matched lines rather than
    /// leaving a blank line. Replacement lines adopt `\r` endings when the
    /// matched window is CRLF, so the file's line-ending convention survives.
    static func whitespaceTolerantEdit(
        content: String, candidates: [EditCandidate], replaceAll: Bool
    ) -> TolerantEditOutcome {
        let contentLines = content.components(separatedBy: "\n")
        // `components(separatedBy:)` on content ending in a newline leaves a trailing
        // "" that marks the terminator — it is not a line, and the longer-than-file
        // diagnostic below already excludes it. `windowMatches` used to count it as
        // matchable, so an anchor carrying a blank line the file does NOT have matched
        // the sentinel and consumed the file's final newline under `ok:true`. The same
        // phantom line cannot be "not a line" for counting and "a line" for matching.
        let scanBound = contentLines.last == "" ? contentLines.count - 1 : contentLines.count
        // A whitespace-only anchor would match any blank run anywhere — refuse it.
        let lineCandidates: [(lines: [String], hadTerminator: Bool, newText: String)] = candidates
            .map { candidate in
                let split = splitAnchorLines(candidate.old)
                return (lines: split.lines, hadTerminator: split.hadTerminator, newText: candidate.new)
            }
            .filter { candidate in
                candidate.lines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }

        if lineCandidates.isEmpty {
            return .notFound(hint: "old_text is whitespace-only — anchor on adjacent non-blank lines instead.")
        }

        var ambiguousCount: Int?
        for (index, candidate) in lineCandidates.enumerated() {
            let (oldLines, hadTerminator, newText) = candidate
            let matches = windowMatches(
                contentLines: contentLines, oldLines: oldLines, scanBound: scanBound, trim: trimTrailing)
            guard !matches.isEmpty else { continue }
            if !replaceAll && matches.count > 1 {
                // Index 0 is the model's literal anchor: it demonstrably exists in
                // several places, so editing a TRANSFORMED variant's unique match
                // instead would be a wrong-location guess — terminal ambiguity.
                // A transformed candidate (gutter-stripped / unescaped) exists to
                // repair an ABSENT anchor; its ambiguity is recorded and the next
                // candidate may still match uniquely.
                if index == 0 { return .ambiguous(count: matches.count) }
                if ambiguousCount == nil { ambiguousCount = matches.count }
                continue
            }
            var lines = contentLines
            let rawNewLines: [String]
            if hadTerminator {
                // Mirror the anchor's terminator semantics on the replacement side:
                // empty new_text deletes the matched lines outright, and a trailing
                // newline on new_text doesn't insert a blank line.
                rawNewLines = newText.isEmpty ? [] : splitAnchorLines(newText).lines
            } else {
                rawNewLines = newText.components(separatedBy: "\n")
            }
            // Line endings are the TOOL's business (see the reattach below), so whatever
            // convention the model happened to emit is normalised away first. Without
            // this, `read_file` — which returns a CRLF file's bytes verbatim — hands the
            // model `\r\n`, it echoes `\r\n` back, and the CRLF reattach appends a SECOND
            // `\r`, writing `\r\r\n`. That is not a valid line ending, and it shipped
            // under `ok:true` with no disclosure.
            let newLines = rawNewLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            let windows = replaceAll ? matches : [matches[0]]
            for start in windows.reversed() {
                let windowRange = start..<(start + oldLines.count)
                // Preserve the file's line-ending convention: a CRLF window keeps
                // CRLF after the edit (the model can't see line endings, so it
                // can't be asked to carry the \r itself).
                let windowIsCRLF = contentLines[windowRange].allSatisfy { $0.hasSuffix("\r") }
                let splice = windowIsCRLF ? newLines.map { $0 + "\r" } : newLines
                lines.replaceSubrange(windowRange, with: splice)
            }
            return .replaced(newContent: lines.joined(separator: "\n"), count: windows.count)
        }

        if let ambiguousCount {
            return .ambiguous(count: ambiguousCount)
        }

        for (oldLines, _, _) in lineCandidates {
            let matches = windowMatches(
                contentLines: contentLines, oldLines: oldLines, scanBound: scanBound, trim: trimBoth)
            guard !matches.isEmpty else { continue }
            let lineList = matches.prefix(3).map { String($0 + 1) }.joined(separator: ", ")
            let plural = matches.count > 1 ? "s" : ""
            return .notFound(hint: "Lines match ignoring indentation near line\(plural) \(lineList) — check leading whitespace (tabs vs spaces).")
        }

        // Don't count the split sentinel after the file's final newline as a line —
        // the same rule `scanBound` applies when matching.
        let fileLineCount = scanBound
        if lineCandidates.allSatisfy({ $0.lines.count > fileLineCount }) {
            return .notFound(hint: "old_text has more lines (\(lineCandidates[0].lines.count)) than the file (\(fileLineCount)).")
        }

        return .notFound(hint: nil)
    }

    /// Splits anchor/replacement text on "\n". A trailing newline is a line
    /// TERMINATOR (the model copied whole lines), not a request to match or
    /// insert a blank line — drop it and report so the replacement can mirror it.
    private static func splitAnchorLines(_ text: String) -> (lines: [String], hadTerminator: Bool) {
        var lines = text.components(separatedBy: "\n")
        guard lines.count > 1, lines.last == "" else { return (lines, false) }
        lines.removeLast()
        return (lines, true)
    }

    /// Start indices of greedy, leftmost non-overlapping line windows in `contentLines`
    /// whose lines all equal `oldLines` after per-line `trim` (after a match at `i`,
    /// scanning resumes at `i + n` — replace_all results depend on this selection).
    private static func windowMatches(
        contentLines: [String], oldLines: [String], scanBound: Int, trim: (String) -> String
    ) -> [Int] {
        let n = oldLines.count
        guard n > 0, scanBound >= n else { return [] }
        let trimmedOld = oldLines.map(trim)
        let trimmedContent = contentLines.map(trim)
        var matches: [Int] = []
        var i = 0
        while i + n <= scanBound {
            var isMatch = true
            for j in 0..<n where trimmedOld[j] != trimmedContent[i + j] {
                isMatch = false
                break
            }
            if isMatch {
                matches.append(i)
                i += n
            } else {
                i += 1
            }
        }
        return matches
    }

    /// Includes CR so CRLF files compare cleanly after splitting on "\n".
    private static let trailingWhitespace = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))

    private static func trimTrailing(_ line: String) -> String {
        var sub = line[...]
        while let last = sub.last, last.unicodeScalars.allSatisfy(trailingWhitespace.contains) {
            sub.removeLast()
        }
        return String(sub)
    }

    private static func trimBoth(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - delete_file

nonisolated struct DeleteFileTool: ToolHandler {
    static let name = TN.deleteFile
    static let schema = ToolSchema(
        name: TN.deleteFile,
        description: "Delete a file.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "must_exist": JS.boolean("Fail if file does not exist"),
            ],
            required: ["path"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let mustExist = optionalBool(args, "must_exist", default: true)

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir)

            struct DeleteData: Codable {
                var path: String
                var deleted: Bool
            }

            if !exists {
                if mustExist {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .fileNotFound, message: "File not found: \(path)"
                    )
                } else {
                    return makeSuccessResult(
                        toolName: Self.name, args: args,
                        data: DeleteData(path: path, deleted: false)
                    )
                }
            }

            if isDir.boolValue {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notAFile, message: "Path is a directory: \(path)"
                )
            }

            try fileManager.removeItem(at: fileURL)

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: DeleteData(path: path, deleted: true)
            )
        }
    }
}
