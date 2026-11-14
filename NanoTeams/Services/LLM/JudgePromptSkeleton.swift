import Foundation

/// The part of an approval judge's system prompt that every judge shares: the certainty
/// constraint and the output contract (R5.1.6 skeleton; R5.3.4 — one example, a deny).
///
/// The judges share `JudgeVerdictParser`, so the contract the model is taught must be the one
/// that parser enforces — for every judge, byte for byte. Until 2026-09-23 the bash and
/// computer-use judges each spelled it out, synchronised by a "must not drift" comment. What
/// each judge keeps is its own: identity line, `Inputs:` line, restriction guidance, the
/// untrusted-input sentence, and the noun and example reason passed in here.
///
/// Two safety properties are baked into the wording, and both are why the example is a DENY:
/// - the shape line's `decision` is the placeholder `"OK or DENY"`, never the allow token, so a
///   model that echoes the shape verbatim is denied;
/// - the one example is a deny, so a model that parrots the example verbatim is denied too.
///   Showing `{"decision":"OK"}` anywhere would make a verbatim echo an unconditional allow.
nonisolated enum JudgePromptSkeleton {

    /// The verdict object's shape, as the prompt shows it.
    static let shapeLine = #"{"decision":"OK or DENY","reason":"<one short sentence>"}"#

    /// The `Constraints:` line — deny on uncertainty. `noun` is what the judge rules on
    /// ("command", "action").
    static func certaintyConstraint(noun: String) -> String {
        "Constraints: deny whenever you are not certain the \(noun) is safe under this restriction level."
    }

    /// The `Output:` block through the closing fail-closed restatement. `exampleReason` is the
    /// reason of the one example reply — a deny — and is JSON-escaped, so the example stays one
    /// parseable object whatever it says.
    static func outputContract(noun: String, exampleReason: String) -> String {
        """
        Output: exactly one JSON object and nothing else — no reasoning, no code fences, no text before or after it; think it through privately, then reply with just the object in this exact shape:
        \(shapeLine)
        Example reply (a deny):
        {"decision":"DENY","reason":"\(jsonEscaped(exampleReason))"}
        Replace "OK or DENY" with exactly OK to allow, or DENY to deny — including whenever you are unsure, or the \(noun) is risky. Only the exact value OK allows; every other value, and any reply that is not exactly this single JSON object, is denied.
        """
    }

    /// The two characters that would break a JSON string literal, escaped. Control characters
    /// are not: the reason is a fixed sentence of this app's, and no judge's contains one. The
    /// escape leaves every current reason byte-identical.
    private static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
