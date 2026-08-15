import Foundation

nonisolated struct StepToolCall: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    /// Optional provider tool_call id (OpenAI field).
    var providerID: String?
    var name: String
    /// Raw JSON string (may be partial/invalid JSON if model streamed malformed args; stored verbatim).
    var argumentsJSON: String
    /// Result JSON from tool execution (nil if not yet executed).
    var resultJSON: String?
    /// Whether the tool execution resulted in an error.
    var isError: Bool?

    /// Set when the parser had to REPAIR this call's argument structure — today, when the
    /// model closed its `arguments` object (or the whole call object) before it had
    /// finished writing the members, so parameters were recovered from outside the
    /// wrapper. Nil for every call the model emitted correctly.
    ///
    /// Exists because the repair is otherwise invisible to the one party that can stop
    /// re-emitting the defect. `gemma-4-26b-a4b-qat` sent the shape twice eight seconds
    /// apart in the same step (`network_log.json`, 2026-08-13), and a silent fix would
    /// have let it keep doing so for the rest of the run. The note rides the tool RESULT
    /// (spliced in `+ToolResultDispatching`), not a separate conversation turn: a turn
    /// would grow the prompt prefix on every occurrence, and the result is already going
    /// to the model anyway.
    ///
    /// Optional so the synthesized decoder reads pre-existing `task.json` files that have
    /// no such key.
    var argumentRepairNote: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        providerID: String? = nil,
        name: String,
        argumentsJSON: String,
        resultJSON: String? = nil,
        isError: Bool? = nil,
        argumentRepairNote: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
        self.isError = isError
        self.argumentRepairNote = argumentRepairNote
    }

    /// The `message` out of this call's error result, in EITHER envelope shape.
    ///
    /// Information Expert: the call owns its result, so every surface that asks "why did
    /// that tool call fail" reads it here instead of re-spelling the dictionary walk. Two
    /// did — the Autovisor's `task_status.last_error` and the generated-team graph panel —
    /// and they had already drifted, one rejecting a whitespace-only message where the
    /// other rendered it as a blank error pane.
    ///
    /// **Two shapes, because the app emits two.** `ToolErrorHandler` nests
    /// (`{"ok":false,"error":{"code":…,"message":…}}`); the EXECUTOR writes the code as a
    /// top-level string beside a top-level message
    /// (`{"error":"tool_not_authorized","message":…}`) — that is every rejection it makes
    /// itself: `tool_not_authorized`, `precondition_failed`, `plan_required`,
    /// `identical_write_loop`. Reading only the nested shape returned `nil` for all four,
    /// so the manager was handed `Role 'X' failed.` for a step whose last error named a
    /// missing `.git` or an unselected Xcode scheme — both things it can act on.
    ///
    /// The top-level branch requires `error` to be a STRING, not merely present: that is
    /// what keeps a success envelope carrying an unrelated `message` from being read as a
    /// failure.
    ///
    /// Whitespace-only is treated as ABSENT: a message that renders as nothing is not a
    /// diagnosis, and every caller has a better generic fallback for that case.
    ///
    /// Lives here rather than on `ToolError` (which owns the envelope's error SHAPE) so the
    /// Domain layer keeps reading downwards only — `AutovisorStatus` is Domain and would
    /// otherwise be the first Domain type to reference one from `Services/Tools`.
    var errorMessage: String? {
        guard let resultJSON,
              let dict = JSONUtilities.parseJSONDictionary(resultJSON)
        else { return nil }
        let raw: String?
        if let nested = dict["error"] as? [String: Any] {
            raw = nested["message"] as? String
        } else if dict["error"] is String {
            raw = dict["message"] as? String
        } else {
            raw = nil
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return raw
    }

    /// True while a vision analysis is in progress (interim placeholder result).
    /// Matches the structured `"status":"analyzing"` marker set by `VisionHandlers.swift`.
    var isAnalyzing: Bool {
        name == ToolNames.analyzeImage
            && resultJSON?.contains("\"status\":\"analyzing\"") == true
            && isError != true
    }

    /// True while a team generation is in progress (interim placeholder result).
    /// Matches the structured `"status":"generating"` marker set at generation start.
    var isGeneratingTeam: Bool {
        name == ToolNames.createTeam
            && resultJSON?.contains("\"status\":\"generating\"") == true
            && isError != true
    }

    /// True when this `search` call requested exploratory mode but it was downgraded
    /// to plain search because the user has `exploratorySearchEnabled = false`.
    /// Matches the `"exploratory_disabled":true` flag set by `ExploratorySearchEnvelope.make`.
    var isExploratorySearchDisabled: Bool {
        name == ToolNames.search
            && resultJSON?.contains("\"exploratory_disabled\":true") == true
            && isError != true
    }
}
