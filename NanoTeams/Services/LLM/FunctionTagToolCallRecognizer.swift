import Foundation

/// Names of the tool calls written in the FUNCTION-TAG form —
///
///     <tool_call>
///     <function=read_file>
///     <parameter=path>
///     MeditationApp/StreaksWidget.swift
///     </parameter>
///     </function>
///     </tool_call>
///
/// Diagnosis only, never dispatch. The one caller is
/// `ConversationRepairService.reasoningChannelToolCallNames`, and its one use is the text of the
/// nudge that tells a model its call sits in its REASONING, where nothing runs it. Under
/// `.native` the server renders and parses this form itself and the app reads `tool_calls`; a
/// model that never closed its reasoning before the call gets the whole call back as reasoning
/// text, `finish_reason: stop`, no `tool_calls`. `MeditationApp` task 111 run 2 (2026-09-13,
/// LM Studio) did that on 3 of 10 responses, and because the detector read the taught `<|call|>`
/// alone, each of those turns was told "Missing deliverables" instead — the model, which had
/// called `list_files` as far as it knew, restarted its survey twice.
///
/// A FORM, not a model: nothing here names a family or reads a chat template.
///
/// The gate, each part load-bearing:
///  1. the literal `<tool_call>` — exact, never case-folded or trimmed, the rule
///     `HarmonySentinelNormalizer` states for the same tag;
///  2. then at most `maxWrapperGap` whitespace characters and `<function=NAME>`, NAME a
///     non-empty run of ASCII `[A-Za-z0-9_.-]` closed by `>` at once. The function tag alone is
///     how prose DESCRIBES the form; the wrapper around it is what makes it a call;
///  3. then `</function>` before the next `<tool_call>` — an unfinished call is not a callable
///     one in the wrong channel (the Harmony detector's rule), and a closer is never borrowed
///     from the call after it.
///
/// This form in CONTENT is a different question with its own answer (`HarmonySentinelNormalizer`,
/// train-first-prompt KNOWN_ISSUES A26): there, reading it as a call would dispatch it.
///
/// `nonisolated` because the app target defaults types to `@MainActor`.
nonisolated enum FunctionTagToolCallRecognizer {

    private static let wrapperOpen = "<tool_call>"
    private static let functionOpen = "<function="
    private static let functionClose = "</function>"

    /// Longest whitespace run tolerated between the wrapper and the function tag. The observed
    /// run is a single `\n` in all three responses; 4 is headroom — the same cap and reasoning as
    /// `HarmonySentinelNormalizer.maxWrapperGap`.
    static let maxWrapperGap = 4

    /// Called names in written order, each once.
    static func calledNames(in text: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        var cursor = text.startIndex
        while let wrapper = text.range(of: wrapperOpen, range: cursor..<text.endIndex) {
            cursor = wrapper.upperBound
            guard let function = functionTag(in: text, from: wrapper.upperBound) else { continue }
            let callEnd = text.range(of: wrapperOpen, range: function.end..<text.endIndex)?.lowerBound
                ?? text.endIndex
            guard text.range(of: functionClose, range: function.end..<callEnd) != nil else { continue }
            if seen.insert(function.name).inserted {
                names.append(function.name)
            }
        }
        return names
    }

    /// The `<function=NAME>` opening at `start`, past at most `maxWrapperGap` whitespace
    /// characters: its name and the index just after its `>`.
    private static func functionTag(
        in text: String, from start: String.Index
    ) -> (name: String, end: String.Index)? {
        var index = start
        var gap = 0
        while index < text.endIndex, text[index].isWhitespace {
            gap += 1
            guard gap <= maxWrapperGap else { return nil }
            index = text.index(after: index)
        }
        guard let open = text.range(of: functionOpen, options: .anchored, range: index..<text.endIndex)
        else { return nil }
        index = open.upperBound
        let nameStart = index
        while index < text.endIndex, isNameCharacter(text[index]) {
            index = text.index(after: index)
        }
        guard index > nameStart, index < text.endIndex, text[index] == ">" else { return nil }
        return (String(text[nameStart..<index]), text.index(after: index))
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "_" || character == "."
                || character == "-")
    }
}
