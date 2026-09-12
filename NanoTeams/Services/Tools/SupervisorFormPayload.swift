import Foundation

// MARK: - Supervisor form payload

/// What the model ASKED, read out of `ask_supervisor_form`'s arguments — the whole decision,
/// and nothing about how a tool result is shaped.
///
/// It lived inside `AskSupervisorFormTool.handle` until 2026-09-13, welded to
/// `ToolExecutionResult` construction, and that made it unreachable from the second seam that
/// needs it: the delegated Supervisor exchange (`DelegatedSupervisorAnswerService`), which has
/// no tool runtime at all — it reads a parking call off the wire and must route the whole
/// questionnaire up to the grandparent. Until the split that seam knew only `ask_supervisor`,
/// and a form call fell through its answer branch with empty content, delivering the literal
/// `"(no answer provided)"` to a child team as the Supervisor's decision (DEBTS D-B14).
///
/// Two jobs, so two types: this one decides what was asked, the handler shapes the envelope.
/// The ladder must not be duplicated — a second `JSONDecoder().decode(SupervisorInquiry.self,)`
/// on the delegated path would refuse the `«»`-quoted and one-closer-short payloads the tool
/// seam READS, and the two seams would disagree about what the model asked.
nonisolated enum SupervisorFormPayload {

    /// The states `INVALID_ARGS` covers for this tool. One code, five recoveries — so each
    /// state names itself in `error.details.diagnosis` rather than sharing one message
    /// (playbook R1.8.5; the slot is R3.5.3's, and `edit_file`'s four-value diagnosis is the
    /// precedent this follows).
    enum Diagnosis: String, Sendable {
        /// A parsed object carrying a value JSON cannot express.
        case unrepresentableValue = "unrepresentable_value"
        /// Text that never parsed, and no repair applied to it.
        case notJSON = "not_json"
        /// Text that still does not parse after its spelling was repaired.
        case notJSONAfterRepair = "not_json_after_repair"
        /// It parsed; the decoder refused the shape, naming the coding path.
        case questionRejected = "question_rejected"
        /// It parsed and decoded; a choice offers fewer answers than a choice can have.
        case tooFewOptions = "too_few_options"
    }

    /// A questionnaire the ladder could read, with everything the model cannot see for itself.
    struct Read: Sendable {
        let inquiry: SupervisorInquiry
        /// Questions the model wrote that per-element tolerance dropped. It believes it asked
        /// them and will never get an answer to them.
        let droppedQuestions: Int
        /// Every ADOPTED rewrite, for `meta.warnings` (playbook REC.5).
        let repairs: [String]
    }

    /// A questionnaire the ladder could not read, already diagnosed.
    struct Refusal: Sendable {
        let diagnosis: Diagnosis
        let message: String
        let repairs: [String]
    }

    enum Outcome: Sendable {
        case read(Read)
        case refused(Refusal)
    }

    /// The tool seam's entry point.
    ///
    /// Throws `ToolArgumentError` for the argument-SHAPE faults — `form` absent, or present as
    /// neither object nor string. Those are not diagnoses: `ToolErrorHandler.execute`
    /// classifies them, and reporting "Missing" for an argument the model just sent would send
    /// it hunting for a phantom omission.
    static func read(args: [String: Any]) throws -> Outcome {
        // Both argument shapes, exactly as `CreateTeamTool` accepts them. The OBJECT is
        // the declared one since 2026-09-12; the string is tolerance for a model that
        // serialises anyway, and it keeps the whole repair ladder below reachable.
        // `argumentTypeViolations` refuses neither, because it judges only
        // `boolean`/`integer`/`array` and both `object` and `string` fall to its
        // `default: continue`.
        let jsonData: Data
        // The text as the model wrote it, when it sent text: decoded raw first, and only
        // a SYNTAX failure runs `SupervisorFormTextRepair` over it — a valid form is
        // never rewritten, a validation failure never reaches it (the text parsed).
        var formText: String?
        if let formDict = args["form"] as? [String: Any] {
            // `isValidJSONObject` FIRST. For a value JSON cannot express (NaN, a non-String
            // key) `data(withJSONObject:)` raises an ObjC `NSInvalidArgumentException` — it
            // does not throw, so no Swift catch sees it and the process dies. This guard is
            // the only defence, which is why no local do/catch sits below it pretending to
            // be a second one.
            guard JSONSerialization.isValidJSONObject(formDict) else {
                return .refused(unrepresentableValue)
            }
            jsonData = try JSONSerialization.data(withJSONObject: formDict)
            // Read straight off `args`, never through `requiredString`: that helper falls back
            // to `__raw_input__` — the whole unparseable arguments blob — for ANY key, so the
            // ladder would run three structural repairs over a tool-call envelope and report
            // its brackets to the model as the form's.
        } else if let formString = args["form"] as? String,
                  let data = formString.data(using: .utf8) {
            jsonData = data
            formText = formString
        } else if !args.keys.contains("form"), args["questions"] is [Any] {
            // The form's CONTENT written straight into the arguments — the shape the
            // description's old example taught, and the one emission of the 2026-09-12
            // field runs that was syntactically flawless on the first try (task 71 run 4:
            // five well-formed questions, refused for a missing `form`, rewritten by hand
            // twice). `headline` rides beside it and is applied below either way, so
            // handing the whole argument dictionary to the envelope decoder costs nothing
            // and asks the question the model actually wrote.
            guard JSONSerialization.isValidJSONObject(args) else {
                return .refused(unrepresentableValue)
            }
            jsonData = try JSONSerialization.data(withJSONObject: args)
        } else if let present = args["form"] {
            // Present but neither shape. Reporting "Missing" for an argument the model
            // just sent it hunting for a phantom omission: a questionnaire arriving as a
            // bare `questions` ARRAY under `form` is the live shape this catches.
            throw ToolArgumentError.invalidValue(
                key: "form",
                detail: "must be the questionnaire object; received "
                    + "\(ToolArgumentError.jsonTypeName(of: present)).")
        } else {
            throw ToolArgumentError.missingRequired("form")
        }

        var decoded: SupervisorInquiryEnvelope
        var repairs: [String] = []
        do {
            decoded = try decode(jsonData)
        } catch let rawError {
            // An error, NOT a park. A step parked on a form nobody can render waits for an
            // answer to a question that was never asked; an error is a thing the model can
            // read and fix in one more call.
            //
            // Only text the model SENT that failed to PARSE is repaired; a validation
            // failure, or a form that arrived as an object, is reported as it is.
            guard let formText, SupervisorFormDecoding.isSyntaxFailure(rawError) else {
                return .refused(Refusal(
                    diagnosis: .questionRejected,
                    message: SupervisorFormDecoding.message(
                        rawError, in: String(data: jsonData, encoding: .utf8)),
                    repairs: []))
            }
            // A ladder, raw rung first, each rung decoded and the first that succeeds
            // adopted (the shape of `HarmonyToolCallParsingHelpers.parseAfterRepair`;
            // playbook REC.5 bounds it and R3.8.7 licenses it):
            //   1. the text as sent — already tried, that is `rawError`;
            //   2. its SPELLING repaired: strings the model quoted with « », surplus
            //      closers after the end (task 52 runs 9–11, 2026-09-11);
            //   3. one dropped structural closer put back (task 65 run 0, 2026-09-11);
            //   4. the form's OWN closing bracket put back, when that is the only one
            //      missing (task 67 run 1, 2026-09-11).
            // Both closer rungs are a guess about STRUCTURE, so each is adopted only
            // because the decode then succeeds, never because the scan found a place.
            let spelling = SupervisorFormTextRepair.repair(formText)
            var spelledError = rawError
            var climbed: (envelope: SupervisorInquiryEnvelope, notes: [String])?

            if spelling.changed {
                do {
                    climbed = (try decode(Data(spelling.text.utf8)), spelling.notes)
                } catch {
                    spelledError = error
                }
            }
            if climbed == nil,
               let padded = JSONStructuralCloserRepair.insertingDroppedCloser(
                   in: spelling.text),
               let envelope = try? decode(Data(padded.utf8)) {
                climbed = (envelope,
                           spelling.notes + [SupervisorFormTextRepair.insertedCloserNote])
            }
            if climbed == nil,
               let closed = JSONStructuralCloserRepair.closingTheTopLevelContainer(
                   in: spelling.text),
               let envelope = try? decode(Data(closed.utf8)) {
                climbed = (envelope,
                           spelling.notes + [SupervisorFormTextRepair.closedTheFormNote])
            }
            guard let climbed else {
                // The excerpt is cut from the SPELLED text — cut from the raw text it
                // would point at a `«` that is no longer there. The closer rung leaves no
                // trace here: it was not adopted, so it is not reported as done.
                // The state is read off the error that actually fired, not off whether a
                // repair ran: a text whose « » were read can still be REFUSED by the
                // decoder, and that is `question_rejected` with a coding path, not a
                // syntax failure the model should hunt a character for.
                let syntax = SupervisorFormDecoding.isSyntaxFailure(spelledError)
                return .refused(Refusal(
                    diagnosis: syntax
                        ? (spelling.changed ? .notJSONAfterRepair : .notJSON)
                        : .questionRejected,
                    message: SupervisorFormDecoding.message(spelledError, in: spelling.text),
                    repairs: spelling.notes))
            }
            decoded = climbed.envelope
            repairs = climbed.notes
        }
        // Resolved only now, because the two fallbacks both live in the decoded document.
        // In preference order: the sibling ARGUMENT, which is where the schema puts it;
        // then a headline the model nested INSIDE the form, which is a spelling of the
        // same intent and not worth refusing; then one derived from the first question
        // (`SupervisorInquiryHeadlineFallback`), because the model writes `form` first
        // and stops when it closes. The dispatcher still never parks on empty text — the
        // same reason `ask_supervisor` insists on a non-empty question — it is just no
        // longer the MODEL that has to guarantee it.
        let headline: String
        if let authored = try? requiredNonEmptyString(args, "headline") {
            headline = authored
        } else if let nested = decoded.authoredHeadline {
            headline = nested
            repairs.append(SupervisorInquiryHeadlineFallback.nestedNote)
        } else if let derived = SupervisorInquiryHeadlineFallback.headline(
            for: decoded.inquiry.questions)
        {
            headline = derived
            repairs.append(SupervisorInquiryHeadlineFallback.note)
        } else {
            throw ToolArgumentError.missingRequired("headline")
        }
        decoded.applyHeadline(headline)
        let droppedQuestions = decoded.authoredCount - decoded.inquiry.questions.count
        // Labels last, on BOTH argument shapes: a `(recommended)` marker or a leading
        // number in a label is read for the intent it spells and reported alongside.
        let labels = SupervisorInquiryLabelRepair.apply(to: decoded.inquiry)
        repairs += labels.notes

        // Syntax is not completeness. A tolerant parse can turn a truncated emission into
        // a document that decodes — the closer rung closes the object the model abandoned
        // — and what it decodes into is a choice offering one answer. Refusing that here
        // is the fail-closed validator of playbook R3.7.6; without it the repair would
        // launder truncation into a form the human is asked to fill in.
        if let fault = SupervisorInquiryCompleteness.fault(in: labels.inquiry) {
            return .refused(Refusal(
                diagnosis: .tooFewOptions, message: fault, repairs: repairs))
        }

        return .read(Read(
            inquiry: labels.inquiry, droppedQuestions: droppedQuestions, repairs: repairs))
    }

    /// For a caller holding a PERSISTED `argumentsJSON` and no tool runtime — the delegated
    /// Supervisor exchange, which reads the parking call off the wire rather than executing it.
    ///
    /// `nil` when even the envelope is not a JSON object, which is the one state the tool seam
    /// cannot reach (a handler is only ever called with parsed arguments) and the wire reader
    /// can: there is nothing to diagnose to a model that is not being answered.
    static func read(argumentsJSON: String) -> Outcome? {
        guard let data = argumentsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let args = parsed as? [String: Any]
        else { return nil }
        // A shape fault throws here rather than returning, exactly as it does at the tool
        // seam; this caller has no error channel, so it reads as "nothing could be read".
        return try? read(args: args)
    }

    private static let unrepresentableValue = Refusal(
        diagnosis: .unrepresentableValue,
        message: "form contains a value JSON cannot represent (NaN/infinity, "
            + "a non-string key, or a non-JSON type). Send plain JSON strings, "
            + "numbers, booleans, arrays and objects only.",
        repairs: [])

    private static func decode(_ data: Data) throws -> SupervisorInquiryEnvelope {
        try JSONCoderFactory.makeWireDecoder().decode(SupervisorInquiryEnvelope.self, from: data)
    }
}
// MARK: - Form payload envelope

