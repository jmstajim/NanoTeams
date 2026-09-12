import Foundation

/// The `form` argument as the model actually spells it, read into the JSON the decoder wants.
///
/// The questionnaire is ~2 KB of JSON the model escapes by hand into a `String` parameter
/// (`JSONSchema` cannot express an array of objects — CLAUDE.md #46), and under that burden a
/// model writing Russian reaches for the quotation marks of its language: `"label": «Мини-
/// редизайн»`, sometimes closed with `"` instead (`«Без правок по теням"`), and it loses count
/// of the closers, ending `{"questions": […]}` with one `}` too many. Measured on
/// `ornith-1.5:35b` (MeditationApp task 52, 2026-09-11): three of five forms in run 9, one of
/// two in run 10, three of three in run 11 — the last of which the model then abandoned one
/// character from success, because the loop nudge told it that changing the arguments was
/// not working. A constraint the prompt cannot hold moves into the instrument (playbook
/// R4.3.4); the instrument accepts the form the model emits (R3.8.7) when that form is a
/// standard spelling of a valid intent (R1.8.4) — and REPORTS every rewrite in the tool
/// result (REC.5), so the model learns what was read without paying a round trip for it.
///
/// Two rules, both lexical — this is a tokenizer pass, not a parser:
/// - a typographic quote (`«` / `“`) OUTSIDE a JSON string, where a value or key may start,
///   opens a string that closes on its own mate at nesting depth zero, or on a bare `"`
///   followed by a structural character (the asymmetric live shape). The content is emitted
///   as a `"`-delimited JSON string: a bare `"` inside it escaped, `\x` pairs copied as they
///   are, inner `«»` kept — they are content there;
/// - closers (`}` / `]`) after the top-level value has closed are dropped.
/// A raw `"`-delimited string is never rewritten (typographic quotes inside it are content),
/// an unterminated typographic quote ends the repair with everything before it kept (the
/// parser then stops ON it and the excerpt names it), and a tail that is anything but
/// closers and whitespace is left for the parser. `„` is not read: no field run has emitted it.
///
/// Raw text first, this second: the handler decodes what the model sent and runs this pass
/// only on a SYNTAX failure (`SupervisorFormDecoding.isSyntaxFailure`), so a valid form is
/// never rewritten and a validation failure — the text parsed — never reaches it. Same shape
/// as `HarmonyToolCallParsingHelpers.parseAfterRepair`.
///
/// Walks `unicodeScalars` by integer index: a `"` followed by a combining mark is one
/// `Character`, so a Character walk would miss it, and a `String.count` inside the loop is
/// the quadratic trap ranked by the complexity axis `a5`.
///
/// It also owns the form's repair VOCABULARY — including the two notes for repairs performed
/// next door in `JSONStructuralCloserRepair`. Those sentences are written for this seam ("the
/// form was read with it"), while the scan they report is shared with `team_config`, which
/// reports nothing; a note worded for a form does not belong on a utility two tools use.
/// Keeping all five here is also what lets the refusal arm compose them as one
/// already-handled clause without reaching across three types for the pieces.
nonisolated enum SupervisorFormTextRepair {

    /// How many surplus closers after the end of the form this pass will drop.
    ///
    /// REC.5 bounds every tolerant-parse seam by a named constant, and this one had none:
    /// `}]}]}}` was the measured tail (task 52 run 11), so the bound is generous at the
    /// observed shape and still refuses a tail that is debris rather than a slip. Past it
    /// the remainder goes to the parser verbatim, which names where it stopped.
    static let maxDroppedClosers = 3

    struct Outcome: Equatable, Sendable {
        /// The text to decode — `text` unchanged when nothing applied.
        let text: String
        /// One line per rule that fired, with its count; empty when nothing applied.
        let notes: [String]
        var changed: Bool { !notes.isEmpty }
    }

    static func repair(_ text: String) -> Outcome {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var inString = false
        var depth = 0
        var topLevelClosed = false
        var lastSignificant: Unicode.Scalar? = nil
        var requoted = 0
        var droppedClosers = 0
        /// Where the text after the top-level value begins, and the whitespace seen since:
        /// past the bound the whole tail is restored from `tailStart`, so the dropping is
        /// all-or-nothing rather than three-of-four.
        var tailStart = 0
        var pendingTail = String.UnicodeScalarView()

        scan: while index < scalars.count {
            let scalar = scalars[index]

            if inString {
                out.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    out.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "\"" { inString = false }
                index += 1
                continue
            }

            if topLevelClosed {
                if scalar == "}" || scalar == "]" {
                    guard droppedClosers < maxDroppedClosers else {
                        // Past the bound the tail is debris, not a slip: nothing after the
                        // value is dropped, and the parser reports where it stopped on the
                        // text as the model wrote it (REC.5 bounds every such seam).
                        out.append(contentsOf: scalars[tailStart...])
                        pendingTail = String.UnicodeScalarView()
                        droppedClosers = 0
                        break scan
                    }
                    droppedClosers += 1
                    index += 1
                    continue
                }
                if scalar.properties.isWhitespace {
                    pendingTail.append(scalar)
                    index += 1
                    continue
                }
                // Something other than a closer after the value: not a shape this pass
                // reads. The parser reports it, on the text as the model wrote it.
                out.append(contentsOf: pendingTail)
                pendingTail = String.UnicodeScalarView()
                out.append(contentsOf: scalars[index...])
                break scan
            }

            if let mate = closer(for: scalar), atValueStart(lastSignificant) {
                guard let (end, inner) = scanTypographicString(
                    in: scalars, from: index, opener: scalar, closer: mate)
                else {
                    // Unterminated: keep what was repaired so far, hand the rest to the
                    // parser unchanged — it will stop on this very character.
                    out.append(contentsOf: scalars[index...])
                    break scan
                }
                out.append("\"")
                out.append(contentsOf: escaped(inner))
                out.append("\"")
                requoted += 1
                lastSignificant = "\""
                index = end + 1
                continue
            }

            if scalar == "\"" {
                inString = true
            } else if scalar == "{" || scalar == "[" {
                depth += 1
            } else if scalar == "}" || scalar == "]" {
                depth -= 1
                if depth == 0 {
                    topLevelClosed = true
                    tailStart = index + 1
                }
            }
            out.append(scalar)
            if !scalar.properties.isWhitespace { lastSignificant = scalar }
            index += 1
        }

        out.append(contentsOf: pendingTail)
        var notes: [String] = []
        if requoted > 0 { notes.append(requotedNote(count: requoted)) }
        if droppedClosers > 0 { notes.append(droppedClosersNote(count: droppedClosers)) }
        return Outcome(text: notes.isEmpty ? text : String(out), notes: notes)
    }

    // MARK: - Notes

    /// runtime-prompt
    ///
    /// Rides `meta.warnings` of the SUCCESS envelope: the form was read, and this is how.
    /// Names the fact and the spelling the next call should use (R1.8.1); quotes none of the
    /// model's bytes back (R3.8.3).
    static func requotedNote(count: Int) -> String {
        "\(count) string(s) were quoted with « » or “ ” and were read as JSON strings; "
            + "JSON strings are quoted with \"."
    }

    /// runtime-prompt
    static func droppedClosersNote(count: Int) -> String {
        "\(count) closing bracket(s) after the end of the form were ignored."
    }

    /// runtime-prompt
    ///
    /// One dropped `}` or `]`, put back where the document first contradicted itself. No
    /// count: the repair inserts exactly one, and a number that is always 1 is noise. Names
    /// WHERE, because its sibling below repairs the other place and the two recoveries are
    /// different: this one is a bracket the model skipped while still writing.
    static let insertedCloserNote =
        "One closing bracket inside the form was missing and was put back; the form was read "
            + "with it."

    /// runtime-prompt
    ///
    /// The form's own final bracket — everything the model opened inside the document was
    /// closed, and only the frame around it was not (MeditationApp task 67 run 1,
    /// 2026-09-11: three calls, ~50 s and a questionnaire rewritten from Russian into
    /// English, for one `}`).
    static let closedTheFormNote =
        "The form's own final `}` was missing and was put back; the form was read with it."

    /// runtime-prompt
    ///
    /// The same notes on the FAILURE arm, where their job is the opposite one: to say what
    /// is NOT the fault. Read as the lead of an error they are a false diagnosis — the model
    /// rewrote 7 accepted guillemet strings in plain ASCII and announced them as the cause
    /// while the real defect, an object it never closed, went untouched (MeditationApp task
    /// 65 run 0, 2026-09-11). So they follow the fault and say so (playbook R1.8.5).
    static func handledNotTheFaultNote(_ notes: [String]) -> String {
        "Already handled, and not the cause of this failure: " + notes.joined(separator: " ")
    }

    // MARK: - Scanning

    private static func closer(for opener: Unicode.Scalar) -> Unicode.Scalar? {
        switch opener {
        case "\u{AB}": "\u{BB}"        // « »
        case "\u{201C}": "\u{201D}"    // “ ”
        default: nil
        }
    }

    /// A string may start at the start of the text or right after `:` `,` `[` `{` — the
    /// positions of a value and of a key.
    private static func atValueStart(_ lastSignificant: Unicode.Scalar?) -> Bool {
        guard let lastSignificant else { return true }
        return lastSignificant == ":" || lastSignificant == "," || lastSignificant == "["
            || lastSignificant == "{"
    }

    private static let structural: Set<Unicode.Scalar> = [",", "}", "]", ":"]

    /// From the opener at `start`, the index of the scalar that closes the string and the
    /// content between — or nil when nothing closes it. The FIRST closer wins: the mate at
    /// nesting depth zero, or a bare `"` whose next non-whitespace scalar is structural.
    /// Without first-wins, `{"a": «x", "b": "y»z"}` would swallow `", "b": "y` into one string.
    private static func scanTypographicString(
        in scalars: [Unicode.Scalar], from start: Int,
        opener: Unicode.Scalar, closer: Unicode.Scalar
    ) -> (end: Int, inner: [Unicode.Scalar])? {
        var inner: [Unicode.Scalar] = []
        var nesting = 0
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                inner.append(scalar)
                inner.append(scalars[index + 1])
                index += 2
                continue
            }
            if scalar == opener {
                nesting += 1
            } else if scalar == closer {
                if nesting == 0 { return (index, inner) }
                nesting -= 1
            } else if scalar == "\"", nextSignificantIsStructural(in: scalars, after: index) {
                return (index, inner)
            }
            inner.append(scalar)
            index += 1
        }
        return nil
    }

    private static func nextSignificantIsStructural(in scalars: [Unicode.Scalar], after index: Int) -> Bool {
        var probe = index + 1
        while probe < scalars.count, scalars[probe].properties.isWhitespace { probe += 1 }
        guard probe < scalars.count else { return false }
        return structural.contains(scalars[probe])
    }

    /// The inside of a typographic string as the body of a JSON string: a bare `"` is
    /// escaped, an existing `\x` pair is copied once, everything else is content.
    private static func escaped(_ inner: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(inner.count)
        var index = 0
        while index < inner.count {
            let scalar = inner[index]
            if scalar == "\\", index + 1 < inner.count {
                out.append(scalar)
                out.append(inner[index + 1])
                index += 2
                continue
            }
            if scalar == "\"" { out.append("\\") }
            out.append(scalar)
            index += 1
        }
        return out
    }
}
