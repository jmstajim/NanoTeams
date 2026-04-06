import Foundation

extension Array where Element == String {
    /// Normalize string array: trim whitespace, remove empty/duplicate entries, sort case-insensitive.
    /// Preserves first-occurrence order before sorting.
    func normalizedUnique() -> [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
