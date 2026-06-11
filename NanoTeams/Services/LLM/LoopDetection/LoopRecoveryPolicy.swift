import Foundation

/// Pure, stateless policy for a TOP-LEVEL role whose stream was broken mid-flight
/// by a thinking loop: decide whether to retry (clean stateless replay) or take a
/// mode-aware terminal action. One exhaustive switch instead of ad-hoc branches on
/// diagnostic strings.
///
/// Delegated CHILD tasks are intentionally NOT modeled here — they fire the parent
/// interrupt directly via `DelegationLoopWatcher.noteStreamLoop` and never reach a
/// retry/terminal decision (the parent's awaiter owns the child's terminal state).
nonisolated enum LoopRecoveryPolicy {

    /// Terminal action when the retry budget is exhausted.
    enum TerminalDecision: Equatable {
        /// Pause and surface a question to the human Supervisor (manual mode).
        case escalateSupervisor(question: String)
        /// End the step gracefully (autonomous chat-mode advisory → `.done` idle).
        case finishGraceful
        /// Mark the step failed (autonomous non-chat).
        case failStep(message: String)
    }

    enum Decision: Equatable {
        /// Within retry budget: drop the session and replay the request statelessly
        /// (the looping turn is discarded; the session was never captured because
        /// `chatEnd` was never reached).
        case retryStateless
        /// Retry budget exhausted: take a terminal action.
        case terminal(TerminalDecision)
    }

    /// - Parameters:
    ///   - breakCount: How many consecutive times THIS step's stream has been broken
    ///                 for a loop (1 on the first break).
    ///   - maxRetries: Retry budget (`LLMConstants.maxThinkingLoopBreaks`).
    static func decide(
        signal: LoopSignal,
        breakCount: Int,
        maxRetries: Int,
        supervisorMode: SupervisorMode,
        isChatMode: Bool,
        roleName: String
    ) -> Decision {
        if breakCount < maxRetries {
            return .retryStateless
        }
        switch supervisorMode {
        case .manual:
            let question = """
            Role \(roleName) appears stuck in a reasoning loop (\(signal.scope)): \(signal.diagnostic). \
            Please advise how to proceed — clarify the task, give a concrete next step, or mark the step failed.
            """
            return .terminal(.escalateSupervisor(question: question))
        case .autonomous:
            if isChatMode {
                return .terminal(.finishGraceful)
            }
            return .terminal(.failStep(
                message: "Reasoning loop detected (\(signal.scope)): \(signal.diagnostic). Step aborted after \(maxRetries) retry attempts."
            ))
        }
    }
}
