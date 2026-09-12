import Foundation

// MARK: - Wire contract

/// Snake-case keys matching the JSON contract documented in the `ask_supervisor_form` schema.
/// `JSONSchema` cannot express this shape (CLAUDE.md #46), so the object arrives unvalidated
/// and the decoder is the ONLY thing standing between a sloppy generation and a card the human
/// cannot answer. The `String` arm survives as tolerance, not as the declared shape: `form` has
/// been `JS.object` since 2026-09-12, and 26 of 26 field emissions that day were objects.
///
/// Two tolerances and one refusal, and the split is deliberate:
///
/// - **Tolerated, per element:** one malformed question or option is dropped (`Failable`).
///   Nine good questions and one broken one are worth nine questions, and rejecting the lot
///   hands the model an error for a payload it mostly got right.
/// - **Tolerated, per field:** a missing `id` is synthesized from the text it labels, the way
///   `GeneratedTeamConfig` synthesizes a team name — models omit ids far more often than they
///   get them wrong.
/// - **Refused, loudly:** an empty questionnaire, a choice with nothing to choose, duplicate
///   ids, a `free_text` question carrying options, and anything past a cap. Each of these is
///   a contradiction the model can see and fix from the message; guessing at them would put a
///   decision in front of the human that nobody intended.
///
/// Caps REFUSE rather than truncate: a silently shortened questionnaire asks the human to
/// decide on a set the model did not author.
nonisolated extension SupervisorInquiry {
    enum CodingKeys: String, CodingKey {
        case headline
        case questions
    }

    init(from decoder: Decoder) throws {
        let decoded = try Self.decode(from: decoder)
        self.init(headline: decoded.headline, questions: decoded.questions)
    }

    /// Heavy decode body extracted from `init(from:)` — the same workaround
    /// `GeneratedTeamConfig` documents for the Swift 6.3.1 type-checker crash
    /// (`bad_optional_access`) on a long init inside a type with non-default isolation.
    private static func decode(from decoder: Decoder) throws -> SupervisorInquiry {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawHeadline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        let headline = rawHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .headline, in: c,
                debugDescription: "A questionnaire needs a headline — one line naming what it "
                    + "is about. Every surface that shows a supervisor question shows this.")
        }
        guard headline.count <= SupervisorInquiryLimits.maxHeadlineCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: .headline, in: c,
                debugDescription: "Headline is \(headline.count) characters; the limit is "
                    + "\(SupervisorInquiryLimits.maxHeadlineCharacters). Put the detail in a "
                    + "question, not in the headline.")
        }

        let raw = try c.decodeIfPresent([Failable<SupervisorInquiryQuestion>].self, forKey: .questions) ?? []
        return try SupervisorInquiry(
            headline: headline,
            validating: raw.compactMap(\.value),
            emptyWasAuthored: !raw.isEmpty,
            codingPath: c.codingPath + [CodingKeys.questions])
    }

    /// Builds an inquiry from already-decoded questions, applying the rules that are about
    /// the SET rather than about one question: non-empty, unique ids.
    ///
    /// Split out because there are two entry points — this type's own decoder and the
    /// `ask_supervisor_form` payload, whose headline arrives as a sibling ARGUMENT rather
    /// than inside the JSON — and set-level rules re-spelled at the second one would be the
    /// inline-copy divergence CLAUDE.md's 2026-08-02 lesson names.
    ///
    /// - Parameter emptyWasAuthored: whether the model wrote questions that were all dropped,
    ///   as opposed to writing none. The two get different messages: one names the required
    ///   shape, the other says a questionnaire needs a question at all.
    init(
        headline: String,
        validating questions: [SupervisorInquiryQuestion],
        emptyWasAuthored: Bool,
        codingPath: [CodingKey] = []
    ) throws {
        func fail(_ message: String) -> DecodingError {
            DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: message))
        }

        guard !questions.isEmpty else {
            throw fail(emptyWasAuthored
                ? "Every question was malformed. Each needs `prompt` and a `kind` of "
                + "free_text, single_choice or multi_choice."
                : "A questionnaire needs at least one question.")
        }
        // No cap on the COUNT — see `SupervisorInquiryLimits`. A form asking ten things is a
        // role that needs to know ten things, and the Supervisor answers the ones they care
        // about; refusing it spent an emission to teach the opposite.

        // Answers are keyed by question id, so a duplicate would silently merge two questions'
        // answers into one — a wrong decision recorded against a question nobody answered.
        var seen = Set<String>()
        for question in questions where !seen.insert(question.id).inserted {
            throw fail("Duplicate question id `\(question.id)`. Ids must be unique — answers "
                + "are recorded against them.")
        }

        self.init(headline: headline, questions: questions)
    }
}

