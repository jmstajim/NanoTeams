import Foundation

/// Which of the two supervisor-ask tools a call's ARGUMENTS actually describe.
///
/// `ask_supervisor` and `ask_supervisor_form` are deliberately separate tools, and the price
/// of that is a name a model can get wrong — it did, live, on the run of 2026-09-10: a
/// perfectly formed `{headline, form}` payload sent under the name `ask_supervisor`, refused
/// with "Missing required argument: question". The model read the refusal, worked out what
/// had happened, and re-sent the identical form under the right name. One wasted round trip
/// for a call whose intent was never in doubt.
///
/// Refusing a call whose arguments say exactly what was meant is the failure mode, not the
/// safe default. So the arguments decide, in the ONE direction each key is unambiguous:
/// `form` belongs to the questionnaire and to nothing else, `question` to the plain ask and
/// to nothing else. A call carrying BOTH is genuinely ambiguous and is left alone to be
/// refused by the handler it named — guessing there would pick a question the model did not
/// ask on behalf of a human who cannot see what was dropped.
///
/// This is the same correction `ToolRegistry.defaultAliases` performs for a hallucinated name
/// (`grep` → `search`), one level later: the alias map answers from the name alone, and this
/// answers when only the arguments can. It follows the alias contract in both directions —
/// the RESULT names the tool that ran (so the model can see which of the two answered it),
/// and `tool_calls.jsonl` keeps the name the model emitted (so the slip stays visible to a
/// human reading the run) rather than being tidied away.
nonisolated enum SupervisorAskRouting {

    /// The tool that should run, or `nil` when the name already fits the arguments (which is
    /// every call that is not one of these two tools).
    static func correctedName(for name: String, argumentKeys: Set<String>) -> String? {
        guard ToolNames.supervisorAskTools.contains(name) else { return nil }
        let hasForm = argumentKeys.contains(formKey) || argumentKeys.contains(questionsKey)
        let hasQuestion = argumentKeys.contains(questionKey)
        guard hasForm != hasQuestion else { return nil }

        let intended = hasForm ? ToolNames.askSupervisorForm : ToolNames.askSupervisor
        return intended == name ? nil : intended
    }

    /// The one argument only `ask_supervisor_form` takes.
    private static let formKey = "form"
    /// The questionnaire's own top-level key, lifted here because a model that writes the
    /// form's CONTENT straight into the arguments has still described the questionnaire and
    /// nothing else. Live shape: `{headline, questions:[…]}` under the form's own name, five
    /// well-formed questions, refused for a missing `form` (MeditationApp task 71 run 4,
    /// 2026-09-12). The handler reads that shape as the document; this makes the same call
    /// reach the handler when the NAME is wrong too.
    private static let questionsKey = "questions"
    /// The one argument only `ask_supervisor` takes. `headline` is NOT a discriminator: it is
    /// the form's, but a model that sends `{question, headline}` has still asked a plain
    /// question and the extra key is ignorable — routing that to the form would refuse it for
    /// a missing `form` instead of parking on the question it did ask.
    private static let questionKey = "question"
}
