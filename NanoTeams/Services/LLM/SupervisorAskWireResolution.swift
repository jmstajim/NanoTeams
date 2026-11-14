import Foundation

/// The one producer of "the Supervisor's answer resolves the parked ask on the wire".
///
/// A parked `ask_supervisor` / `ask_supervisor_form` call leaves a `{"status":"pending"}`
/// `.tool` result on the wire, keyed by the call's provider id (`+ToolResultDispatching`).
/// The answer — the human's on re-entry (`+StepLifecycle`), the auto-answerer's within the
/// same iteration (`+ToolLoopState`) — REPLACES that placeholder in place, id kept. A second
/// `.tool` appended after it answers nothing the preceding turn asked: on the OpenAI-compat
/// route `NativeToolTurnPairing` found the call already claimed and minted the answer a fresh
/// `tool_call_id` inside every `buildRequest`, a prefix-cache miss per request that
/// `PromptPrefixFingerprint` (ids excluded by design) could not see; on Ollama the answer
/// shipped unnamed. Two paths, two producers, and only the auto-answer one replaced — the
/// review of 2026-09-13 found the other.
nonisolated enum SupervisorAskWireResolution {

    /// The provider ids of the supervisor-ask calls the LAST assistant turn of `messages`
    /// made — the calls a re-entry answer resolves. Empty when that turn made none: a
    /// transcript persisted before ids rode the wire, or a park that was not an ask.
    static func pendingAskCallIDs(in messages: [ChatMessage]) -> [String] {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return [] }
        return (last.toolCalls ?? [])
            .filter { ToolNames.supervisorAskTools.contains($0.name) }
            .map(\.id)
    }

    /// Replaces the `.tool` result of every call in `ids` with `answer`, id kept — the LAST
    /// result carrying the id, since a resent placeholder is the one the model last saw.
    /// Returns whether any was replaced; the callers append a fallback when none was.
    ///
    /// One pass over the wire indexes the last position of every id, so the replacement is
    /// linear in the wire plus the ids (`coverage/tools/algorithmic_complexity.py`, axis a1).
    @discardableResult
    static func resolve(ids: [String], with answer: String, in messages: inout [ChatMessage]) -> Bool {
        guard !ids.isEmpty else { return false }
        var lastIndexByID: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if message.role == .tool, let id = message.toolCallID { lastIndexByID[id] = index }
        }
        var replacedAny = false
        for id in ids {
            guard let index = lastIndexByID[id] else { continue }
            // The answer replaces the placeholder; what the placeholder told the model rides the
            // answer instead of vanishing with it — its warnings (a form's repairs, an argument
            // the runtime ignored) and the parser's `format_note` (an argument left out of a
            // prompt-taught call). The model never reads the placeholder itself: the step parks.
            let placeholder = messages[index].content ?? ""
            messages[index] = ChatMessage(
                role: .tool,
                content: LLMExecutionService.appendingRepairNote(
                    Self.formatNote(in: placeholder), to: carryingWarnings(from: placeholder, into: answer)),
                toolCallID: id)
            replacedAny = true
        }
        return replacedAny
    }

    /// The parser's note spliced into a tool turn (`LLMExecutionService.appendingRepairNote`):
    /// its `format_note` member, or `nil` when the turn carries none.
    private static func formatNote(in content: String) -> String? {
        guard content.contains("format_note"), let data = content.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["format_note"] as? String
    }
}
