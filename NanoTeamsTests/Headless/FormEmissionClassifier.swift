import Foundation
@testable import NanoTeams

/// What one `ask_supervisor_form` ATTEMPT looked like, derived from `tool_calls.jsonl` alone.
///
/// One emission is one attempt by the model to send the questionnaire — dispatched or not.
/// The undispatched ones are the point: on the three field runs of 2026-09-12 two of seven
/// emissions never reached the handler at all (the outer `<|call|>` envelope did not parse),
/// and a measure that counted only handler calls would have reported those runs as one clean
/// park each.
nonisolated struct FormEmission: Codable, Equatable {

    /// Which argument shape the model reached for.
    ///
    /// Readable even when the envelope never parsed, which is exactly the case worth telling
    /// apart: `string` there means the model was still hand-escaping a document into one value
    /// when it lost its place, and that is the defect the schema change exists to remove.
    enum Shape: String, Codable {
        /// `"form": { … }` — the questionnaire as a nested object.
        case object
        /// `"form": "{ … }"` — the questionnaire hand-escaped into a string.
        case string
        /// `{"headline": …, "questions": […]}` — the form's own content written straight into
        /// the arguments, with no `form` wrapper.
        case questionsAtTop = "questions@top"
        /// The envelope parsed and carried no form argument of any shape.
        case absent
        /// The envelope did not parse and no `form`/`questions` key was legible in the text.
        case unknown
    }

    /// 1-based position among this run's form emissions, in call order.
    var attempt: Int
    var shape: Shape
    /// Whether the outer `<|call|>` envelope parsed — i.e. whether the call reached the handler.
    var envelopeParsed: Bool
    /// Whether the handler accepted the questionnaire (`ok: true`). False when the envelope
    /// never parsed, since nothing was decoded.
    var documentAccepted: Bool
    /// `error.details.diagnosis` when the handler named one, else the error code, else `"-"`.
    /// `malformed_tool_call` for an emission that never reached the handler.
    var diagnosis: String
    /// How many repairs the decode ladder had to adopt (`meta.warnings`). A park that needed
    /// two rewrites is not the same result as one that needed none.
    var repairs: Int

    /// The one outcome worth the name: accepted, first try, with nothing repaired.
    ///
    /// "Nothing repaired" is as far as `tool_calls.jsonl` can see, and that boundary is real:
    /// a call the HARMONY layer rescued — `ToolCallParsingHelpers.appliedRepairs`, e.g. the
    /// closers put back in nesting order — reaches the handler looking untouched, because the
    /// log records the re-encoded arguments and the repair note rides the step log instead.
    /// So this counts what the HANDLER was given, not what the model wrote. Measured live:
    /// 3 of 20 after-runs carried the reorder note while scoring clean here (2026-09-12).
    var isClean: Bool { envelopeParsed && documentAccepted && repairs == 0 }
}

/// What a set of runs did, as one row.
nonisolated struct FormEmissionSummary: Codable, Equatable {
    /// Runs that emitted at least one form attempt. A run that never reached for the tool is
    /// not evidence about the tool.
    var runs: Int
    var emissions: Int
    /// Runs whose FIRST emission was clean. The headline measure: everything else the ladder
    /// rescues is a round trip the human waited through.
    var cleanOnFirst: Int
    /// Runs that ended up parked on an accepted questionnaire, however many tries it took.
    var parked: Int
    /// Emissions per park — 1.0 is the floor, and the field baseline was 2.33.
    var callsPerPark: Double
    var shapeCounts: [String: Int]
    var diagnosisCounts: [String: Int]
}

