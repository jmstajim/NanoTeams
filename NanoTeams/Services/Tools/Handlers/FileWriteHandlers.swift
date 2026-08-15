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
            var matchedIgnoringIndentation = false
            var indentationPassedThroughLines = 0
            // Selection goes through range(of:) — the same primitive the
            // single-replacement arm splices with — so "located but could not be
            // replaced" is unrepresentable. The previous shape selected via
            // contains() and re-searched, which needed a defensive arm for the two
            // primitives disagreeing; measured (macOS 26, NFC anchor over NFD
            // content) they agree, and if a future Foundation ever splits them,
            // a range miss now falls through to the tolerant path's honest
            // anchorNotFound instead of an unactionable "Internal error".
            var selected: (winner: EditCandidate, range: Range<String.Index>)?
            // Ambiguity is checked on the EXACT path too, not just the tolerant one below.
            // Without this an `old_text` occurring N times without `replace_all` silently
            // edited the FIRST occurrence and reported `replacements_made: 1` under `ok:true` —
            // a wrong-location write with no signal, which is a worse failure than any refusal.
            // Same index-0 rule as `whitespaceTolerantEdit`: the model's literal anchor being
            // ambiguous is terminal, while a TRANSFORMED candidate's ambiguity only disqualifies
            // that candidate (it exists to repair an absent anchor, so a later one may still be
            // unique).
            var exactAmbiguousCount: Int?
            for (index, candidate) in candidates.enumerated() {
                guard let range = content.range(of: candidate.old) else { continue }
                if !replaceAll {
                    let occurrences = content.components(separatedBy: candidate.old).count - 1
                    if occurrences > 1 {
                        if index == 0 {
                            return Self.exactAmbiguityError(args: args, count: occurrences)
                        }
                        if exactAmbiguousCount == nil { exactAmbiguousCount = occurrences }
                        continue
                    }
                }
                selected = (candidate, range)
                break
            }
            if selected == nil, let exactAmbiguousCount {
                return Self.exactAmbiguityError(args: args, count: exactAmbiguousCount)
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
                case .replaced(let replacedContent, let replacedCount, let kind):
                    newContent = replacedContent
                    count = replacedCount
                    switch kind {
                    case .trailingWhitespace: matchedIgnoringTrailingWhitespace = true
                    case .indentation(let passedThrough):
                        matchedIgnoringIndentation = true
                        indentationPassedThroughLines = passedThrough
                    }
                case .ambiguous(let matchCount):
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .anchorAmbiguous,
                        message: "old_text matches \(matchCount) regions when ignoring trailing whitespace — include more surrounding lines to disambiguate."
                    )
                case .notFound(let diagnosis):
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .anchorNotFound,
                        message: diagnosis.message(path: path),
                        details: diagnosis.details
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
                // Separate from the flag above because the repair is different in
                // kind: trailing whitespace is spliced away, whereas an indentation
                // match REWRITES the replacement's leading whitespace into the
                // file's convention. A model that sees this knows its own
                // indentation was not what landed.
                var matched_ignoring_indentation: Bool?
            }

            // No silent repair: the model is told that part of its replacement was
            // rewritten into the file's convention and part was left alone, because
            // the two halves are indistinguishable from its side and the next anchor
            // it builds from memory depends on knowing which is which.
            var warnings: [String] = []
            if indentationPassedThroughLines > 0 {
                warnings.append(
                    "Anchor indentation was rewritten to match the file. "
                    + "\(indentationPassedThroughLines) appended line"
                    + (indentationPassedThroughLines == 1 ? "" : "s")
                    + " kept your own indentation — the anchor showed no depth for "
                    + (indentationPassedThroughLines == 1 ? "it" : "them") + ". "
                    + "Re-read the region if it must match the file's style."
                )
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: EditFileData(
                    path: path, replacements_made: count,
                    matched_ignoring_trailing_whitespace: matchedIgnoringTrailingWhitespace ? true : nil,
                    matched_ignoring_indentation: matchedIgnoringIndentation ? true : nil
                ),
                meta: ToolResultMeta(warnings: warnings)
            )
        }
    }

    /// The exact path's ambiguity refusal. Same `ANCHOR_AMBIGUOUS` code as the tolerant path — so
    /// `ToolErrorNotePolicy.direction`'s `anchor_ambiguous` arm steers both identically — but a DIFFERENT
    /// sentence: the tolerant one says "when ignoring trailing whitespace", which is a false
    /// diagnosis here (this anchor matched byte-for-byte) and would send the model hunting a
    /// whitespace problem it does not have. Names `replace_all` because on this path, unlike the
    /// tolerant one, editing every occurrence is a coherent thing to have meant.
    static func exactAmbiguityError(args: [String: Any], count: Int) -> ToolExecutionResult {
        makeErrorResult(
            toolName: Self.name, args: args,
            code: .anchorAmbiguous,
            message: "old_text matches \(count) places in the file — include more surrounding lines to disambiguate, or pass replace_all: true to change every one."
        )
    }

    /// Matches the `read_lines` gutter forms: `6\t`, `6   │ `, `6  | `.
    /// Compiled once — the pattern is a literal, so `try!` either always succeeds
    /// or fails every test run; it cannot ship broken. NSRegularExpression is
    /// immutable, documented thread-safe, and now carries a `Sendable`
    /// conformance, so this needs no `nonisolated(unsafe)` escape hatch.
    private static let lineNumberPrefixPattern = try! NSRegularExpression(
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

    /// Which tolerance located the window — disclosed to the model, because the two
    /// differ in what they did to its `new_text` (nothing, vs re-indented it).
    ///
    /// `indentation` carries how many replacement lines kept the model's OWN
    /// indentation because they lie outside the matched window (see
    /// `reindentToFileConvention`). It is a count rather than a flag so the
    /// disclosure can name a number instead of hedging.
    enum TolerantMatchKind {
        case trailingWhitespace
        case indentation(passedThroughLines: Int)
    }

    enum TolerantEditOutcome {
        /// `count` is always >= 1 — a zero-match scan returns `.notFound` instead.
        case replaced(newContent: String, count: Int, kind: TolerantMatchKind)
        /// The anchor trailing-trim-matched `count` (> 1) regions with replace_all off:
        /// it needs MORE surrounding lines, not a character-level correction.
        case ambiguous(count: Int)
        /// No window matched. The diagnosis is TYPED rather than a free string
        /// because the states disagree about what advice is even true — see
        /// `NotFoundDiagnosis`.
        case notFound(NotFoundDiagnosis)
    }

    /// Why `old_text` did not match, at the granularity the recovery differs at.
    ///
    /// This is typed rather than a `hint: String?` because the base sentence is not
    /// shared: telling a model to "match exactly including whitespace and
    /// indentation" is right when its anchor is nearly correct and actively WRONG
    /// when the text is not in the file at all — measured on a real run
    /// (MeditationApp task 24), 22 of 31 failures were anchors naming code that
    /// never existed, and every one of them was answered with whitespace advice.
    /// The model then perturbed indentation for another round. Each case therefore
    /// owns its whole message.
    enum NotFoundDiagnosis {
        /// Anchor is only whitespace — it would match any blank run anywhere.
        case whitespaceOnlyAnchor
        /// Anchor cannot fit: it has more lines than the file has.
        case anchorLongerThanFile(anchorLines: Int, fileLines: Int)
        /// The window exists but its indentation could not be translated (see
        /// `reindentToFileConvention`). Carries the file's exact bytes so the next
        /// attempt is a copy rather than another guess.
        case indentationMismatch(lines: [Int], fileText: String)
        /// The anchor's first line was found, but the window breaks at
        /// `anchorLine` (0-based into the anchor).
        case diverges(anchorLine: Int, fileLine: Int, modelText: String, fileText: String?)
        /// Not one line of the anchor appears in the file.
        case absent

        /// The `details["diagnosis"]` key. Present only for the three states whose
        /// message SUPERSEDES the generic character-level steering in
        /// `ToolErrorNotePolicy.direction`; the two legacy states keep the old shape
        /// (generic sentence + appended hint) so their pins stay meaningful.
        var key: String? {
            switch self {
            case .indentationMismatch: "indentation_mismatch"
            case .diverges: "diverges"
            case .absent: "absent"
            case .whitespaceOnlyAnchor, .anchorLongerThanFile: nil
            }
        }

        /// Kept for the two legacy states, whose `message` composes as
        /// `anchorNotFoundMessage + " " + hint` — so the hint is already on the wire.
        /// `ToolErrorNotePolicy` appends it only when an envelope carried NO message at all;
        /// re-stating it beside a message that contains it put the same sentence in front of
        /// the model twice.
        var hint: String? {
            switch self {
            case .whitespaceOnlyAnchor:
                "old_text is whitespace-only — anchor on adjacent non-blank lines instead."
            case .anchorLongerThanFile(let anchorLines, let fileLines):
                "old_text has more lines (\(anchorLines)) than the file (\(fileLines))."
            case .indentationMismatch, .diverges, .absent:
                nil
            }
        }

        var details: [String: String]? {
            var dict: [String: String] = [:]
            if let hint { dict["hint"] = hint }
            if let key { dict["diagnosis"] = key }
            return dict.isEmpty ? nil : dict
        }

        func message(path: String) -> String {
            switch self {
            case .whitespaceOnlyAnchor, .anchorLongerThanFile:
                // Legacy shape: base sentence + hint. Both states mean the anchor is
                // malformed rather than mislocated, so the character-level advice holds.
                return hint.map { EditFileTool.anchorNotFoundMessage + " " + $0 }
                    ?? EditFileTool.anchorNotFoundMessage

            case .indentationMismatch(let lines, let fileText):
                // The phrase "ignoring indentation" is load-bearing — existing pins
                // are calibrated on it. The bytes are still handed over: they are
                // evidence, and cheap.
                //
                // What they are NOT is an instruction. This message used to close with
                // "copy those lines byte-for-byte", and MeditationApp task 28 measured
                // what that buys: three consecutive retries, the model reading the
                // eight-space line back as "9 leading spaces" in its own reasoning, and
                // an escape only when it abandoned the indented anchor for a zero-indent
                // one. Asking a model that has just failed to count spaces to count them
                // again is the one thing known not to work; name the way out it found.
                //
                // The advice is deliberately state-NEUTRAL. THREE states reach this arm
                // and only one of them is an irregular file: the window matched in
                // several places (ambiguity), the window is unique but the replacement
                // carries a depth that cannot be placed, or the anchor's one depth
                // corresponds to two file depths. An earlier draft asserted irregularity
                // outright and was therefore false on two routes in three — including
                // one an existing test stages against a uniformly tab-indented file.
                // Steering the model to a column-0 anchor is right on all three.
                return "old_text not found in \(path). Lines match ignoring indentation near "
                    + "line\(lines.count > 1 ? "s" : "") "
                    + lines.prefix(3).map(String.init).joined(separator: ", ")
                    + " — check leading whitespace (tabs vs spaces). "
                    + "The file's exact text there is:\n\(fileText)\n"
                    + "Rather than reproducing that indentation, anchor on a nearby line "
                    + "that starts at column 0."

            case .diverges(let anchorLine, let fileLine, let modelText, let fileText):
                // Name BOTH sides. The model cannot diff its anchor against a file it
                // is not looking at, and "line \(anchorLine + 1) of your old_text" is
                // the only coordinate it holds.
                let found = fileText.map { "the file has `\($0)`" } ?? "the file ends"
                return "old_text starts matching \(path) at line \(fileLine - anchorLine + 1), "
                    + "but line \(anchorLine + 1) of your old_text is `\(modelText)` while "
                    + "\(found) at line \(fileLine + 1). Re-read that region — your copy is stale."

            case .absent:
                // Deliberately silent about whitespace: none of these lines are in the
                // file under ANY spelling, so a whitespace correction cannot help and
                // naming it costs a round trip. The gutter advice survives because a
                // partially-guttered anchor lands here (stripLineNumberPrefixes bails
                // on the first non-matching line, so the repair never fires).
                return "old_text not found: none of its lines appear in \(path). "
                    + "Re-read the file before editing — this is not a whitespace problem. "
                    + "(If you copied from read_lines output, drop the line-number gutter.)"
            }
        }
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
            return .notFound(.whitespaceOnlyAnchor)
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
            let newLines = replacementLines(newText: newText, hadTerminator: hadTerminator)
            let windows = replaceAll ? matches : [matches[0]]
            return .replaced(
                newContent: spliceWindows(
                    contentLines: contentLines, windows: windows,
                    oldLineCount: oldLines.count, newLines: newLines),
                count: windows.count,
                kind: .trailingWhitespace
            )
        }

        if let ambiguousCount {
            return .ambiguous(count: ambiguousCount)
        }

        // TIER 3 — the window exists but its LEADING whitespace differs.
        //
        // The scan below already existed; it only ever produced a hint. Promoting it
        // is what closes the real loop: a file whose indentation is irregular (5-space
        // doc comments beside 4-space members — MeditationApp, inherited from earlier
        // agent runs) is read faithfully and then re-emitted by the model in canonical
        // form, so the anchor misses forever and the model starts perturbing spaces.
        //
        // Auto-fix requires a UNIQUE window: several windows may each need a different
        // translation, and picking one would be a wrong-location guess.
        for (oldLines, hadTerminator, newText) in lineCandidates {
            let matches = windowMatches(
                contentLines: contentLines, oldLines: oldLines, scanBound: scanBound, trim: trimBoth)
            guard !matches.isEmpty else { continue }

            if matches.count == 1, let start = matches.first {
                let fileWindow = Array(contentLines[start..<(start + oldLines.count)])
                let newLines = replacementLines(newText: newText, hadTerminator: hadTerminator)
                if let reindented = reindentToFileConvention(
                    newLines: newLines, anchorLines: oldLines, fileLines: fileWindow
                ) {
                    return .replaced(
                        newContent: spliceWindows(
                            contentLines: contentLines, windows: [start],
                            oldLineCount: oldLines.count, newLines: reindented.lines),
                        count: 1,
                        kind: .indentation(passedThroughLines: reindented.passedThroughCount)
                    )
                }
            }

            // Located but not translatable — hand back the file's exact bytes.
            return .notFound(.indentationMismatch(
                lines: matches.prefix(3).map { $0 + 1 },
                fileText: contentLines[matches[0]..<(matches[0] + oldLines.count)]
                    .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                    .joined(separator: "\n")
            ))
        }

        // Don't count the split sentinel after the file's final newline as a line —
        // the same rule `scanBound` applies when matching.
        let fileLineCount = scanBound
        if lineCandidates.allSatisfy({ $0.lines.count > fileLineCount }) {
            return .notFound(.anchorLongerThanFile(
                anchorLines: lineCandidates[0].lines.count, fileLines: fileLineCount))
        }

        // Nothing matched as a window. Distinguish "your copy is stale" from "this
        // text was never here" — they take different recoveries, and conflating them
        // is what sent a model chasing whitespace through 21 of 31 failures.
        for (oldLines, _, _) in lineCandidates {
            guard let partial = bestPartialMatch(
                contentLines: contentLines, oldLines: oldLines, scanBound: scanBound)
            else { continue }
            // A full match would have been caught by tier 3 above, so this is
            // unreachable — but it guards an index, and an out-of-range read here
            // is a trap that `ToolErrorHandler` cannot catch.
            guard partial.matched < oldLines.count else { continue }
            let fileIndex = partial.start + partial.matched
            return .notFound(.diverges(
                anchorLine: partial.matched,
                fileLine: fileIndex,
                modelText: trimBoth(oldLines[partial.matched]),
                fileText: fileIndex < scanBound ? trimBoth(contentLines[fileIndex]) : nil
            ))
        }

        return .notFound(.absent)
    }

    /// Splices `newLines` over each window, preserving the file's line-ending
    /// convention per window. Shared by tier 2 and tier 3 so CRLF handling cannot
    /// drift between the two paths.
    private static func spliceWindows(
        contentLines: [String], windows: [Int], oldLineCount: Int, newLines: [String]
    ) -> String {
        var lines = contentLines
        // Reversed so earlier indices stay valid as later windows are replaced.
        for start in windows.reversed() {
            let windowRange = start..<(start + oldLineCount)
            // Preserve the file's line-ending convention: a CRLF window keeps
            // CRLF after the edit (the model can't see line endings, so it
            // can't be asked to carry the \r itself).
            let windowIsCRLF = contentLines[windowRange].allSatisfy { $0.hasSuffix("\r") }
            let splice = windowIsCRLF ? newLines.map { $0 + "\r" } : newLines
            lines.replaceSubrange(windowRange, with: splice)
        }
        return lines.joined(separator: "\n")
    }

    /// Turns `new_text` into replacement lines, mirroring the anchor's terminator
    /// semantics: empty `new_text` under a terminator deletes the matched lines
    /// outright, and a trailing newline doesn't insert a blank line.
    ///
    /// Line endings are the TOOL's business (see `spliceWindows`), so whatever
    /// convention the model happened to emit is normalised away here. Without this,
    /// `read_file` — which returns a CRLF file's bytes verbatim — hands the model
    /// `\r\n`, it echoes `\r\n` back, and the CRLF reattach appends a SECOND `\r`,
    /// writing `\r\r\n`. That is not a valid line ending, and it shipped under
    /// `ok:true` with no disclosure.
    private static func replacementLines(newText: String, hadTerminator: Bool) -> [String] {
        let raw: [String]
        if hadTerminator {
            raw = newText.isEmpty ? [] : splitAnchorLines(newText).lines
        } else {
            raw = newText.components(separatedBy: "\n")
        }
        return raw.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Rewrites `new_text`'s leading whitespace from the model's indentation
    /// convention into the file's, or returns nil when the difference is not
    /// expressible as a per-depth mapping.
    ///
    /// The rule is that `anchorIndent -> fileIndent` must be a FUNCTION over the
    /// matched window. That admits the common repair (the model wrote four spaces
    /// where the file uses a tab, at every depth) and refuses the case that actually
    /// produced this code path: a file whose own indentation is irregular, where
    /// `"    "` maps to `"     "` on one line and `"    "` on the next. There the
    /// correct output is genuinely unknown, so the caller returns the file's bytes
    /// instead of writing a guess.
    ///
    /// Injectivity is deliberately NOT required. Two anchor depths collapsing onto
    /// one file depth is exactly the shape of the repair we want most: a model that
    /// opened a block with four spaces and closed it with five is describing one
    /// file depth twice, and refusing that would drop the commonest real win.
    ///
    /// A replacement line whose depth never appeared in the anchor is placed only if
    /// it lies OUTSIDE the matched window — see `freeRegion`. Inside the window the
    /// file has a demonstrated convention and an unknown depth is genuinely unplaceable,
    /// so the whole edit is still refused rather than extrapolated. Zero-indent and
    /// blank lines are exempt: no indentation means no indentation in either convention.
    ///
    /// The free region is then translated ALL-OR-NOTHING: either every depth in it is a
    /// map key and the whole block is relabelled into the file's convention, or none of
    /// it is touched. A per-line choice would re-order the block's own nesting, because
    /// the map relabels depths without preserving their order — see the comment at the
    /// decision itself.
    ///
    /// The outside-the-window rule is what makes INSERTION work at all. Measured on
    /// MeditationApp task 28: every one of the four refusals appended a 25-line struct
    /// after a three-line anchor, so `new_text` necessarily carried depths the anchor
    /// could not have shown, and refusing cost 30% of the run without the model ever
    /// recovering — it escaped by abandoning the indented anchor entirely.
    static func reindentToFileConvention(
        newLines: [String], anchorLines: [String], fileLines: [String]
    ) -> Reindented? {
        guard anchorLines.count == fileLines.count else { return nil }

        var map: [String: String] = [:]
        for (anchor, file) in zip(anchorLines, fileLines) {
            // A blank line carries no depth information, and the two sides disagree
            // about blank lines constantly (the file has "", the model wrote spaces).
            guard !trimBoth(anchor).isEmpty else { continue }
            let key = leadingWhitespace(anchor)
            let value = leadingWhitespace(file)
            if let existing = map[key], existing != value { return nil }
            map[key] = value
        }
        guard !map.isEmpty else { return nil }

        let free = freeRegion(newLines: newLines, anchorLines: anchorLines)

        // The free region is ALL-OR-NOTHING, and that is a correctness requirement, not
        // a simplification. The map is a per-depth RELABELLING; it is not order
        // preserving. Translating some lines of an appended block and leaving the rest
        // verbatim therefore re-orders the block's own nesting, which is the only meaning
        // an appended block has — the file fixes the window's depths, but nothing fixes
        // the new code's except its internal structure.
        //
        // Measured, with a 2-space model against a 4-space file (map {2→4, 4→8}) and an
        // appended block at 4/6/4: a per-line policy writes the opener at 8, its child at
        // 6, and the closer at 8 — the child lands SHALLOWER than the block enclosing it,
        // under `ok:true`. In Swift that is mangled but compiles; `edit_file` has no
        // extension gating, and in Python it is an IndentationError. Before this whole
        // tolerance existed the same input was refused with the file's bytes, so a
        // per-line policy converts a safe refusal into a wrong write.
        //
        // Neither real fixture (task 24, task 28) straddles the key set, so both stay
        // byte-identical either way — the defect was invisible to them by luck.
        let freeRegionIsTranslatable = free.allSatisfy { index in
            let line = newLines[index]
            if trimBoth(line).isEmpty { return true }
            let prefix = leadingWhitespace(line)
            return prefix.isEmpty || map[prefix] != nil
        }

        var out: [String] = []
        out.reserveCapacity(newLines.count)
        var passedThrough = 0
        for (index, line) in newLines.enumerated() {
            if trimBoth(line).isEmpty {
                out.append(line)
                continue
            }
            let prefix = leadingWhitespace(line)

            if free.contains(index) {
                // Expressible as a whole → the file's convention wins, and the block's
                // nesting survives because every one of its depths is relabelled.
                // Otherwise the model's own bytes, entire.
                if freeRegionIsTranslatable, let mapped = map[prefix] {
                    out.append(mapped + line.dropFirst(prefix.count))
                } else {
                    out.append(line)
                    if !prefix.isEmpty { passedThrough += 1 }
                }
                continue
            }

            // Inside the window every line replaces a line the file has a depth for, so
            // an unknown depth is unplaceable and the edit is refused.
            //
            // A zero-indent line is only passed through when the anchor never showed
            // that depth: if `""` IS a key — the anchor began at top level and the
            // file's window is nested — then top level means something here and the
            // line must be translated like any other.
            if let mapped = map[prefix] {
                out.append(mapped + line.dropFirst(prefix.count))
            } else if prefix.isEmpty {
                out.append(line)
            } else {
                return nil
            }
        }
        return Reindented(lines: out, passedThroughCount: passedThrough)
    }

    /// The outcome of translating a replacement's indentation into the file's.
    nonisolated struct Reindented {
        let lines: [String]
        /// How many lines were emitted with the model's OWN indentation because they
        /// lie outside the matched window and carry a depth the anchor never showed.
        /// Zero for a pure rewrite. Disclosed — a model whose indentation was partly
        /// rewritten and partly kept cannot build its next anchor from memory unless
        /// it is told which.
        let passedThroughCount: Int
    }

    /// Indices of `newLines` that are NOT a rewrite of the matched window, i.e. new
    /// content the file has no convention for.
    ///
    /// Only two shapes carry that evidence: the replacement opens with the anchor
    /// (append after it) or closes with it (insert before it). Anything else — the
    /// model rewrote the window itself — has no free region at all, and every line
    /// must be translated or the edit refused. Comparison ignores leading and
    /// trailing whitespace, since reproducing it exactly is the very thing the model
    /// has just failed at.
    private static func freeRegion(newLines: [String], anchorLines: [String]) -> Range<Int> {
        let newCount = newLines.count
        let anchorCount = anchorLines.count
        guard newCount > anchorCount, anchorCount > 0 else { return noFreeRegion }

        func aligns(_ slice: ArraySlice<String>) -> Bool {
            zip(slice, anchorLines).allSatisfy { trimBoth($0) == trimBoth($1) }
        }
        // Appended after the anchor: everything past the reproduced window is new.
        if aligns(newLines.prefix(anchorCount)) { return anchorCount..<newCount }
        // Inserted before it: everything up to the reproduced window is new.
        if aligns(newLines.suffix(anchorCount)) { return 0..<(newCount - anchorCount) }
        return noFreeRegion
    }

    /// "Every replacement line rewrites the window" — an empty index range, named
    /// because `0..<0` at a `return` reads like a coordinate rather than an answer.
    private static let noFreeRegion: Range<Int> = 0..<0

    /// The occurrence of the anchor's first line from which the most consecutive
    /// lines agree (ignoring leading and trailing whitespace), or nil when that line
    /// appears nowhere. Ties resolve to the earliest occurrence.
    ///
    /// Only used to DIAGNOSE — a partial match is never edited.
    static func bestPartialMatch(
        contentLines: [String], oldLines: [String], scanBound: Int
    ) -> (start: Int, matched: Int)? {
        guard let first = oldLines.first, scanBound > 0 else { return nil }
        let target = trimBoth(first)
        guard !target.isEmpty else { return nil }

        var best: (start: Int, matched: Int)?
        for i in 0..<scanBound where trimBoth(contentLines[i]) == target {
            var k = 0
            while k < oldLines.count, i + k < scanBound,
                  trimBoth(contentLines[i + k]) == trimBoth(oldLines[k]) {
                k += 1
            }
            if best == nil || k > best!.matched { best = (i, k) }
        }
        return best
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
