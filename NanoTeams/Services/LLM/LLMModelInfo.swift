import Foundation

/// One model as a server described it in its OWN list response.
///
/// The thing this replaces is a bare `[String]`: both providers hand back format and quantization
/// for every model in the same single response that yields the names — LM Studio's
/// `/api/v1/models` (`format`, `quantization.name`) and Ollama's `/api/tags`
/// (`details.format`, `details.quantization_level`) — and both were decoded and thrown away. Until
/// this type existed, nothing in the app could answer "what format is this model" without
/// MEASURING it, which is why the benchmark's model list read those two facts out of its own run
/// history and had nothing to show for a model nobody had measured yet.
///
/// Deliberately narrow, and `Identifiable` is deliberately absent by the same rule: `size_bytes`,
/// `params_string`, `max_context_length` and `capabilities` all ride the same payload, and nothing
/// puts these in a `ForEach` — a field or a conformance with no reader is a fact with no owner.
/// Each is a one-line addition on the day something renders it.
nonisolated struct LLMModelInfo: Equatable, Sendable {

    /// The name the server answers to, trimmed. The type's invariant, so callers never have to
    /// wonder which end trimmed it — every dictionary keyed on a model name, and every lookup
    /// against one, agree by construction.
    let name: String

    /// The model's file format, VERBATIM as the server spells it — `gguf`, `mlx`, `safetensors`.
    /// Never inferred: a server that does not report one leaves this nil rather than having a
    /// runtime guessed from its quantization.
    let format: String?

    /// The quantization, VERBATIM — `Q4_K_M`, `4bit`, `MXFP4`, `nvfp4`. Same no-inference rule.
    let quantization: String?

    /// Empty strings collapse to nil at this boundary, so "the server said nothing" has ONE
    /// spelling downstream. Both wire shapes can produce an empty value (an absent key on one
    /// build, an empty string on another), and leaving both alive would make every reader test for
    /// two things.
    init(name: String, format: String? = nil, quantization: String? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.format = Self.present(format)
        self.quantization = Self.present(quantization)
    }

    private static func present(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
