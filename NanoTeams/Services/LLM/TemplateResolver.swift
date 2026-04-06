import Foundation

// MARK: - Template Resolver

/// Stateless template resolver for `{placeholder}` substitution in prompt templates.
/// Extracted from SystemTemplates to keep the Domain layer free of service-level logic.
enum TemplateResolver {

    /// Resolves a template string by replacing `{key}` placeholders with values from the dictionary.
    static func resolve(_ template: String, placeholders: [String: String]) -> String {
        var result = template
        for (key, value) in placeholders {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
