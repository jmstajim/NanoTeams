import Foundation

/// The structural closers a model dropped from a JSON document it escaped by hand.
///
/// A model hand-escaping a nested JSON document loses count of `}` and `]` — measured at two
/// seams of this app, both of them a JSON document carried inside a `String` tool argument
/// because `JSONSchema` cannot express an array of objects (CLAUDE.md #46): `create_team`'s
/// `team_config` and `ask_supervisor_form`'s `form`. Two shapes of that miscount are repaired
/// here, both bounded on purpose, and it is the caller — not this scan — that decides whether
/// to adopt a candidate: adoption is "it parses now", which only the caller's own decoder can
/// answer (playbook REC.5).
///
/// **One closer dropped INSIDE the document** (`insertingDroppedCloser`). Three contradictions
/// locate it, and each names the closer that is missing:
/// - a `}` while an array is innermost — the array's `]` was dropped, insert it there;
/// - a `]` while an object is innermost — the object's `}` was dropped, insert it there;
/// - a key or an object where a VALUE cannot stand — the enclosing container closed too
///   late, so the insertion point walks BACK to the separating `,` (or to the start of the
///   key when there is none).
///
/// **The document's OWN closer dropped at the end** (`closingTheTopLevelContainer`). Exactly
/// one container open at end of text means every container the model opened INSIDE the
/// document was closed: nothing is missing from the content, only the frame around it. Two or
/// more open containers is the other thing entirely — something the model was in the middle
/// of writing never finished — and padding that would launder an abandoned emission into a
/// document that reads as whole (playbook R3.7.6, CLAUDE.md #293). So exactly one is closed
/// and everything else is reported to the model instead, which can say precisely what is
/// owed.
nonisolated enum JSONStructuralCloserRepair {

    /// What one walk of the document found.
    private enum Finding {
        /// The document contradicts itself at `at`, and `closer` is what was dropped before it.
        case drop(at: Int, closer: Unicode.Scalar)
        /// The walk reached the end. `open` is what is still open, outermost first;
        /// `endsOnCompleteValue` is true only when the last thing written is a value that
        /// provably ENDED: a closed string or a closed container; `endsInsideString` singles
        /// out the one incomplete tail a reader can name precisely.
        case endOfText(open: [Unicode.Scalar], endsOnCompleteValue: Bool, endsInsideString: Bool)
    }

    /// The candidate text with one closer inserted, or nil when the scan finds no drop.
    /// The candidate is NOT parsed here — the caller adopts it only if its own decode
    /// succeeds.
    static func insertingDroppedCloser(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard case .drop(let at, let closer) = scan(scalars), at <= scalars.count else {
            return nil
        }
        var repaired = String.UnicodeScalarView(scalars[0..<at])
        repaired.append(closer)
        repaired.append(contentsOf: scalars[at...])
        return String(repaired)
    }

    /// What a document that reached its end still owes.
    struct Unclosed: Equatable, Sendable {
        /// The closers that would balance it, innermost first — `"]}"` for an object holding
        /// an unclosed array. Never empty.
        let closers: String
        /// False when the text breaks off inside a string, or right after a separator or an
        /// opener: there the last thing written is itself unfinished, so what is missing is
        /// content and not only brackets.
        let endsOnCompleteValue: Bool
        /// True for the one incomplete tail that can be named rather than merely reported:
        /// a string the model opened and never closed. The others — a dangling comma, a bare
        /// opener, a literal cut mid-digit — are indistinguishable from a value still being
        /// written, so a reader can only say the text ran out.
        let endsInsideString: Bool
    }

    /// What `text` still owes at end of text, or nil when it owes nothing — including when
    /// the walk found a dropped closer INSIDE the document instead, which is
    /// `insertingDroppedCloser`'s shape and not an unfinished tail.
    ///
    /// The one place that knows what is open where the model stopped: the repair below reads
    /// it, and so does the refusal that has to tell the model what to add.
    static func unclosed(in text: String) -> Unclosed? {
        guard case .endOfText(let open, let complete, let inString) = scan(Array(text.unicodeScalars)),
              !open.isEmpty
        else { return nil }
        return Unclosed(
            closers: String(open.reversed().map { $0 == "[" ? "]" : "}" }),
            endsOnCompleteValue: complete,
            endsInsideString: inString)
    }

    /// The candidate text with the document's own closer appended, or nil when the text does
    /// not end exactly one closer short of complete.
    ///
    /// Refused when the text breaks off mid-value, when nothing is open, and when MORE than
    /// the document itself is open — see the type's note on why the bound is one. Like the
    /// other repair it returns an UNPARSED candidate for the caller to adopt.
    static func closingTheTopLevelContainer(in text: String) -> String? {
        guard let unclosed = unclosed(in: text),
              unclosed.endsOnCompleteValue, unclosed.closers.count == 1
        else { return nil }
        return text + unclosed.closers
    }

    /// The candidate text with its trailing run of closers rewritten in the order the open
    /// containers actually owe, or nil when that run is already right — or wrong in some
    /// other way.
    ///
    /// The third miscount, and the one that appeared only once the document stopped being
    /// hand-escaped. With `form` declared `object` the model no longer loses count of
    /// brackets — it writes the right NUMBER of them, of the right kinds, in the wrong ORDER:
    /// `}}]` where the nesting owes `}]}`. The tally balances, so nothing here reports a drop
    /// and nothing reports an unclosed container; Foundation refuses at the first closer that
    /// does not match, saying only "Expecting ',' delimiter" about a position several levels
    /// deep. Measured 8 of 11 undispatched emissions across 20 runs (`ornith-1.5:35b`,
    /// MeditationApp task 75, 2026-09-12); the other three are a genuinely different
    /// miscount and this refuses them.
    ///
    /// Narrow by construction, and the narrowness is what makes it safe to apply blind:
    /// - only the maximal trailing run of `}`/`]` is touched, so nothing inside the document
    ///   moves;
    /// - the text before that run must end on a COMPLETE value, so an emission abandoned
    ///   mid-write is refused rather than padded into something that reads as whole (the same
    ///   bound `closingTheTopLevelContainer` carries, playbook R3.7.6);
    /// - the run's multiset must equal what is owed. Equal multiset plus unequal order is the
    ///   whole signature: nothing is added, nothing is dropped, the same closers are put back
    ///   in the order the containers were opened in. A run that owes MORE or FEWER closers
    ///   than were written is a different defect and is left to be reported.
    ///
    /// Like its two siblings the candidate is returned UNPARSED — adoption is "it parses now",
    /// which only the caller's decoder can answer (playbook REC.5).
    static func reorderingTrailingClosers(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var start = scalars.count
        while start > 0, scalars[start - 1] == "}" || scalars[start - 1] == "]" {
            start -= 1
        }
        // One closer cannot be in the wrong order, and zero is not this defect.
        guard scalars.count - start >= 2 else { return nil }
        let written = String(String.UnicodeScalarView(scalars[start...]))
        let head = String(String.UnicodeScalarView(scalars[0..<start]))
        guard let unclosed = unclosed(in: head),
              unclosed.endsOnCompleteValue,
              unclosed.closers != written,
              unclosed.closers.sorted() == written.sorted()
        else { return nil }
        return head + unclosed.closers
    }

    // MARK: - The walk

    /// One lexical pass, two answers. Not a parser: it tracks string boundaries, `\` escapes
    /// and container nesting, and stops at the first place the nesting contradicts itself.
    ///
    /// Walks `unicodeScalars` by integer index: a `"` followed by a combining mark is one
    /// `Character`, so a Character walk would miss it, and a `String.count` inside the loop
    /// is the quadratic trap ranked by the complexity axis `a5`.
    private static func scan(_ scalars: [Unicode.Scalar]) -> Finding {
        var stack: [Unicode.Scalar] = []
        var inString = false
        /// The most recent `,` while an ARRAY / an OBJECT is innermost — the walk-back target.
        var arrayComma: Int?
        var objectComma: Int?
        var lastSignificant: Unicode.Scalar?
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if inString {
                if scalar == "\\", index + 1 < scalars.count {
                    index += 2
                    continue
                }
                if scalar == "\"" {
                    inString = false
                    lastSignificant = "\""
                }
                index += 1
                continue
            }

            switch scalar {
            case "\"":
                inString = true
            case "{", "[":
                // A container where a KEY belongs — only possible if the enclosing object
                // should already have closed. Requires the separating comma to walk back to:
                // without one the document is missing a separator as well, and choosing
                // between the two would be two edits invented from one observation.
                if stack.last == "{", lastSignificant == "," || lastSignificant == "{",
                   let comma = objectComma {
                    return .drop(at: comma, closer: "}")
                }
                stack.append(scalar)
                arrayComma = nil
                objectComma = nil
            case "}":
                if stack.last == "{" {
                    stack.removeLast()
                    arrayComma = nil
                    objectComma = nil
                } else if stack.last == "[" {
                    return .drop(at: index, closer: "]")
                }
            // else: a closer with nothing open — trailing debris, not this drop.
            case "]":
                if stack.last == "[" {
                    stack.removeLast()
                    arrayComma = nil
                    objectComma = nil
                } else if stack.last == "{" {
                    return .drop(at: index, closer: "}")
                }
            case ":":
                // A `key: value` pair inside an array is impossible — the array's `]` was
                // dropped before the preceding key, and the separating comma is where it
                // goes. Without a comma there is NO place to put it, and the walk goes on:
                // closing at the key's own start would put `]` immediately before a `"`,
                // which no container accepts after a closer — an object wants `,` or `}`
                // there and an array `,` or `]`. That candidate could never parse, so it was
                // removed rather than tested around (2026-09-12; CLAUDE.md #189).
                if stack.last == "[", let at = arrayComma {
                    return .drop(at: at, closer: "]")
                }
            case ",":
                if stack.last == "[" {
                    arrayComma = index
                } else if stack.last == "{" {
                    objectComma = index
                }
            default:
                break
            }

            if !scalar.properties.isWhitespace { lastSignificant = scalar }
            index += 1
        }

        // Only a value that provably ENDED counts: a closed string or a closed container.
        // Stated the other way round — as "not a separator, not an opener" — it also admits
        // a bare literal, and a bare literal at end of text is exactly the cut that cannot be
        // seen: `{"a":12` closes into `12` where the model was writing `125`, and no decoder
        // can tell. Nothing else is a JSON value that can be known to be complete, so the
        // rule is written as the small allowed set rather than as a list of exclusions.
        let complete = !inString
            && (lastSignificant == "\"" || lastSignificant == "}" || lastSignificant == "]")
        return .endOfText(open: stack, endsOnCompleteValue: complete, endsInsideString: inString)
    }
}