/// Scores `ask_supervisor_form` emissions off a run's tool-call log.
///
/// Pure and log-derived on purpose: the same code scores a run the trainer has just produced
/// and a run recorded in the field weeks ago, so a before/after measurement cannot drift from
/// the tool that reads the archive (playbook REC.10). Nothing here asks the orchestrator
/// anything — a run directory is the whole input.
nonisolated enum FormEmissionClassifier {

    /// The card name `LLMExecutionService` writes for a `<|call|>` block that would not parse.
    private static let malformedName = "malformed_tool_call"

    // MARK: - One run

    /// Every form emission in one run's log, in call order.
    static func emissions(in records: [ToolCallLogRecord]) -> [FormEmission] {
        var result: [FormEmission] = []
        for record in records {
            let arguments = record.argumentsJSON
            let parsed = jsonObject(arguments)
            let isMalformed = record.toolName == Self.malformedName

            // Which tool the emission was FOR. A dispatched call says so in its own name; an
            // undispatched one says so only inside the envelope text it failed to parse, which
            // is why the name is read from there rather than the record being skipped.
            let target: String?
            let inner: [String: Any]?
            if isMalformed {
                target = (parsed?["name"] as? String) ?? quotedValue(ofKey: "name", in: arguments)
                inner = parsed?["arguments"] as? [String: Any]
            } else {
                target = record.toolName
                // `nil` rather than `[:]` when the arguments will not parse, so the text scan
                // below still gets a shot: a dispatched call's arguments are re-encoded by
                // `encodeArgsToJSON` and should always parse, but reading an absent form out of
                // a blank dictionary would be a fact the log never carried.
                inner = parsed
            }
            guard target == ToolNames.askSupervisorForm else { continue }

            let attempt = result.count + 1
            let shape = self.shape(arguments: arguments, inner: inner)
            guard !isMalformed else {
                result.append(FormEmission(
                    attempt: attempt, shape: shape, envelopeParsed: false,
                    documentAccepted: false, diagnosis: Self.malformedName, repairs: 0))
                continue
            }

            let envelope = jsonObject(record.resultJSON ?? "")
            let error = envelope?["error"] as? [String: Any]
            let details = error?["details"] as? [String: Any]
            let warnings = (envelope?["meta"] as? [String: Any])?["warnings"] as? [Any]
            result.append(FormEmission(
                attempt: attempt,
                shape: shape,
                envelopeParsed: true,
                documentAccepted: envelope?["ok"] as? Bool == true,
                diagnosis: (details?["diagnosis"] as? String) ?? (error?["code"] as? String) ?? "-",
                repairs: warnings?.count ?? 0))
        }
        return result
    }

    // MARK: - Many runs

    static func summarize(_ runs: [[FormEmission]]) -> FormEmissionSummary {
        let scored = runs.filter { !$0.isEmpty }
        let emissions = scored.flatMap { $0 }
        let parked = scored.filter { run in run.contains { $0.envelopeParsed && $0.documentAccepted } }
        return FormEmissionSummary(
            runs: scored.count,
            emissions: emissions.count,
            cleanOnFirst: scored.filter { $0[0].isClean }.count,
            parked: parked.count,
            // Against PARKS, not runs: a run that gave up without parking spent its calls on
            // nothing, and dividing by it would flatter the ratio exactly where it should not.
            callsPerPark: parked.isEmpty ? 0 : Double(emissions.count) / Double(parked.count),
            shapeCounts: counted(emissions.map(\.shape.rawValue)),
            diagnosisCounts: counted(emissions.map(\.diagnosis)))
    }

    private static func counted(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - Shape

    private static func shape(arguments: String, inner: [String: Any]?) -> FormEmission.Shape {
        if let inner {
            if inner["form"] is [String: Any] { return .object }
            if inner["form"] is String { return .string }
            if inner["questions"] != nil { return .questionsAtTop }
            return .absent
        }
        // Text-only fallback, for the envelope that never parsed. Both live malformed
        // emissions land here, and both were `string` — without this they would read as
        // `unknown` and the measure would lose the half of the evidence that names the cause.
        switch firstValueCharacter(ofKey: "form", in: arguments) {
        case "\"": return .string
        case "{": return .object
        default:
            return arguments.contains("\"questions\"") ? .questionsAtTop : .unknown
        }
    }

    // MARK: - Text scanning
    //
    // For the envelope that did NOT parse, so `JSONSerialization` is not an option and the
    // scan has to be tolerant of whatever broke it.

    /// The first non-whitespace character of `"key": …`, or nil when the key is absent.
    private static func firstValueCharacter(ofKey key: String, in text: String) -> Character? {
        guard let afterColon = afterColon(ofKey: key, in: text) else { return nil }
        return afterColon.first(where: { !$0.isWhitespace })
    }

    /// The string value of `"key": "…"`, or nil when the key is absent or not a string.
    private static func quotedValue(ofKey key: String, in text: String) -> String? {
        guard let afterColon = afterColon(ofKey: key, in: text),
              let open = afterColon.firstIndex(of: "\"")
        else { return nil }
        // Only a quote may separate the colon from the value — otherwise `"name": {…"x"…}`
        // would yield whatever string came first inside the object.
        guard afterColon[..<open].allSatisfy(\.isWhitespace) else { return nil }
        let valueStart = afterColon.index(after: open)
        guard let close = afterColon[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(afterColon[valueStart..<close])
    }

    private static func afterColon(ofKey key: String, in text: String) -> Substring? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        let tail = text[keyRange.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        return tail[tail.index(after: colon)...]
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
