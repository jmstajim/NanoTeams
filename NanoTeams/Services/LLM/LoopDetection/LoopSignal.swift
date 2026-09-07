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

    /// The clause a MODEL may read — how the discarded output repeated itself, derived from
    /// the case alone. `diagnostic` and `scope` are for the human feed: `diagnostic` quotes
    /// up to 80 characters of the repeated block plus tool names and paths, and on an
    /// append-only wire a quoted fragment rides the prefix of every later request and
    /// re-seeds the loop it was meant to break (R3.8.3 / R5.2.6; measured 2026-08-24).
    /// `LoopRecoveryPolicy` composed this itself since then; `DelegationLoopWatcher` and
    /// `AutovisorStuckEvaluator.wireRow` shipped `diagnostic` to a model until 2026-09-07.
    /// Exhaustive on purpose: a fourth shape must be given words here.
    var modelFacingClause: String {
        switch self {
        case .withinMessage:
            return " — the same block of text, several times in a row."
        case .acrossMessages:
            return " — restating content from its earlier turns almost verbatim."
        case .identicalToolCallSequence:
            return " — the same tool call with identical arguments, several times in a row."
        }
    }

    /// Short scope label for the human-facing feed row. Mirrors the legacy `fireInterrupt`
    /// scope strings verbatim (`"across messages"` / `"tool-call repetition"`).
    var scope: String {
        switch self {
        case .withinMessage: return "within-message"
        case .acrossMessages: return "across messages"
        case .identicalToolCallSequence: return "tool-call repetition"
        }
    }
}
