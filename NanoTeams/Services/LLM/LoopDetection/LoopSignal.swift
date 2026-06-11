import Foundation

/// Typed result of a repetition-loop detection scan. The three cases map 1:1 to
/// the three `MessageRepetitionDetector` modes; the discriminant lets every
/// consumer switch exhaustively instead of pattern-matching free-text diagnostic
/// prefixes. Produced by `LoopScanner`, carried by `AutovisorStuckEvaluator`'s
/// verdict and the streaming-loop recovery path.
nonisolated enum LoopSignal: Equatable, Hashable {

    /// A block repeated consecutively at the tail of a single message or live stream
    /// buffer (`detectTailLoop`).
    case withinMessage(diagnostic: String)

    /// Strategic repetition across recent role outputs (`detectAcrossMessages`).
    case acrossMessages(diagnostic: String)

    /// Identical `(toolName, argsJSON)` pair repeated N times (`detectIdenticalToolCallSequence`).
    case identicalToolCallSequence(diagnostic: String)

    /// Human-readable one-liner for the paused/supervisor envelope. Single
    /// accessor so no consumer re-correlates a discriminant with a separate string.
    var diagnostic: String {
        switch self {
        case .withinMessage(let d), .acrossMessages(let d), .identicalToolCallSequence(let d):
            return d
        }
    }

    /// Short scope label embedded in the delegation paused-envelope's
    /// `supervisor_message`. Mirrors the legacy `fireInterrupt` scope strings
    /// verbatim (`"across messages"` / `"tool-call repetition"`) so the
    /// LLM-facing envelope text — and the tests pinning it — are unchanged.
    var scope: String {
        switch self {
        case .withinMessage: return "within-message"
        case .acrossMessages: return "across messages"
        case .identicalToolCallSequence: return "tool-call repetition"
        }
    }
}
