import Foundation

/// Option text as the model writes it, normalized to what the card renders — and the
/// recommendation READ OUT of it.
///
/// Two jobs, one pass, because both read the same strings. A model used to numbered lists
/// numbers its labels (`"1. Чистый light"`, MeditationApp task 52 run 11) beside radio
/// buttons, and a model that wants to recommend one says so — as a marker in the label
/// (`«Мини-редизайн (recommended)»`, run 10) or, far more often, as the first word of that
/// option's `detail` («Рекомендую — пользователи выбирают в системе»). Each is a standard
/// spelling of a valid intent (playbook R1.8.4, R3.8.7): the number is read as nothing, the
/// recommendation is read as `recommendedOptionID`, and every adopted REWRITE is reported in
/// `meta.warnings` (REC.5).
///
/// Reading the recommendation is not a rewrite and is reported nowhere. The questionnaire the
/// human answers carries the same questions, options, order and text either way; only the
/// badge moves, which is what the model asked for by writing the word. Reporting it cost the
/// trainer's own ruler: `FormEmissionClassifier.isClean` reads `meta.warnings.count`, so nine
/// of twenty-two emissions scored as repaired for having been read correctly (task 84,
/// 2026-09-12). Stripping the marker from a LABEL is a rewrite, and that one is still
/// reported.
///
/// Nothing is ASKED for. The description does not teach a marker spelling, because the field
/// archive shows models already writing one unprompted, in the Supervisor's own language, and
/// because this wire carries no grammar — a taught key would be one more thing to emit and to
/// get wrong (KF3, R3.7.6), paid for in a description whose every word rides every call.
///
/// It RESOLVES rather than REORDERS. Until 2026-09-12 a marked option was moved to index 0,
/// because the recommendation was a position; the order the model chose carried meaning of its
/// own (the archived design form lists by scope), and destroying it to encode one bit was the
/// cost of having nowhere else to put that bit. There is somewhere now.
///
/// Applied at the TOOL seam, after decoding — never inside `SupervisorInquiry.init(from:)`.
/// That decoder also reads the questionnaire persisted on the step
/// (`StepExecution.supervisorInquiry`), and `SupervisorInquiry.identity` folds ids, labels and
/// ORDER: a normalization there would rewrite a parked questionnaire on reload, change its
/// identity, and orphan every draft answer given to it (`SupervisorInquiryDraft.answer(for:)`).
///
/// Ids follow the label only when they were derived from it — an id the model authored is
/// its own — and a collision after stripping (`"1. Debug"` and `"Debug (recommended)"` both
/// slug to `debug`) keeps every raw id of that question: the decoder's duplicate rule
/// guarantees they were distinct, and silently merging two options is the failure this
/// pass must not introduce.
nonisolated enum SupervisorInquiryLabelRepair {

    struct Outcome: Equatable, Sendable {
        let inquiry: SupervisorInquiry
        let notes: [String]
    }

    /// The enumeration a list item opens with — `1.` `1)` `(1)` `a)` — shared with
    /// `SupervisorQuestionShape`, which counts the same items in a plain ask's prose.
    static let enumerationItemStem = #"(?:\d{1,2}[.)]|\(\d{1,2}\)|[a-zа-я]\))"#
    /// The word that marks a recommended item, in both languages the field runs write.
    ///
    /// Shared VERBATIM with `SupervisorQuestionShape.recommendedItem`, the gate that turns a
    /// plain ask carrying options into `QUESTIONNAIRE_REQUIRED`. Widening it here (to the noun
    /// «рекомендация», to a participle) widens that gate too and starts refusing plain asks
    /// that merely mention a recommendation, so the stem is read from more PLACES rather than
    /// made to match more WORDS.
    static let recommendedWordStem = #"(?:recommended|рекоменду\w*)"#

    static func apply(to inquiry: SupervisorInquiry) -> Outcome {
        var questions: [SupervisorInquiryQuestion] = []
        var enumerated = 0
        var markersRemoved = 0
        for question in inquiry.questions {
            guard !question.options.isEmpty else {
                questions.append(question)
                continue
            }
            var options: [SupervisorInquiryOption] = []
            var markedIndices: [Int] = []
            // Where an ALREADY-resolved recommendation sits, captured against the RAW id in
            // the same walk that rebuilds the options — a rewritten label recomputes a derived
            // id, so the id itself cannot be carried across, only the position can.
            var carriedIndex: Int?
            for (index, option) in question.options.enumerated() {
                let (label, marked, numbered) = normalizedLabel(option.label)
                if numbered { enumerated += 1 }
                if marked { markedIndices.append(index) }
                if option.id == question.recommendedOptionID { carriedIndex = index }
                options.append(rebuilt(option, label: label))
            }
            // Ids that now collide would merge two options' answers; keep the raw ids then.
            if Set(options.map(\.id)).count < options.count {
                options = zip(options, question.options).map { repaired, raw in
                    SupervisorInquiryOption(id: raw.id, label: repaired.label, detail: raw.detail)
                }
            }
            markersRemoved += markedIndices.count
            // The label marker wins over the detail sentence when the model wrote both: it is
            // the more deliberate spelling, and it is the one the model was shown in a
            // previous form's rendering. Detail prose is the fallback, and by far the commoner
            // one in the field.
            var recommended = resolve(markedIndices, in: options)
            if recommended == nil {
                recommended = resolve(leadingRecommendIndices(in: options), in: options)
            }
            // A resolution already made survives a second pass. The marker that produced it
            // was STRIPPED from the label, so re-reading finds nothing — and clearing the field
            // on the way would make this pass lose the very thing it exists to find, the second
            // time a questionnaire goes through it.
            if recommended == nil, let carried = carriedIndex {
                recommended = options[carried].id
            }
            questions.append(SupervisorInquiryQuestion(
                id: question.id, prompt: question.prompt, detail: question.detail,
                kind: question.kind, options: options, recommendedOptionID: recommended))
        }
        var notes: [String] = []
        if enumerated > 0 { notes.append(enumerationNote(count: enumerated)) }
        if markersRemoved > 0 { notes.append(recommendedMarkerNote(count: markersRemoved)) }
        // The rebuilt inquiry, always. `notes.isEmpty` used to mean "nothing changed" and
        // returned the original — until this pass gained a change that is deliberately NOT
        // reported: resolving `recommendedOptionID` rewrites nothing the human answers, so it
        // earns no note, and an early return keyed on notes threw the resolution away. The
        // rebuild is byte-identical when nothing changed.
        return Outcome(
            inquiry: SupervisorInquiry(headline: inquiry.headline, questions: questions),
            notes: notes)
    }

    // MARK: - Notes

    /// runtime-prompt
    static func enumerationNote(count: Int) -> String {
        "\(count) option label(s) began with a number and were read without it — options "
            + "are chosen by position, not by number."
    }

    /// runtime-prompt
    ///
    /// The marker is stripped from the LABEL because a radio-button caption is a caption and
    /// the badge beside it already says this. A recommendation written in a `detail` is left
    /// alone: there it is the model's reason, in the Supervisor's language, and the badge is
    /// its summary rather than its duplicate.
    static func recommendedMarkerNote(count: Int) -> String {
        "The (recommended) marker was removed from \(count) option label(s) — the badge on "
            + "the card says it instead."
    }


    // MARK: - Reading the recommendation

    /// The one marked option's id — nil unless EXACTLY one is marked.
    ///
    /// Zero is the ordinary case and means what it says. Two or more is a question the model
    /// did not resolve for itself, and picking one of them would be the app deciding; both
    /// resolve to no recommendation, and neither is refused — a questionnaire is not worth
    /// bouncing over a badge (R1.8.1 would also require naming an argument this tool has no
    /// key for).
    private static func resolve(
        _ indices: [Int], in options: [SupervisorInquiryOption]
    ) -> String? {
        guard indices.count == 1, let only = indices.first, options.indices.contains(only) else {
            return nil
        }
        return options[only].id
    }

    /// Options whose `detail` OPENS with the recommend-word.
    ///
    /// The leading position is the whole false-positive defence, and it is free: in both
    /// languages the negation particle precedes the verb, so «Не рекомендую — ломает
    /// совместимость» and "Not recommended — deprecated" fail the anchor without a negation
    /// list to maintain, as do «Apple не рекомендует этот подход» (not first) and
    /// «Рекомендация Apple HIG» (the noun stem is not the verb stem). A recommendation
    /// mentioned in the middle of a sentence is prose, and reading prose for intent is what
    /// A32 refuses — reading the first word is reading a slot.
    private static func leadingRecommendIndices(in options: [SupervisorInquiryOption]) -> [Int] {
        var found: [Int] = []
        for (index, option) in options.enumerated() {
            guard let detail = option.detail else { continue }
            let range = NSRange(detail.startIndex..., in: detail)
            if leadingRecommendation.firstMatch(in: detail, range: range) != nil { found.append(index) }
        }
        return found
    }

    private static let leadingRecommendation = try! NSRegularExpression(
        pattern: #"^[\s*_(\["«“]*"# + recommendedWordStem + #"(?!\w)"#,
        options: [.caseInsensitive])

    // MARK: - Labels

    private static let leadingEnumeration = try! NSRegularExpression(
        pattern: "^" + enumerationItemStem + #"\s+"#)
    private static let trailingMarker = try! NSRegularExpression(
        pattern: #"\s*[(\[]\s*"# + recommendedWordStem + #"\s*[)\]]\s*$"#,
        options: [.caseInsensitive])

    /// The label without its enumeration and marker — or the label itself when stripping
    /// would leave nothing (a label that IS an enumeration is kept, and counted for nothing).
    private static func normalizedLabel(_ label: String) -> (label: String, marked: Bool, numbered: Bool) {
        var text = label
        var marked = false
        var numbered = false
        if let match = trailingMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let stripped = String(text[..<range.lowerBound])
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                text = stripped
                marked = true
            }
        }
        if let match = leadingEnumeration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let stripped = String(text[range.upperBound...])
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                text = stripped
                numbered = true
            }
        }
        return (text.trimmingCharacters(in: .whitespaces), marked, numbered)
    }

    /// The option with its new label — and a new id only when the old one was derived from
    /// the old label (`SupervisorInquiryIdentity.resolve` with no authored id).
    private static func rebuilt(_ option: SupervisorInquiryOption, label: String) -> SupervisorInquiryOption {
        guard label != option.label else { return option }
        let derived = option.id == SupervisorInquiryIdentity.resolve("", fallbackFrom: option.label)
        return SupervisorInquiryOption(
            id: derived ? SupervisorInquiryIdentity.resolve("", fallbackFrom: label) : option.id,
            label: label, detail: option.detail)
    }
}
