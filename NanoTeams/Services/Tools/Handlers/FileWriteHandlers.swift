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

            let stripped = Self.stripLineNumberPrefixes(oldText)
            let unescaped = Self.unescapeJSONSequences(oldText)
            var candidates = [oldText]
            if !stripped.isEmpty && stripped != oldText { candidates.append(stripped) }
            if unescaped != oldText { candidates.append(unescaped) }

            let newContent: String
            let count: Int
            var matchedIgnoringTrailingWhitespace = false
            if let effectiveOldText = candidates.first(where: { content.contains($0) }) {
                if replaceAll {
                    count = content.components(separatedBy: effectiveOldText).count - 1
                    newContent = content.replacingOccurrences(of: effectiveOldText, with: newText)
                } else {
                    count = 1
                    guard let range = content.range(of: effectiveOldText) else {
                        // contains() and range(of:) disagreeing would mean a Foundation
                        // behavior change; fail loudly instead of writing the file
                        // unchanged while reporting a successful replacement.
                        return makeErrorResult(
                            toolName: Self.name, args: args,
                            code: .commandFailed,
                            message: "Internal error: old_text was located but could not be replaced. Retry the edit."
                        )
                    }
                    newContent = content.replacingCharacters(in: range, with: newText)
                }
            } else {
                switch Self.whitespaceTolerantEdit(
                    content: content, candidates: candidates,
                    newText: newText, replaceAll: replaceAll
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

    /// Strips line-number prefixes from each line of text.
    /// Handles formats: `6\t`, `6   │ `, `6  | ` (from read_lines output).
    /// Only strips if ALL non-empty lines match the prefix pattern to avoid false positives.
    private static func stripLineNumberPrefixes(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let prefixPattern = try? NSRegularExpression(
            pattern: #"^\d+(\t|\s*[\x{2502}|]\s?)"#
        ) else {
            return text
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return text }

        let allMatch = nonEmptyLines.allSatisfy { line in
            let range = NSRange(line.startIndex..., in: line)
            return prefixPattern.firstMatch(in: line, range: range) != nil
        }

        guard allMatch else { return text }

        let stripped = lines.map { line in
            guard !line.isEmpty else { return line }
            let range = NSRange(line.startIndex..., in: line)
            if let match = prefixPattern.firstMatch(in: line, range: range) {
                let matchRange = Range(match.range, in: line)!
                return String(line[matchRange.upperBound...])
            }
            return line
        }

        return stripped.joined(separator: "\n")
    }

    /// Unescapes common JSON escape sequences that LLMs copy from read_file output.
    private static func unescapeJSONSequences(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: Whitespace-tolerant fallback

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
        content: String, candidates: [String], newText: String, replaceAll: Bool
    ) -> TolerantEditOutcome {
        let contentLines = content.components(separatedBy: "\n")
        // A whitespace-only anchor would match any blank run anywhere — refuse it.
        let lineCandidates: [(lines: [String], hadTerminator: Bool)] = candidates
            .map { splitAnchorLines($0) }
            .filter { candidate in
                candidate.lines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }

        if lineCandidates.isEmpty {
            return .notFound(hint: "old_text is whitespace-only — anchor on adjacent non-blank lines instead.")
        }

        var ambiguousCount: Int?
        for (index, candidate) in lineCandidates.enumerated() {
            let (oldLines, hadTerminator) = candidate
            let matches = windowMatches(contentLines: contentLines, oldLines: oldLines, trim: trimTrailing)
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
            let newLines: [String]
            if hadTerminator {
                // Mirror the anchor's terminator semantics on the replacement side:
                // empty new_text deletes the matched lines outright, and a trailing
                // newline on new_text doesn't insert a blank line.
                newLines = newText.isEmpty ? [] : splitAnchorLines(newText).lines
            } else {
                newLines = newText.components(separatedBy: "\n")
            }
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

        for (oldLines, _) in lineCandidates {
            let matches = windowMatches(contentLines: contentLines, oldLines: oldLines, trim: trimBoth)
            guard !matches.isEmpty else { continue }
            let lineList = matches.prefix(3).map { String($0 + 1) }.joined(separator: ", ")
            let plural = matches.count > 1 ? "s" : ""
            return .notFound(hint: "Lines match ignoring indentation near line\(plural) \(lineList) — check leading whitespace (tabs vs spaces).")
        }

        // Don't count the split sentinel after the file's final newline as a line.
        let fileLineCount = contentLines.last == "" ? contentLines.count - 1 : contentLines.count
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
        contentLines: [String], oldLines: [String], trim: (String) -> String
    ) -> [Int] {
        let n = oldLines.count
        guard n > 0, contentLines.count >= n else { return [] }
        let trimmedOld = oldLines.map(trim)
        let trimmedContent = contentLines.map(trim)
        var matches: [Int] = []
        var i = 0
        while i + n <= trimmedContent.count {
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
