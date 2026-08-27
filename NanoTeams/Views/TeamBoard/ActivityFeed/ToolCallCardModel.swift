import Foundation

/// Everything a tool-call card renders, derived ONCE from `StepToolCall`.
///
/// `ToolCallItemView` used to derive each field on demand from a computed property, and
/// SwiftUI re-evaluates a computed property at every reference: `canonicalName` was read
/// five times per body pass (four `String` allocations each, in
/// `ToolRegistry.resolveToolName`), and `call.argumentsJSON` was handed to
/// `JSONSerialization` twice on a `search` card — once by the exploratory-badge test and
/// once by the argument summarizer, which parse the identical bytes for different keys.
///
/// The fields are all `Sendable` + `Equatable` on purpose. A parsed `[String: Any]` is
/// neither, and it is COW-boxed, so threading the dictionary into a child view instead
/// would hand SwiftUI a fresh box every pass and defeat the structural comparison that
/// keeps the card off the hot path — paying back the parse this type exists to save.
nonisolated struct ToolCallCardModel: Equatable {
    /// Display + dispatch name with model-emitted namespace prefixes (`repo_browser.`,
    /// `functions.`) and common aliases stripped.
    let canonicalName: String
    /// True when this `search` call took the exploratory branch.
    let isExploratorySearch: Bool
    /// The `$ tool args` tail. Empty when a custom summary owns the row instead.
    let argumentSummary: String
    /// The richer inline summary for the collaboration tools, pre-resolved to display
    /// values so the view holds no unparsed JSON.
    let customSummary: ToolCallCustomSummary?

    /// Tools whose card renders `customSummary` in place of `argumentSummary`.
    private static let customSummaryTools: Set<String> = [
        ToolNames.requestTeamMeeting,
    ]

    static func make(
        call: StepToolCall,
        resolveRoleName: ((String) -> String)? = nil
    ) -> ToolCallCardModel {
        // The ONE `resolveToolName` and the ONE `parseJSONDictionary` for this card.
        let canonical = ToolRegistry.resolveToolName(call.name)
        let arguments = JSONUtilities.parseJSONDictionary(call.argumentsJSON)

        let hasCustomSummary = customSummaryTools.contains(canonical)
        let exploratory = canonical == ToolNames.search
            && (arguments.map { optionalBool($0, "exploratory") } ?? false)

        return ToolCallCardModel(
            canonicalName: canonical,
            isExploratorySearch: exploratory,
            argumentSummary: hasCustomSummary ? "" : ToolCallSummarizer.cardSummary(
                toolName: canonical,
                arguments: arguments,
                resultJSON: call.resultJSON,
                isError: call.isError == true,
                resolveRoleName: resolveRoleName
            ),
            customSummary: customSummary(canonical: canonical, arguments: arguments)
        )
    }

    private static func customSummary(
        canonical: String,
        arguments: [String: Any]?
    ) -> ToolCallCustomSummary? {
        guard let arguments else { return nil }
        switch canonical {
        case ToolNames.askTeammate:
            guard let question = arguments["question"] as? String, !question.isEmpty else {
                return nil
            }
            return .question(question)
        case ToolNames.requestTeamMeeting:
            let topic = (arguments["topic"] as? String) ?? ""
            let ids = optionalStringArray(arguments, "participants") ?? []
            let names = ids.compactMap { Role.builtInRole(for: $0)?.displayName }
            if topic.isEmpty, names.isEmpty { return nil }
            return .meeting(topic: topic, participantNames: names)
        default:
            return nil
        }
    }
}

/// The inline summary rendered next to the tool name, as display values rather than as
/// the JSON they came from.
nonisolated enum ToolCallCustomSummary: Equatable {
    case question(String)
    case meeting(topic: String, participantNames: [String])
}
