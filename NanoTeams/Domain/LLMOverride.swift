import Foundation

/// Per-role LLM configuration override within a team.
/// If a field is nil, the global default is used for that field.
struct LLMOverride: Codable, Hashable {
    var baseURLString: String?
    var modelName: String?
    var maxTokens: Int?
    var temperature: Double?

    /// True when no fields are set (effectively no override).
    var isEmpty: Bool {
        baseURLString == nil && modelName == nil
            && maxTokens == nil && temperature == nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
    }

    init(
        baseURLString: String? = nil,
        modelName: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
