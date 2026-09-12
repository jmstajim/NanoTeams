import Foundation

/// Decodes a `T` per array element, swallowing per-element failures.
///
/// Lets a decoder drop malformed array entries — an artifact with `name: null` from a
/// truncated LLM stream, one questionnaire question the model spelled wrong — without
/// rejecting the whole payload. The judgement it encodes is that a model-authored array is
/// not an all-or-nothing document: nine good questions and one broken one are worth nine
/// questions, and the alternative (a hard throw) hands the model an error for a payload it
/// mostly got right.
///
/// One type, not one per decoder: it began file-private inside `GeneratedTeamConfig`, and a
/// second copy beside `SupervisorInquiry` would be the shape CLAUDE.md's 2026-08-02 lesson
/// names — an inline re-spelling of a shared rule, which diverges silently the first time
/// one of them learns something (a cap, a probe, a diagnostic) the other does not.
nonisolated struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
