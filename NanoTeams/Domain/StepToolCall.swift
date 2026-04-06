import Foundation

struct StepToolCall: Codable, Identifiable, Hashable {
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

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        providerID: String? = nil,
        name: String,
        argumentsJSON: String,
        resultJSON: String? = nil,
        isError: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
        self.isError = isError
    }

    /// True while a vision analysis is in progress (interim placeholder result).
    /// Matches the structured `"status":"analyzing"` marker set by `Tools+Vision.swift`.
    var isAnalyzing: Bool {
        name == ToolNames.analyzeImage
            && resultJSON?.contains("\"status\":\"analyzing\"") == true
            && isError != true
    }
}
