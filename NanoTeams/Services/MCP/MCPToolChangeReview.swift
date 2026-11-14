import Foundation

/// What changed in a rewritten tool, against the text the person approved.
///
/// **Both sides are rendered by one function**, from canonical text: the approved side from the
/// bytes the pin recorded (`MCPToolPin.approvedCanonicalJSON`), the live side from the same
/// canonical form of what the server sends now. A section that differs is a difference in the
/// text, never in how two code paths chose to print it.
///
/// **Readable first, raw always.** The description, the arguments as the prompt renders them,
/// the annotations and the titles are what a person can judge; but the argument rendering is a
/// projection and can lose a constraint, so the whole pinned text is compared too, and a change
/// no readable section can show still shows there. Every line is sanitized the way the sheet
/// sanitizes the text it shows, so a rewrite that only added invisible characters has NO
/// visible section — and the sheet says so in words instead of showing an empty comparison.
nonisolated enum MCPToolChangeReview {

    nonisolated enum SectionTitle {
        static let title = "Title"
        static let description = "Description"
        static let arguments = "Arguments"
        static let annotations = "Annotations"
        static let raw = "Everything the fingerprint covers"
    }

    nonisolated struct Section: Hashable, Sendable, Identifiable {
        let title: String
        let lines: [LineDiff.Line]
        var id: String { title }
    }

    nonisolated enum Outcome: Hashable, Sendable {
        /// No approved text to compare with: the pin predates recorded texts, or what it
        /// recorded does not hash to it — and a guess shown as "what you approved" would be
        /// worse than saying nothing was kept.
        case notRecorded
        /// The sections that differ, readable ones first and the raw text last. Empty when the
        /// two texts read the same once invisible characters are removed.
        case changed([Section])
    }

    static func between(approved pin: MCPToolPin, live: MCPToolDescriptor) -> Outcome {
        guard let recorded = pin.approvedCanonicalJSON,
              MCPPinHasher.hash(canonicalForm: recorded) == pin.hash,
              let before = sections(canonicalForm: recorded) else { return .notRecorded }
        let after = sections(canonicalForm: MCPPinHasher.canonicalForm(rawTool: live.rawTool)) ?? []

        var changed: [Section] = []
        for (old, new) in zip(before, after) where old.title == new.title {
            let lines = LineDiff.between(old.lines, new.lines)
            if LineDiff.hasChanges(lines) { changed.append(Section(title: new.title, lines: lines)) }
        }
        return .changed(changed)
    }

    // MARK: - Rendering one side

    /// One side, as titled runs of lines, always the same titles in the same order. `nil` when
    /// the text is not JSON — which a recorded text that hashes to its pin cannot be.
    private static func sections(canonicalForm: String) -> [(title: String, lines: [String])]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(canonicalForm.utf8)),
              let object = value.objectValue else { return nil }
        return [
            (SectionTitle.title, titleLines(object)),
            (SectionTitle.description, descriptionLines(object)),
            (SectionTitle.arguments, argumentLines(object)),
            (SectionTitle.annotations, claimLines(object["annotations"])),
            (SectionTitle.raw, rawLines(value)),
        ]
    }

    private static func titleLines(_ object: [String: JSONValue]) -> [String] {
        guard let title = object["title"]?.stringValue else { return [] }
        let line = MCPTextSanitizer.singleLine(title)
        return line.isEmpty ? [] : [line]
    }

    /// The description as the model reads it: sanitized, paragraphs kept.
    private static func descriptionLines(_ object: [String: JSONValue]) -> [String] {
        let text = MCPTextSanitizer.sanitize(object["description"]?.stringValue ?? "")
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// The arguments as the review sheet's Arguments card shows them (`readableArguments`) —
    /// the same projection the descriptor factory uses, so a section that differs is a
    /// difference in the schema, never in how two cards chose to print it.
    private static func argumentLines(_ object: [String: JSONValue]) -> [String] {
        let rawSchema = object["inputSchema"] ?? .object(["type": .string("object")])
        let rendered: String
        do throws(MCPSchemaProjectionError) {
            rendered = readableArguments(try MCPSchemaProjection.project(rawSchema))
        } catch {
            // The projection throws nothing else (`throws(MCPSchemaProjectionError)`), so there
            // is no second arm to fall into; until 2026-09-24 there was one, and nothing reached it.
            rendered = "The schema cannot be rendered: \(error.message)"
        }
        return rendered.components(separatedBy: "\n")
    }

    /// A tool's arguments as a person reads them: the list a prompt-taught tool list prints
    /// (`NativeLMStudioClient.renderParameters`) without the blank lines the prompt puts between
    /// tools, and "No arguments." for a schema with none — the renderer never returns "", it
    /// prints "Args: none", which is the prompt's placeholder, not a sentence (F53).
    static func readableArguments(_ schema: JSONSchema) -> String {
        guard !(schema.properties ?? [:]).isEmpty else { return "No arguments." }
        return NativeLMStudioClient.renderParameters(schema).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each claim the server makes about the tool, one per line, as it sent the value — a
    /// flipped `readOnlyHint` is a change a person must see.
    private static func claimLines(_ annotations: JSONValue?) -> [String] {
        guard let object = annotations?.objectValue else { return [] }
        return object.sorted { $0.key < $1.key }.map { key, value in
            MCPTextSanitizer.singleLine("\(key): \(value.canonicalJSONString())")
        }
    }

    /// The whole pinned text, one member per line and nested members indented, keys sorted —
    /// a display form (no commas), so a line comparison lands on the member that moved.
    private static func rawLines(_ value: JSONValue) -> [String] {
        var lines: [String] = []
        appendRaw(value, key: nil, depth: 0, to: &lines)
        return lines
    }

    private static func appendRaw(_ value: JSONValue, key: String?, depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let label = key.map { JSONValue.string($0).canonicalJSONString() + ": " } ?? ""
        switch value {
        case .object(let object) where !object.isEmpty:
            lines.append(indent + MCPTextSanitizer.singleLine(label + "{"))
            for (member, nested) in object.sorted(by: { $0.key < $1.key }) {
                appendRaw(nested, key: member, depth: depth + 1, to: &lines)
            }
            lines.append(indent + "}")
        case .array(let items) where !items.isEmpty:
            lines.append(indent + MCPTextSanitizer.singleLine(label + "["))
            for item in items {
                appendRaw(item, key: nil, depth: depth + 1, to: &lines)
            }
            lines.append(indent + "]")
        default:
            lines.append(indent + MCPTextSanitizer.singleLine(label + value.canonicalJSONString()))
        }
    }
}