// MARK: - Question

nonisolated extension SupervisorInquiryQuestion {
    enum CodingKeys: String, CodingKey {
        case id
        case prompt
        case detail
        case kind
        case options
        case recommendedOptionID
    }

    init(from decoder: Decoder) throws {
        let decoded = try Self.decode(from: decoder)
        self.init(
            id: decoded.id, prompt: decoded.prompt, detail: decoded.detail,
            kind: decoded.kind, options: decoded.options,
            recommendedOptionID: decoded.recommendedOptionID)
    }

    private static func decode(from decoder: Decoder) throws -> SupervisorInquiryQuestion {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawPrompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .prompt, in: c, debugDescription: "A question needs a `prompt`.")
        }
        guard prompt.count <= SupervisorInquiryLimits.maxPromptCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: .prompt, in: c,
                debugDescription: "Question prompt is \(prompt.count) characters; the limit is "
                    + "\(SupervisorInquiryLimits.maxPromptCharacters).")
        }

        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        guard let kind = SupervisorInquiryKind.fromLooseString(rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown kind `\(rawKind)`. Use one of: "
                    + SupervisorInquiryKind.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }

        let rawOptions = try c.decodeIfPresent([Failable<SupervisorInquiryOption>].self, forKey: .options) ?? []
        let options = rawOptions.compactMap(\.value)

        if kind.isChoice {
            guard !options.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .options, in: c,
                    debugDescription: "`\(kind.rawValue)` needs at least one option. Use "
                        + "free_text when there is nothing to choose between.")
            }
            guard options.count <= SupervisorInquiryLimits.maxOptionsPerQuestion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .options, in: c,
                    debugDescription: "\(options.count) options; the limit is "
                        + "\(SupervisorInquiryLimits.maxOptionsPerQuestion).")
            }
            var seen = Set<String>()
            for option in options where !seen.insert(option.id).inserted {
                throw DecodingError.dataCorruptedError(
                    forKey: .options, in: c,
                    debugDescription: "Duplicate option id `\(option.id)` in question "
                        + "`\(prompt.prefix(60))`.")
            }
        } else if !options.isEmpty {
            // Contradiction, not a shorthand: silently keeping the options would show a choice
            // the kind says does not exist, and silently dropping them would delete work the
            // model did. Both put something in front of the human nobody authored.
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "`free_text` carries \(options.count) option(s). Use "
                    + "single_choice or multi_choice to offer them.")
        }

        let rawID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let id = SupervisorInquiryIdentity.resolve(rawID, fallbackFrom: prompt)
        let rawDetail = try c.decodeIfPresent(String.self, forKey: .detail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawDetail, rawDetail.count > SupervisorInquiryLimits.maxDetailCharacters {
            throw DecodingError.dataCorruptedError(
                forKey: .detail, in: c,
                debugDescription: "Question detail is \(rawDetail.count) characters; the limit "
                    + "is \(SupervisorInquiryLimits.maxDetailCharacters). A detail is one line "
                    + "under the question, not the answer to it.")
        }

        // Read, never required: the model is not asked for this key, but the PERSISTED
        // questionnaire carries one (`StepExecution.supervisorInquiry` decodes through here),
        // and a model that writes it anyway has said something true about its own options.
        // Validated against them, so an id naming nothing resolves to no recommendation
        // rather than to a neighbour.
        let recommended = try c.decodeIfPresent(String.self, forKey: .recommendedOptionID)
        let resolved = options.contains { $0.id == recommended } ? recommended : nil

        return SupervisorInquiryQuestion(
            id: id, prompt: prompt,
            detail: (rawDetail?.isEmpty ?? true) ? nil : rawDetail,
            kind: kind, options: options, recommendedOptionID: resolved)
    }
}

