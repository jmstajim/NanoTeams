import Foundation

/// Projects a foreign MCP `inputSchema` onto the app's own `JSONSchema`.
///
/// This is the allowlist the playbook's R3.7.4 asks for: a schema an external server wrote
/// is untrusted input, and the app decides what of it reaches a prompt — rather than
/// forwarding the document and hoping the renderer ignores what it does not understand.
/// Everything downstream (the prose renderer, the native `tools` field, the argument type
/// gate in `ToolRuntime`) then works on an MCP tool exactly as it does on a built-in one,
/// because after this projection there is no difference left to handle.
///
/// What the projection refuses, and why each refusal is a refusal rather than a repair:
///
///  - **A root that is not an object.** `tools/call` sends `arguments` as an object; a
///    schema declaring the arguments are a string describes a call this client cannot make.
///  - **A dialect it does not know.** A `$schema` naming something outside the four
///    accepted drafts means the keywords may not mean what this code reads them as.
///  - **A `$ref` that leaves the document.** `"$ref": "https://…"` is a fetch — the schema
///    itself becomes an outbound request to a host the user never approved.
///  - **A `$ref` chain deeper than `MCPConstants.maxSchemaRefDepth`, or a cycle.** Both are
///    non-termination dressed as a schema.
///  - **A property name that is not name-safe** (`MCPTextSanitizer.isNameSafe`) — a hidden
///    character, a control or line break, surrounding space — at any depth the projection
///    prints, `required` included. A name is not prose: it is the key the model sends back, so
///    cleaning it would silently rename an argument, and printing it raw would hand the model
///    text the reviewer never saw. A joiner between two visible characters is part of a name
///    (Persian ZWNJ, an emoji's ZWJ) and does not refuse it.
///
/// Every OTHER server string that reaches a prompt goes through `MCPTextSanitizer.singleLine`
/// here: descriptions and titles, the rendered bounds, and type names (2026-09-23 — until then
/// only descriptions and `pattern`/`format` did, and a hidden instruction in an enum value
/// reached segment 0 with no banner in the sheet). The VALUES the model sends back — `enum`,
/// `const`, `default` — go through `MCPTextSanitizer.valueLine`, the same cleaning keeping an
/// interior joiner, so the value the model reads is the value the server accepts.
///
/// What it FOLDS rather than refuses: depth. `JSONSchema` is three levels (CLAUDE.md #46),
/// so an object nested deeper than a leaf renders as a bare `(object)` whose shape rides
/// its description — the same device `ask_supervisor_form.form` and `create_team.team_config`
/// already use, and the handler decodes the real document itself.
nonisolated enum MCPSchemaProjection {

    /// Dialects whose keywords this projection reads correctly. Anything else is refused
    /// rather than guessed at.
    static let acceptedDialects: Set<String> = [
        "https://json-schema.org/draft/2020-12/schema",
        "https://json-schema.org/draft/2019-09/schema",
        "http://json-schema.org/draft-07/schema#",
        "http://json-schema.org/draft-04/schema#",
    ]

    /// How deep the `Shape: {…}` summary of a folded object goes before it prints the bare
    /// type. Three levels is what the summary can show on one line and still be read.
    private static let maxShapeDepth = 3

    // MARK: - Entry point

    static func project(_ raw: JSONValue) throws(MCPSchemaProjectionError) -> JSONSchema {
        guard case .object(let root) = raw else { throw MCPSchemaProjectionError.rootNotAnObject }
        try validateDialect(root)

        let resolver = RefResolver(document: raw)
        let merged = try resolver.flatten(.object(root), depth: 0)
        guard case .object(let object) = merged else { throw MCPSchemaProjectionError.rootNotAnObject }

        let declared = typeNames(of: object)
        guard declared.isEmpty || declared.contains("object") else {
            throw MCPSchemaProjectionError.rootNotAnObject
        }

        let properties = object["properties"]?.objectValue ?? [:]
        let required = try requiredNames(of: object)

        var projected: [String: JSONSchemaProperty] = [:]
        for (key, value) in properties {
            projected[try printableName(key)] = try projectProperty(value, resolver: resolver)
        }

        return JSONSchema(
            type: "object",
            description: nil,
            properties: projected.isEmpty ? nil : projected,
            required: required.isEmpty ? nil : required,
            items: nil,
            enumValues: nil)
    }

    /// An empty object schema — what a tool advertising no arguments projects to, and the
    /// fallback a caller uses when a server sends no `inputSchema` at all (the spec makes
    /// it required; not every server obeys).
    static var emptyObject: JSONSchema {
        JSONSchema(type: "object", description: nil, properties: nil, required: nil, items: nil, enumValues: nil)
    }

    // MARK: - Argument Constraints

    /// Extracts value-level constraints (`enum`/`const` and numeric `minimum`/`maximum`) from the
    /// projected `inputSchema` and, when present, the raw `inputSchema` inside `rawTool`.
    static func argumentConstraints(
        inputSchema: JSONSchema,
        rawTool: JSONValue
    ) -> [String: MCPArgumentConstraint] {
        guard let properties = inputSchema.properties, !properties.isEmpty else { return [:] }
        let rawLookup = rawPropertiesMap(from: rawTool)
        var result: [String: MCPArgumentConstraint] = [:]
        for (key, prop) in properties {
            let rawProp = rawLookup?.properties[key]
            if let constraint = buildConstraint(
                for: prop, rawProperty: rawProp, resolver: rawLookup?.resolver)
            {
                result[key] = constraint
            }
        }
        return result
    }

    private static func rawPropertiesMap(
        from rawTool: JSONValue
    ) -> (properties: [String: JSONValue], resolver: RefResolver)? {
        guard let rawSchema = rawTool.objectValue?["inputSchema"] else { return nil }
        let resolver = RefResolver(document: rawSchema)
        guard let merged = try? resolver.flatten(rawSchema, depth: 0),
              let props = merged.objectValue?["properties"]?.objectValue
        else { return nil }
        return (props, resolver)
    }

    private static func buildConstraint(
        for property: JSONSchemaProperty,
        rawProperty: JSONValue?,
        resolver: RefResolver?
    ) -> MCPArgumentConstraint? {
        let rawNode = resolvedObject(rawProperty, resolver: resolver)
        let topValue = valueConstraint(
            declaredType: property.type, enumValues: property.enumValues, rawNode: rawNode)

        var nestedConstraints: [String: MCPValueConstraint]?
        if let leaves = property.properties {
            let rawLeaves = rawNode?["properties"]?.objectValue
            var built: [String: MCPValueConstraint] = [:]
            for (leafKey, leaf) in leaves {
                let rawLeaf = resolvedObject(rawLeaves?[leafKey], resolver: resolver)
                let vc = valueConstraint(
                    declaredType: leaf.type, enumValues: leaf.enumValues, rawNode: rawLeaf)
                if !vc.isEmpty { built[leafKey] = vc }
            }
            if !built.isEmpty { nestedConstraints = built }
        }

        var itemConstraint: MCPValueConstraint?
        if let items = property.items {
            let rawItems = resolvedObject(rawNode?["items"], resolver: resolver)
            let vc = valueConstraint(
                declaredType: items.type, enumValues: items.enumValues, rawNode: rawItems)
            if !vc.isEmpty { itemConstraint = vc }
        }

        let constraint = MCPArgumentConstraint(
            value: topValue, properties: nestedConstraints, items: itemConstraint)
        return constraint.isEmpty ? nil : constraint
    }

    private static func resolvedObject(
        _ node: JSONValue?, resolver: RefResolver?
    ) -> [String: JSONValue]? {
        guard let node, let resolver, let flat = try? resolver.flatten(node, depth: 0) else {
            return nil
        }
        return flat.objectValue
    }

    private static func valueConstraint(
        declaredType: String,
        enumValues: [String]?,
        rawNode: [String: JSONValue]?
    ) -> MCPValueConstraint {
        let allowed = validatedEnumStrings(
            declaredType: declaredType, projectedEnum: enumValues, rawNode: rawNode)
        let bounds = numericBounds(declaredType: declaredType, rawNode: rawNode)
        return MCPValueConstraint(
            allowedStrings: allowed, lowerBound: bounds.lower, upperBound: bounds.upper)
    }

    private static func validatedEnumStrings(
        declaredType: String,
        projectedEnum: [String]?,
        rawNode: [String: JSONValue]?
    ) -> [String]? {
        guard declaredType == "string", let projectedEnum, !projectedEnum.isEmpty else { return nil }
        guard let rawNode else { return projectedEnum }
        let rawMembers: [JSONValue]
        if let array = rawNode["enum"]?.arrayValue {
            rawMembers = array
        } else if let single = rawNode["const"] {
            rawMembers = [single]
        } else {
            return nil
        }
        guard !rawMembers.isEmpty else { return nil }
        let nonNullTypes = typeNames(of: rawNode).filter { $0 != "null" }
        if nonNullTypes.count > 1 { return nil }
        for member in rawMembers {
            guard let text = member.stringValue, MCPTextSanitizer.valueLine(text) == text else {
                return nil
            }
        }
        return projectedEnum
    }

    private static func numericBounds(
        declaredType: String,
        rawNode: [String: JSONValue]?
    ) -> (lower: MCPNumericBound?, upper: MCPNumericBound?) {
        guard declaredType == "integer" || declaredType == "number", let rawNode else {
            return (nil, nil)
        }
        let lower = extractBound(
            from: rawNode, inclusiveKey: "minimum", exclusiveKey: "exclusiveMinimum", isLower: true)
        let upper = extractBound(
            from: rawNode, inclusiveKey: "maximum", exclusiveKey: "exclusiveMaximum", isLower: false)
        if let lower, let upper {
            if lower.value > upper.value { return (nil, nil) }
            if lower.value == upper.value, lower.isExclusive || upper.isExclusive {
                return (nil, nil)
            }
        }
        return (lower, upper)
    }

    private static func extractBound(
        from object: [String: JSONValue],
        inclusiveKey: String,
        exclusiveKey: String,
        isLower: Bool
    ) -> MCPNumericBound? {
        if let excVal = numberValue(of: object[exclusiveKey]) {
            if let incVal = numberValue(of: object[inclusiveKey]) {
                let exclusiveTighter = isLower ? (excVal >= incVal) : (excVal <= incVal)
                if exclusiveTighter {
                    return MCPNumericBound(value: excVal, isExclusive: true)
                }
                return MCPNumericBound(value: incVal, isExclusive: false)
            }
            return MCPNumericBound(value: excVal, isExclusive: true)
        }
        if let incVal = numberValue(of: object[inclusiveKey]) {
            let draft04Exclusive = object[exclusiveKey]?.boolValue == true
            return MCPNumericBound(value: incVal, isExclusive: draft04Exclusive)
        }
        return nil
    }

    private static func numberValue(of json: JSONValue?) -> Double? {
        switch json {
        case .int(let int): return Double(int)
        case .double(let double) where double.isFinite: return double
        default: return nil
        }
    }

    // MARK: - Properties

    private static func projectProperty(_ raw: JSONValue, resolver: RefResolver) throws(MCPSchemaProjectionError) -> JSONSchemaProperty {
        let flattened = try resolver.flatten(raw, depth: 0)
        guard case .object(let object) = flattened else {
            // A boolean schema (`true` / `false`, legal since draft-06) constrains nothing.
            return JSONSchemaProperty(type: "string", description: nil, properties: nil,
                                      required: nil, items: nil, enumValues: nil)
        }

        var notes: [String] = []
        let type = resolvedType(of: object, notes: &notes)
        let description = descriptionText(of: object)

        var properties: [String: JSONSchemaLeaf]?
        var items: JSONSchemaLeaf?
        var required: [String]?

        switch type {
        case "object":
            let nested = object["properties"]?.objectValue ?? [:]
            if !nested.isEmpty, let leaves = try scalarLeaves(of: nested, resolver: resolver) {
                properties = leaves
                required = try requiredNames(of: object)
                if required?.isEmpty == true { required = nil }
            } else if !nested.isEmpty {
                // Deeper than `JSONSchemaLeaf` can hold: the shape goes into the text, which
                // is the licensed carrier for exactly this case.
                notes.append("shape: " + (try shapeSummary(of: flattened, resolver: resolver, depth: 0)))
            }
        case "array":
            if let rawItems = object["items"] {
                let flattenedItems = try resolver.flatten(rawItems, depth: 0)
                var itemNotes: [String] = []
                let itemObject = flattenedItems.objectValue ?? [:]
                let itemType = resolvedType(of: itemObject, notes: &itemNotes)
                let itemDescription = descriptionText(of: itemObject)
                if itemType == "object" || itemType == "array" {
                    let summary = try shapeSummary(of: flattenedItems, resolver: resolver, depth: 0)
                    notes.append("each item — " + summary)
                }
                items = JSONSchemaLeaf(
                    type: itemType,
                    description: joined(itemDescription, itemNotes),
                    enumValues: enumStrings(of: itemObject))
            }
        default:
            break
        }

        if let defaultValue = object["default"] { notes.append(defaultNote(defaultValue)) }
        for constraint in constraintNotes(of: object) { notes.append(constraint) }

        return JSONSchemaProperty(
            type: type,
            description: joined(description, notes),
            properties: properties,
            required: required,
            items: items,
            enumValues: enumStrings(of: object))
    }

    /// The nested object's members as leaves, or `nil` when any member is itself a
    /// container — the point at which `JSONSchema`'s three levels run out.
    private static func scalarLeaves(
        of properties: [String: JSONValue], resolver: RefResolver
    ) throws(MCPSchemaProjectionError) -> [String: JSONSchemaLeaf]? {
        var leaves: [String: JSONSchemaLeaf] = [:]
        for (key, value) in properties {
            let flattened = try resolver.flatten(value, depth: 0)
            guard case .object(let object) = flattened else { return nil }
            var notes: [String] = []
            let type = resolvedType(of: object, notes: &notes)
            if type == "object" || type == "array" { return nil }
            if let defaultValue = object["default"] { notes.append(defaultNote(defaultValue)) }
            leaves[try printableName(key)] = JSONSchemaLeaf(
                type: type,
                description: joined(descriptionText(of: object), notes),
                enumValues: enumStrings(of: object))
        }
        return leaves
    }

    // MARK: - Type

    /// The declared types, with composition branches folded in. `anyOf: [{string}, {null}]`
    /// — the nullable idiom — reads as `["string", "null"]` here.
    ///
    /// Cleaned at the one place a type is read, because a type is printed three ways — as the
    /// parameter's type, in the `accepts … or …` note, inside a folded shape — and is compared
    /// against `object`/`array`/`null` besides. A name that cleans to nothing is no name.
    private static func typeNames(of object: [String: JSONValue]) -> [String] {
        guard let declared = object["type"] else { return [] }
        let raw = declared.stringValue.map { [$0] } ?? declared.arrayValue?.compactMap(\.stringValue) ?? []
        return raw.map(MCPTextSanitizer.singleLine).filter { !$0.isEmpty }
    }

    /// The one type name the projection prints.
    ///
    /// A schema naming several types is common and legitimate (`["string", "null"]`, or an
    /// `anyOf` of scalars). Picking one has a consequence beyond the prose: `ToolRuntime`'s
    /// argument gate refuses a value whose type does not match, so naming the NARROWEST type
    /// would refuse arguments the server would have accepted. Hence: `string` when it is
    /// among the options — it is both the widest reading and the one the gate does not
    /// police — otherwise the first non-null option, with the alternatives named in the text
    /// so the model is not told a half-truth.
    private static func resolvedType(of object: [String: JSONValue], notes: inout [String]) -> String {
        var names = typeNames(of: object)
        if names.isEmpty {
            for keyword in ["anyOf", "oneOf"] {
                guard let branches = object[keyword]?.arrayValue else { continue }
                names = branches.flatMap { typeNames(of: $0.objectValue ?? [:]) }
                if !names.isEmpty { break }
            }
        }
        if names.isEmpty {
            // No type at all: infer from the keywords present, then fall back to the shape
            // `tools/call` can always carry.
            if object["properties"] != nil { return "object" }
            if object["items"] != nil { return "array" }
            if let values = object["enum"]?.arrayValue, values.allSatisfy({ $0.stringValue != nil }) {
                return "string"
            }
            return "string"
        }

        let nonNull = names.filter { $0 != "null" }
        if names.contains("null") { notes.append("may be null") }
        guard !nonNull.isEmpty else { return "string" }
        if nonNull.count > 1 {
            notes.append("accepts " + nonNull.joined(separator: " or "))
            if nonNull.contains("string") { return "string" }
        }
        return nonNull[0]
    }

    // MARK: - Text

    private static func descriptionText(of object: [String: JSONValue]) -> String {
        let title = object["title"]?.stringValue
        let description = object["description"]?.stringValue
        let pieces = [title, description].compactMap { $0 }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return "" }
        // Title first, then description — a server that sets both usually means the title
        // as the short label.
        return MCPTextSanitizer.singleLine(pieces.joined(separator: " — "))
    }

    /// `enum` and `const` as the strings the renderer prints. A non-string member renders
    /// canonically (`{"a":1}`), so an enum of objects still tells the model what to send.
    ///
    /// Each value on one line with nothing hidden (`MCPTextSanitizer.valueLine` — an interior
    /// joiner stays): the renderer prints `enum: a|b` and the native `tools` field carries the
    /// list. A value the cleaning changed is one the server will refuse when the model sends it
    /// back — loudly, as `-32602`, which is the right way for a disguised value to fail.
    private static func enumStrings(of object: [String: JSONValue]) -> [String]? {
        let members: [JSONValue]
        if let values = object["enum"]?.arrayValue, !values.isEmpty {
            members = values
        } else if let constant = object["const"] {
            members = [constant]
        } else {
            return nil
        }
        return members.map { MCPTextSanitizer.valueLine($0.stringValue ?? $0.canonicalJSONString()) }
    }

    /// `default: <value>` as the model reads it. The canonical form escapes a line break
    /// inside a value, not a zero-width or tag character — hence the cleaning after it, the
    /// value cleaning `enumStrings` uses.
    private static func defaultNote(_ value: JSONValue) -> String {
        "default: " + MCPTextSanitizer.valueLine(value.canonicalJSONString())
    }

    // MARK: - Names

    /// A property name exactly as the server wrote it, or the refusal of the whole tool. The
    /// test is `MCPTextSanitizer.isNameSafe`: a name that hides anything cannot be printed as
    /// written, and cannot be cleaned without renaming the argument.
    private static func printableName(_ key: String) throws(MCPSchemaProjectionError) -> String {
        guard MCPTextSanitizer.isNameSafe(key) else {
            throw MCPSchemaProjectionError.unprintablePropertyName(key)
        }
        return key
    }

    /// `required`, sorted, each entry held to the same rule as a property name — the native
    /// `tools` field carries the list whether or not a property of that name exists.
    private static func requiredNames(of object: [String: JSONValue]) throws(MCPSchemaProjectionError) -> [String] {
        try (object["required"]?.arrayValue ?? []).compactMap(\.stringValue).map(printableName).sorted()
    }

    /// The numeric and length bounds worth telling the model about. A bound it cannot see
    /// is a refusal it cannot avoid — the server validates them and answers `-32602`.
    private static func constraintNotes(of object: [String: JSONValue]) -> [String] {
        var notes: [String] = []
        let numeric: [(String, String)] = [
            ("minimum", "min"), ("maximum", "max"),
            ("exclusiveMinimum", "greater than"), ("exclusiveMaximum", "less than"),
            ("minLength", "min length"), ("maxLength", "max length"),
            ("minItems", "min items"), ("maxItems", "max items"),
        ]
        for (key, label) in numeric {
            guard let value = object[key], !value.isNull else { continue }
            // A bound is a number by the spec and a string when the server says so.
            notes.append("\(label) \(MCPTextSanitizer.singleLine(value.canonicalJSONString()))")
        }
        if let pattern = object["pattern"]?.stringValue, !pattern.isEmpty {
            notes.append("pattern " + MCPTextSanitizer.singleLine(pattern))
        }
        if let format = object["format"]?.stringValue, !format.isEmpty {
            notes.append("format " + MCPTextSanitizer.singleLine(format))
        }
        return notes
    }

    /// The description line: the server's own prose, then the attributes this projection
    /// derived, as a parenthetical tail. A parameter with attributes and no prose reads as
    /// the bare attribute list rather than as `min 1 (max 9)`, which would claim the first
    /// attribute is the description of the rest.
    private static func joined(_ description: String, _ notes: [String]) -> String? {
        let kept = notes.filter { !$0.isEmpty }
        if description.isEmpty { return kept.isEmpty ? nil : kept.joined(separator: ", ") }
        if kept.isEmpty { return description }
        return description + " (" + kept.joined(separator: ", ") + ")"
    }

    /// One-line rendering of a shape `JSONSchema` cannot hold: `{id: string, tags: array of
    /// string, owner: object}`. Below `maxShapeDepth` a nested object prints as the bare
    /// word — the summary is a map, not a second schema.
    private static func shapeSummary(
        of raw: JSONValue, resolver: RefResolver, depth: Int
    ) throws(MCPSchemaProjectionError) -> String {
        let flattened = try resolver.flatten(raw, depth: 0)
        guard case .object(let object) = flattened else { return "any" }
        var ignored: [String] = []
        let type = resolvedType(of: object, notes: &ignored)

        switch type {
        case "object":
            let properties = object["properties"]?.objectValue ?? [:]
            guard !properties.isEmpty, depth < maxShapeDepth else { return "object" }
            let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            var pieces: [String] = []
            for key in properties.keys.sorted() {
                guard let value = properties[key] else { continue }
                let inner = try shapeSummary(of: value, resolver: resolver, depth: depth + 1)
                pieces.append("\(try printableName(key))\(required.contains(key) ? "*" : ""): \(inner)")
            }
            return "{" + pieces.joined(separator: ", ") + "}"
        case "array":
            guard depth < maxShapeDepth, let items = object["items"] else { return "array" }
            return "array of " + (try shapeSummary(of: items, resolver: resolver, depth: depth + 1))
        default:
            return type
        }
    }

    // MARK: - Dialect

    private static func validateDialect(_ root: [String: JSONValue]) throws(MCPSchemaProjectionError) {
        guard let declared = root["$schema"]?.stringValue else { return }
        let normalized = declared.hasSuffix("#") ? String(declared.dropLast()) : declared
        let accepted = acceptedDialects.contains(declared)
            || acceptedDialects.contains(normalized)
            || acceptedDialects.contains(normalized + "#")
        guard accepted else { throw MCPSchemaProjectionError.unsupportedDialect(declared) }
    }
}

