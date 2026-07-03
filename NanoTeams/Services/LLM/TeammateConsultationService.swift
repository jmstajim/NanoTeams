import Foundation

/// Pure validation/record helpers for the `ask_teammate` consultation flow.
///
/// The LLM exchange itself lives in `LLMExecutionService+TeammateConsultation`
/// (persistent per-role consultation chat; system prompt resolved from the
/// team's `consultationPromptTemplate` in
/// `LLMExecutionService.buildConsultationSystemPrompt`). A legacy one-shot
/// `generateResponse` path lived here but was never called in production —
/// deleted so the Settings-exposed template has exactly one runtime consumer.
nonisolated struct TeammateConsultationService {}

// MARK: - Consultation Management

extension TeammateConsultationService {

    /// Check if a consultation limit has been reached
    static func hasReachedLimit(
        consultations: [TeammateConsultation],
        limits: TeamLimits
    ) -> Bool {
        consultations.count >= limits.maxConsultationsPerStep
    }

    /// Check if a consultation to the same teammate would exceed the limit
    static func wouldExceedSameTeammateLimit(
        consultations: [TeammateConsultation],
        targetTeammate: Role,
        limits: TeamLimits
    ) -> Bool {
        let countToTeammate = consultations.filter { $0.consultedRole == targetTeammate }.count
        return countToTeammate >= limits.maxSameTeammateAsks
    }

    /// Check if this is a duplicate question
    static func isDuplicateQuestion(
        consultations: [TeammateConsultation],
        targetTeammate: Role,
        question: String
    ) -> Bool {
        let normalizedQuestion = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return consultations.contains { consultation in
            consultation.consultedRole == targetTeammate &&
            consultation.question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuestion
        }
    }

    /// Create a new consultation record
    static func createConsultation(
        requestingRole: Role,
        consultedRole: Role,
        question: String,
        context: String?
    ) -> TeammateConsultation {
        TeammateConsultation(
            requestingRole: requestingRole,
            consultedRole: consultedRole,
            question: question,
            context: context,
            status: .pending
        )
    }
}