// MARK: - Option

nonisolated extension SupervisorInquiryOption {
    enum CodingKeys: String, CodingKey {
        case id
        case label
        case detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawLabel = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .label, in: c, debugDescription: "An option needs a `label`.")
        }
        guard label.count <= SupervisorInquiryLimits.maxOptionLabelCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: .label, in: c,
                debugDescription: "Option label is \(label.count) characters; the limit is "
                    + "\(SupervisorInquiryLimits.maxOptionLabelCharacters). Put the reasoning "
                    + "in `detail`.")
        }
        let rawID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let rawDetail = try c.decodeIfPresent(String.self, forKey: .detail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawDetail, rawDetail.count > SupervisorInquiryLimits.maxDetailCharacters {
            throw DecodingError.dataCorruptedError(
                forKey: .detail, in: c,
                debugDescription: "Option detail is \(rawDetail.count) characters; the limit is "
                    + "\(SupervisorInquiryLimits.maxDetailCharacters). A detail is one line "
                    + "beside the option, not a document.")
        }
        self.init(
            id: SupervisorInquiryIdentity.resolve(rawID, fallbackFrom: label),
            label: label,
            detail: (rawDetail?.isEmpty ?? true) ? nil : rawDetail)
    }
}

// MARK: - Identity

/// Resolves the id of a question or an option.
///
/// Models omit ids far more often than they get them wrong, and a payload rejected over a
/// missing id costs a whole round trip for something the text already determines. So an
/// absent id is synthesized from the text it labels — deterministic, so the same question
/// decoded twice keeps the same identity and a half-filled answer still matches.
nonisolated enum SupervisorInquiryIdentity {
    /// Longest synthesized id. Long enough to keep distinct prompts distinct, short enough
    /// that the id stays readable in a log line and in the rendered answer.
    static let maxSynthesizedLength = 48

    static func resolve(_ raw: String, fallbackFrom text: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let slug = synthesize(from: text)
        // A prompt of pure punctuation slugs to nothing; a stable literal beats an empty id,
        // and the duplicate check upstream turns a second one into a loud error rather than a
        // silently merged answer.
        return slug.isEmpty ? "q" : slug
    }

    static func synthesize(from text: String) -> String {
        var out = ""
        var lastWasSeparator = false
        // Counted, not measured: `out.count` walks the grapheme clusters of everything
        // appended so far, so asking it once per character turns a linear pass over a long
        // prompt into a quadratic one. Ranked by the complexity axis `a5`.
        var length = 0
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                length += 1
                lastWasSeparator = false
            } else if !lastWasSeparator, length > 0 {
                out.append("_")
                length += 1
                lastWasSeparator = true
            }
            if length >= maxSynthesizedLength { break }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }
}

// MARK: - Loose enum parsing

nonisolated extension SupervisorInquiryKind {
    /// Case- and separator-insensitive lookup: a model that writes `singleChoice`,
    /// `single-choice` or `SINGLE_CHOICE` meant the same thing, and refusing over the
    /// spelling costs a round trip that teaches nothing.
    static func fromLooseString(_ raw: String) -> SupervisorInquiryKind? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return allCases.first {
            $0.rawValue.replacingOccurrences(of: "_", with: "") == normalized
        }
    }
}
