import Foundation

/// How an external server's tool is named for the model, and how that name is read back.
///
/// Two servers can both publish `search`, and a role can hold both. Namespacing is what
/// keeps the second one from shadowing the first — the documented cross-server attack, and
/// also just an ordinary collision. The shape is `mcp__<slug>__<tool>`:
///
///  - `mcp__` marks the family without a `ToolCategory` case, so none of the fifteen sets
///    fed by `ToolHandlerRegistry.allTypes` has to learn about a tool family that is not a
///    `ToolHandler` at all. `isMCPName` is the predicate.
///  - `<slug>` is the user's short name for the server, entered in Settings.
///  - `<tool>` is the server's own tool name, lowercased with anything outside
///    `[a-z0-9_]` folded to `_`.
///
/// **Why the character set is this narrow.** `PromptFormatConventionsTests` pins every tool
/// name the renderer prints to `[a-z0-9_]+` — a hyphen would fail the pin, and the pin is
/// right: the name is printed into prose the model reads back as an identifier. Folding is
/// lossy on purpose; the ORIGINAL name is what `tools/call` sends, so nothing depends on the
/// folded form round-tripping.
nonisolated enum MCPToolNaming {

    /// Marks the family. Double underscore so a server slug containing a single `_` cannot
    /// be mistaken for the separator.
    static let prefix = "mcp__"

    static let separator = "__"

    /// Longest slug a user may enter. Short enough that `mcp__<slug>__<tool>` stays a name
    /// rather than a paragraph.
    static let maxSlugLength = 32

    // MARK: - Slugs

    /// A slug is lowercase alphanumerics and single underscores, starting with an
    /// alphanumeric.
    ///
    /// `__` is refused inside a slug even though the character class would allow it: the
    /// separator is `__`, and a slug spelling it would make `mcp__a__b__c` ambiguous
    /// between server `a` tool `b__c` and server `a__b` tool `c`.
    static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= maxSlugLength else { return false }
        guard !slug.contains(separator) else { return false }
        guard let first = slug.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return slug.allSatisfy { isAllowedNameCharacter($0) }
    }

    /// Why a slug was refused, for the Settings editor's live validation. Each case names
    /// the repair rather than the rule.
    enum SlugRejection: Equatable {
        case empty
        case tooLong(max: Int)
        case badFirstCharacter
        case badCharacters
        case doubleUnderscore

        var message: String {
            switch self {
            case .empty:
                return "Enter a short name — lowercase letters, digits and underscores."
            case .tooLong(let max):
                return "Shorten the name to \(max) characters or fewer."
            case .badFirstCharacter:
                return "Start the name with a lowercase letter or a digit."
            case .badCharacters:
                return "Use only lowercase letters, digits and underscores — replace anything else."
            case .doubleUnderscore:
                return "Use a single underscore — a double underscore separates the server from the tool."
            }
        }
    }

    static func rejection(forSlug slug: String) -> SlugRejection? {
        if slug.isEmpty { return .empty }
        if slug.count > maxSlugLength { return .tooLong(max: maxSlugLength) }
        if slug.contains(separator) { return .doubleUnderscore }
        guard let first = slug.first, first.isASCII, first.isLowercase || first.isNumber else {
            return .badFirstCharacter
        }
        if !slug.allSatisfy({ isAllowedNameCharacter($0) }) { return .badCharacters }
        return nil
    }

    /// A slug proposal for a display name, so the Add sheet can prefill one. Best effort:
    /// the result is still validated, because a name of only punctuation has no slug.
    static func suggestedSlug(from displayName: String) -> String {
        // A run of underscores is collapsed in ONE pass. The rescan-and-replace loop this
        // replaced walked the whole string again per round, and the input is a display name
        // the user types — short in practice, unbounded in principle.
        var folded = ""
        for character in fold(displayName) where !(character == "_" && folded.hasSuffix("_")) {
            folded.append(character)
        }
        folded = String(folded.prefix(maxSlugLength))
        while let first = folded.first, !(first.isLowercase || first.isNumber) {
            folded.removeFirst()
        }
        while folded.hasSuffix("_") { folded.removeLast() }
        return folded
    }

    // MARK: - Tool names

    /// The name the model sees. `nil` when the server's tool name folds to nothing —
    /// a name of only punctuation is not a tool this client will advertise.
    static func modelFacingName(slug: String, toolName: String) -> String? {
        guard isValidSlug(slug) else { return nil }
        let folded = foldToolName(toolName)
        guard !folded.isEmpty else { return nil }
        return prefix + slug + separator + folded
    }

    /// The model-facing name for a synthesized read-only resource or resource-template tool:
    /// `mcp__<slug>__read_resource__<folded_resource_name>`.
    static func resourceModelFacingName(slug: String, resourceName: String) -> String? {
        guard isValidSlug(slug) else { return nil }
        let folded = foldToolName(resourceName)
        guard !folded.isEmpty else { return nil }
        return prefix + slug + separator + "read_resource" + separator + folded
    }

    /// The server's tool name, lowercased and folded into `[a-z0-9_]`. Runs of folded
    /// characters collapse to one underscore so `get-design context` and `get design-context`
    /// do not become two different names for the same intent.
    static func foldToolName(_ toolName: String) -> String {
        var folded = fold(toolName)
        while folded.hasPrefix("_") { folded.removeFirst() }
        while folded.hasSuffix("_") { folded.removeLast() }
        return folded
    }

    /// Whether a name belongs to the MCP family. The predicate every seam uses instead of a
    /// `ToolCategory` case.
    static func isMCPName(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.count > prefix.count
    }

    /// The whole-server grant a role can hold instead of listing every tool:
    /// `mcp__<slug>`, which expands to that server's approved tools at resolution time.
    static func serverGrant(slug: String) -> String { prefix + slug }

    /// Whether a `toolIDs` entry is a whole-server grant rather than one tool.
    static func isServerGrant(_ name: String) -> Bool {
        guard isMCPName(name) else { return false }
        return !name.dropFirst(prefix.count).contains(separator)
    }

    /// The slug a model-facing name or a whole-server grant belongs to.
    static func slug(ofName name: String) -> String? {
        guard isMCPName(name) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        guard let range = rest.range(of: separator) else {
            return isValidSlug(rest) ? rest : nil
        }
        let slug = String(rest[rest.startIndex..<range.lowerBound])
        return isValidSlug(slug) ? slug : nil
    }

    /// The folded tool name inside a model-facing name — the half after the server's slug.
    /// `nil` for a whole-server grant, which names no tool.
    static func foldedToolName(ofName name: String) -> String? {
        guard isMCPName(name) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        guard let range = rest.range(of: separator) else { return nil }
        let tool = String(rest[range.upperBound...])
        return tool.isEmpty ? nil : tool
    }

    // MARK: - Folding

    private static func isAllowedNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character == "_" || character.isNumber || (character.isLetter && character.isLowercase)
    }

    /// Lowercases and folds everything outside `[a-z0-9_]` to a single `_`.
    private static func fold(_ text: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        for character in text.lowercased() {
            if isAllowedNameCharacter(character), character != "_" {
                out.append(character)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        return out
    }
}
