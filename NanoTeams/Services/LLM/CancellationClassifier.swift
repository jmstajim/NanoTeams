import Foundation

/// Is this error the user stopping the work, or the work failing?
///
/// A single owner because the answer decides which of two OPPOSITE things a service does,
/// and four of them have to agree. Pause cancels the step task, `client.streamChat` throws,
/// and every catch arm downstream has to choose: report a failure, or unwind quietly. Get it
/// wrong and a Pause is recorded as a defect that outlives the pause —
///
/// - `SupervisorAutoAnswerService` returned its canned fallback, which
///   `recordAutoSupervisorAnswer` then persisted as the Supervisor's decision (the state
///   entry is still live: `cancelStepExecution` AWAITS the running task before clearing it),
///   clearing `needsSupervisorInput` and answering the role's question on the user's behalf.
/// - `LLMExecutionService+TeammateConsultation` wrote "Unable to get response from X:
///   cancelled" permanently onto `step.consultations`, rendered red forever.
/// - `DelegatedSupervisorAnswerService` raised an error banner and returned nil, which
///   `handleDelegateToTeam` reads as an internal failure and tears the child team down.
///
/// `TeamGenerationService` got this right first and its doc comment states the rule: the two
/// layers "must agree, or a paused generation is marked `.failed` at one layer and `.paused`
/// at the other". That rule was never a property of team generation — it is a property of
/// cancellation — so it lives here now and `TeamGenerationService.isCancellation` delegates.
nonisolated enum CancellationClassifier {

    /// True for `CancellationError` and for the `URLError.cancelled` that `URLSession`
    /// emits when its streaming task is cancelled mid-request.
    ///
    /// Both spellings are required: structured concurrency throws the former, but a stream
    /// already suspended on the network throws the latter, and which one surfaces depends on
    /// where the task happened to be — i.e. on timing, not on intent.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
