import Foundation

// MARK: - Supervisor ask payload

/// The WHOLE question a parking call asks, as an ANSWERER must see it.
///
/// The deliberate contrast is `StepToolCall.parsedSupervisorQuestion`, which is scoped to the
/// ONE-LINE slot every card renders — `question` for the plain ask, `headline` for the form.
/// That is the right text for a banner and the wrong text for whoever has to decide: routing a
/// form's headline alone hands the answerer a summary and asks it to settle questions it never
/// saw, and the questionnaire comes back with every question unanswered while the asker
/// believes it was answered. The same reasoning is already written into
/// `DelegatedSupervisorAnswerService` for the downward direction; this is the upward one.
///
/// Three rungs, in order:
///   1. the form, read through the same ladder the tool seam climbs
///      (`SupervisorFormPayload`), rendered by `SupervisorInquiryReply.questionnaire(for:)`;
///   2. the one-line slot, for a plain ask or a form nothing could read;
///   3. `nil`, so the caller keeps whatever it was already asking.
nonisolated enum SupervisorAskPayload {

    /// - Returns: `nil` for a call that is not a parking call at all, and for a parking call
    ///   carrying no readable text.
    static func question(for call: StepToolCall) -> String? {
        guard call.isSupervisorAsk else { return nil }
        // The ARGUMENTS decide which tool this call describes, not the name it was emitted
        // under: a well-formed `{headline, form}` payload sent as `ask_supervisor` is the live
        // shape of 2026-09-10, and the same routing that makes it reach the form's handler
        // makes it read as a form here.
        let resolved = SupervisorAskRouting.correctedName(
            for: call.name, argumentKeys: argumentKeys(in: call.argumentsJSON)) ?? call.name
        if resolved == ToolNames.askSupervisorForm,
           case .read(let read)? = SupervisorFormPayload.read(argumentsJSON: call.argumentsJSON)
        {
            return SupervisorInquiryReply.questionnaire(for: read.inquiry)
        }
        return call.parsedSupervisorQuestion
    }

    /// The top-level argument names, or an empty set when the blob is not a JSON object —
    /// under which `correctedName` corrects nothing and the emitted name stands.
    private static func argumentKeys(in argumentsJSON: String) -> Set<String> {
        guard let data = argumentsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(parsed.keys)
    }
}