/// The `form` argument's own shape: `{"questions": [...]}`, with the headline supplied
/// separately as a sibling argument.
///
/// A wrapper rather than decoding `SupervisorInquiry` directly, because the headline lives
/// OUTSIDE the JSON blob — it is a first-class argument so a provider that truncates the long
/// one still delivers the line every surface renders, and so the streaming card can show it
/// before the body finishes arriving.
///
/// It is read INSIDE the document too, and kept rather than dropped
/// (`authoredHeadline`): the model nests it there — 2 of 68 field calls, and in one of them
/// that was the only copy, so deriving one from the questions would have discarded a headline
/// the model had written (MeditationApp task 75 run 9, 2026-09-12). The decoder still cannot
/// USE it, because `SupervisorInquiry` refuses a blank one and the document may legitimately
/// carry none; the placeholder stands until the tool seam chooses between the sibling
/// argument, this, and the fallback.
nonisolated private struct SupervisorInquiryEnvelope: Decodable {
    private(set) var inquiry: SupervisorInquiry
    /// How many entries the model wrote, before per-element tolerance dropped any.
    ///
    /// The difference between this and `inquiry.questions.count` is the one thing the model
    /// cannot see for itself: a dropped question is a question it believes it asked and will
    /// never get an answer to. Reporting the count is cheap; making it notice a silent
    /// shortening is not.
    private(set) var authoredCount: Int
    /// A headline the model wrote INSIDE the document, trimmed; nil when it wrote none there.
    private(set) var authoredHeadline: String?

    init(from decoder: Decoder) throws {
        // Decoded through `SupervisorInquiry` itself so there is exactly one set of validation
        // rules; the placeholder headline is replaced before anything reads it.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let questions = try c.decodeIfPresent([Failable<SupervisorInquiryQuestion>].self, forKey: .questions) ?? []
        authoredCount = questions.count
        let nested = ((try? c.decodeIfPresent(String.self, forKey: .headline)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        authoredHeadline = (nested?.isEmpty == false) ? nested : nil
        inquiry = try SupervisorInquiry(
            headline: SupervisorInquiryEnvelope.headlinePlaceholder,
            validating: questions.compactMap(\.value),
            emptyWasAuthored: !questions.isEmpty,
            codingPath: [CodingKeys.questions])
    }

    mutating func applyHeadline(_ headline: String) {
        inquiry = SupervisorInquiry(headline: headline, questions: inquiry.questions)
    }

    private enum CodingKeys: String, CodingKey { case questions, headline }
    fileprivate static let headlinePlaceholder = "-"
}