// MARK: - Refusals

nonisolated enum MCPSchemaProjectionError: Error, Equatable, LocalizedError {
    case rootNotAnObject
    case unsupportedDialect(String)
    case externalRef(String)
    case unresolvedRef(String)
    case refTooDeep
    case refCycle(String)
    /// A property name that is not name-safe (`MCPTextSanitizer.isNameSafe`). Carries the name
    /// as the server wrote it; the message shows it with every hidden character spelled out.
    case unprintablePropertyName(String)

    /// Reader-facing text for the server detail row and the RPC log. Says which part of the
    /// schema was refused so the server's author can fix it.
    var errorDescription: String? { message }

    /// Non-optional for the same reason `MCPTransportError.message` is.
    var message: String {
        switch self {
        case .rootNotAnObject:
            return "The tool's inputSchema is not an object schema. Declare \"type\": \"object\" with properties."
        case .unsupportedDialect(let declared):
            return "The tool's inputSchema names an unsupported $schema (\(Self.shown(declared))). Use JSON Schema draft-04, draft-07, 2019-09 or 2020-12."
        case .externalRef(let reference):
            return "The tool's inputSchema points $ref outside the document (\(Self.shown(reference))). Inline the definition — a schema is never fetched."
        case .unresolvedRef(let reference):
            return "The tool's inputSchema has a $ref that resolves to nothing (\(Self.shown(reference))). Fix the pointer or inline the definition."
        case .refTooDeep:
            return "The tool's inputSchema nests $ref deeper than \(MCPConstants.maxSchemaRefDepth) levels. Flatten the definitions."
        case .refCycle(let reference):
            return "The tool's inputSchema has a $ref cycle at \(Self.shown(reference)). Break the loop or inline the definition."
        case .unprintablePropertyName(let name):
            return "The tool's inputSchema names a property “\(Self.shown(name))” with hidden characters, "
                + "a line break or surrounding spaces. Rename it — a name the prompt cannot show exactly "
                + "is one the model cannot send."
        }
    }

    /// A server string inside a refusal, on one line with every hidden character spelled out:
    /// the server row shows it, and its author has to be able to find what was refused.
    private static func shown(_ serverText: String) -> String {
        MCPTextSanitizer.visibleLine(serverText)
    }
}

// MARK: - $ref

/// Resolves local `$ref` pointers and folds `allOf` before the projection reads a node.
///
/// Both are done HERE rather than in the projection because both change what a node MEANS:
/// a node that is a bare `$ref` has no type of its own, and an `allOf` splits one object's
/// properties across branches. A projection reading either directly would print an
/// untyped, property-less parameter and call it `(string)`.
nonisolated private struct RefResolver {
    let document: JSONValue

    /// Follows `$ref` and merges `allOf`, returning a node the projection can read.
    func flatten(_ node: JSONValue, depth: Int) throws(MCPSchemaProjectionError) -> JSONValue {
        guard depth <= MCPConstants.maxSchemaRefDepth else { throw MCPSchemaProjectionError.refTooDeep }
        guard case .object(let object) = node else { return node }

        if let reference = object["$ref"]?.stringValue {
            let target = try resolve(pointer: reference, seen: [], depth: depth)
            // Siblings of `$ref` are ignored in draft-07 and merged in 2019-09+. Merging is
            // the generous reading and cannot lose information: a sibling `description`
            // stays with the parameter it was written for.
            var siblings = object
            siblings.removeValue(forKey: "$ref")
            if siblings.isEmpty { return try flatten(target, depth: depth + 1) }
            let merged = merge(base: try flatten(target, depth: depth + 1), overlay: .object(siblings))
            return merged
        }

        guard let branches = object["allOf"]?.arrayValue else { return node }
        var merged: JSONValue = .object(object.filter { $0.key != "allOf" })
        for branch in branches {
            merged = merge(base: merged, overlay: try flatten(branch, depth: depth + 1))
        }
        return merged
    }

    /// JSON Pointer against the schema document. Only local pointers: a `$ref` naming a
    /// host is an outbound fetch the user never approved.
    private func resolve(pointer: String, seen: Set<String>, depth: Int) throws(MCPSchemaProjectionError) -> JSONValue {
        guard depth <= MCPConstants.maxSchemaRefDepth else { throw MCPSchemaProjectionError.refTooDeep }
        guard pointer.hasPrefix("#") else { throw MCPSchemaProjectionError.externalRef(pointer) }
        guard !seen.contains(pointer) else { throw MCPSchemaProjectionError.refCycle(pointer) }

        var node = document
        let path = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: true)
        for rawSegment in path {
            let segment = String(rawSegment)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let next = node[segment] else { throw MCPSchemaProjectionError.unresolvedRef(pointer) }
            node = next
        }
        if let chained = node.objectValue?["$ref"]?.stringValue {
            return try resolve(pointer: chained, seen: seen.union([pointer]), depth: depth + 1)
        }
        return node
    }

    /// Shallow merge, overlay winning. `properties` and `required` are unioned, because an
    /// `allOf` that splits an object's members across branches is the whole reason the
    /// keyword exists.
    private func merge(base: JSONValue, overlay: JSONValue) -> JSONValue {
        guard case .object(let baseObject) = base, case .object(let overlayObject) = overlay else {
            return overlay
        }
        var merged = baseObject
        for (key, value) in overlayObject {
            switch key {
            case "properties":
                var properties = merged["properties"]?.objectValue ?? [:]
                for (name, schema) in value.objectValue ?? [:] { properties[name] = schema }
                merged["properties"] = .object(properties)
            case "required":
                let existing = (merged["required"]?.arrayValue ?? []).compactMap(\.stringValue)
                let added = (value.arrayValue ?? []).compactMap(\.stringValue)
                merged["required"] = .array(Array(Set(existing + added)).sorted().map { .string($0) })
            default:
                merged[key] = value
            }
        }
        return .object(merged)
    }
}
