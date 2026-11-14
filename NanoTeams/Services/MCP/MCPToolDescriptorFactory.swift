import Foundation

/// Turns a server's raw `tools/list` entries into descriptors the rest of the app can hold.
///
/// This is the boundary where untrusted data stops being untrusted-shaped: after it, a tool
/// has a name that satisfies the prompt format pin, a description with no invisible
/// characters, a schema the renderer can print, and a hash the user's approval is keyed to.
/// Everything upstream of this file treats a tool as `JSONValue`; nothing downstream does.
///
/// **A tool that cannot be projected is DROPPED, and the whole catalogue is refused only when
/// the failure is about the catalogue itself.** The distinction matters: a server with one
/// tool whose schema names a network `$ref` should still lend its other eleven, while two
/// tools that fold to the same model-facing name make the WHOLE namespace ambiguous — the
/// model would call one and get the other.
nonisolated enum MCPToolDescriptorFactory {

    /// One tool the factory could not accept, kept so the server-detail view can say which and
    /// why rather than silently showing a shorter list.
    nonisolated struct Rejection: Hashable, Sendable {
        /// The name as the server sent it — the row's identity, so two names that merely print
        /// alike stay two rows (`Outcome.rejections`).
        let toolName: String
        let reason: String

        /// The row the server detail view shows: the name and why, with every hidden character
        /// and line break on the line spelled out (`MCPTextSanitizer.visibleLine`). Over the
        /// whole line, not the name alone: a reason already spells out the server strings it
        /// quotes, and nothing on the row can hide anything whichever reason a future refusal
        /// adds.
        var displayLine: String { MCPTextSanitizer.visibleLine("\(toolName) — \(reason)") }
    }

    nonisolated struct Outcome: Sendable {
        let descriptors: [MCPToolDescriptor]
        /// In listing order, and no two equal: each is one fact about the listing — a repeated
        /// name is reported once however often it repeats, and nameless entries are counted in
        /// one row — so the detail view can key its rows by value (CLAUDE.md #22/#23).
        let rejections: [Rejection]
    }

    nonisolated struct PromptOutcome: Sendable {
        let prompts: [MCPPromptDescriptor]
        let rejections: [Rejection]
    }

    /// Whole-catalogue failures. Each one means the namespace itself is unusable, so no tool
    /// of this server reaches a prompt until the server changes.
    nonisolated enum CatalogueError: Error, Hashable, LocalizedError {
        case nameCollision(first: String, second: String, modelFacingName: String)

        var errorDescription: String? { message }

        /// Non-optional for the same reason `MCPTransportError.message` is. Both names are the
        /// server's own and are spelled out (`MCPTextSanitizer.visibleLine`): a hidden
        /// character is the likeliest way two names come to fold alike, and the person has to
        /// see the difference to report it.
        var message: String {
            switch self {
            case .nameCollision(let first, let second, let modelFacingName):
                return "This server publishes “\(MCPTextSanitizer.visibleLine(first))” and "
                    + "“\(MCPTextSanitizer.visibleLine(second))”, which both become \(modelFacingName). "
                    + "Ask the server to rename one — a role could not say which it meant."
            }
        }
    }

    /// Why a repeated name is not offered. The pin is keyed by the server's own name, so a
    /// second entry under it would ride on an approval given to the first entry's text.
    static let repeatedNameReason =
        "The server lists this name more than once. Only its first entry is offered, "
            + "so the text you review is the text that ships."

    private static let unnamedToolName = "(unnamed)"

    /// Why nameless entries are not offered, counted: they are one fact about the listing.
    private static func unnamedReason(count: Int) -> String {
        count == 1
            ? "The entry has no name, so nothing could call it."
            : "\(count) entries have no name, so nothing could call them."
    }

    /// The model-facing names `rawTools` publishes that `offered` has no descriptor for: every
    /// entry with a name that folds (`MCPToolNaming.modelFacingName`, the fold `build` applies),
    /// less the names that were offered. The APP's refusals, by the name a role grants them
    /// under — a collided listing's every entry (pass no descriptor: the whole namespace was
    /// refused), an entry whose schema could not be read, the first of a repeated name when it
    /// was refused. An entry with no name, or one that folds to nothing, has no name a role could
    /// hold, and is not here.
    static func unofferedModelFacingNames(
        of rawTools: [JSONValue], slug: MCPServerSlug, offered: [MCPToolDescriptor]
    ) -> Set<String> {
        var published = Set<String>()
        for raw in rawTools {
            guard let name = raw.objectValue?["name"]?.stringValue, !name.isEmpty,
                  let folded = MCPToolNaming.modelFacingName(slug: slug.rawValue, toolName: name)
            else { continue }
            published.insert(folded)
        }
        return published.subtracting(offered.map(\.modelFacingName))
    }

    static func build(
        rawTools: [JSONValue],
        rawResources: [JSONValue] = [],
        rawResourceTemplates: [JSONValue] = [],
        slug: MCPServerSlug,
        era: MCPProtocolEra?
    ) throws -> Outcome {
        var descriptors: [MCPToolDescriptor] = []
        var rejections: [Rejection] = []
        var originalByModelFacingName: [String: String] = [:]
        // First listed wins, whether or not the first entry itself projects: the listing is
        // ambiguous either way, and offering a later entry would be choosing a text for the
        // person. `listAllTools` joins the pages first, so a repeat on a later page is caught
        // here too.
        var seenOriginalNames: Set<String> = []
        // Each repeated name is reported once, and the nameless entries in one counted row at
        // the first one's place — so no two rejections are equal (`Outcome.rejections`).
        var reportedRepeats: Set<String> = []
        var unnamedCount = 0
        var unnamedRow: Int?

        func recordUnnamed() {
            unnamedCount += 1
            let row = Rejection(toolName: unnamedToolName, reason: unnamedReason(count: unnamedCount))
            if let unnamedRow {
                rejections[unnamedRow] = row
            } else {
                unnamedRow = rejections.count
                rejections.append(row)
            }
        }

        for raw in rawTools {
            guard let object = raw.objectValue, let originalName = object["name"]?.stringValue,
                  !originalName.isEmpty else {
                recordUnnamed()
                continue
            }
            guard seenOriginalNames.insert(originalName).inserted else {
                if reportedRepeats.insert(originalName).inserted {
                    rejections.append(Rejection(toolName: originalName, reason: repeatedNameReason))
                }
                continue
            }
            guard let modelFacingName = MCPToolNaming.modelFacingName(
                slug: slug.rawValue, toolName: originalName) else {
                rejections.append(Rejection(
                    toolName: originalName,
                    reason: "The name has no letters or digits left after folding, so it cannot be written in a prompt."))
                continue
            }
            // Ambiguity is a catalogue-level fact: with two tools behind one name the model
            // cannot say which it meant, and picking either would be picking for it.
            if let existing = originalByModelFacingName[modelFacingName], existing != originalName {
                throw CatalogueError.nameCollision(
                    first: existing, second: originalName, modelFacingName: modelFacingName)
            }
            originalByModelFacingName[modelFacingName] = originalName

            do {
                descriptors.append(try descriptor(
                    raw: raw, object: object, originalName: originalName, modelFacingName: modelFacingName,
                    era: era))
            } catch let error as MCPSchemaProjectionError {
                rejections.append(Rejection(toolName: originalName, reason: error.message))
            } catch let error as MCPHeaderParamError {
                rejections.append(Rejection(toolName: originalName, reason: error.message))
            }
        }

        for raw in rawResources {
            guard let object = raw.objectValue,
                  let uri = object["uri"]?.stringValue, !uri.isEmpty,
                  let name = object["name"]?.stringValue, !name.isEmpty else {
                recordUnnamed()
                continue
            }
            let pinKey = "resource:\(uri)"
            guard seenOriginalNames.insert(pinKey).inserted else {
                if reportedRepeats.insert(pinKey).inserted {
                    rejections.append(Rejection(toolName: pinKey, reason: repeatedNameReason))
                }
                continue
            }
            guard let modelFacingName = MCPToolNaming.resourceModelFacingName(
                slug: slug.rawValue, resourceName: name) else {
                rejections.append(Rejection(
                    toolName: pinKey,
                    reason: "The name has no letters or digits left after folding, so it cannot be written in a prompt."))
                continue
            }
            if let existing = originalByModelFacingName[modelFacingName], existing != pinKey {
                throw CatalogueError.nameCollision(
                    first: existing, second: pinKey, modelFacingName: modelFacingName)
            }
            originalByModelFacingName[modelFacingName] = pinKey
            descriptors.append(resourceDescriptor(
                raw: raw, object: object, pinKey: pinKey, name: name, modelFacingName: modelFacingName,
                target: .staticResource(uri: uri),
                inputSchema: JSONSchema.object(properties: [:])))
        }

        for raw in rawResourceTemplates {
            guard let object = raw.objectValue,
                  let uriTemplate = object["uriTemplate"]?.stringValue, !uriTemplate.isEmpty,
                  let name = object["name"]?.stringValue, !name.isEmpty else {
                recordUnnamed()
                continue
            }
            let pinKey = "resource_template:\(uriTemplate)"
            guard seenOriginalNames.insert(pinKey).inserted else {
                if reportedRepeats.insert(pinKey).inserted {
                    rejections.append(Rejection(toolName: pinKey, reason: repeatedNameReason))
                }
                continue
            }
            guard let modelFacingName = MCPToolNaming.resourceModelFacingName(
                slug: slug.rawValue, resourceName: name) else {
                rejections.append(Rejection(
                    toolName: pinKey,
                    reason: "The name has no letters or digits left after folding, so it cannot be written in a prompt."))
                continue
            }
            let variables = MCPResourceTarget.variables(in: uriTemplate)
            if let badReason = hiddenVariableReason(in: variables) {
                rejections.append(Rejection(toolName: pinKey, reason: badReason))
                continue
            }
            if let existing = originalByModelFacingName[modelFacingName], existing != pinKey {
                throw CatalogueError.nameCollision(
                    first: existing, second: pinKey, modelFacingName: modelFacingName)
            }
            originalByModelFacingName[modelFacingName] = pinKey
            let schema = templateInputSchema(uriTemplate: uriTemplate, variables: variables)
            descriptors.append(resourceDescriptor(
                raw: raw, object: object, pinKey: pinKey, name: name, modelFacingName: modelFacingName,
                target: .template(uriTemplate: uriTemplate, variables: variables),
                inputSchema: schema))
        }

        return Outcome(descriptors: descriptors, rejections: rejections)
    }

    /// Projects `prompts/list` entries into reviewable `MCPPromptDescriptor`s and rejections.
    static func buildPrompts(rawPrompts: [JSONValue], slug: MCPServerSlug) -> PromptOutcome {
        _ = slug
        var prompts: [MCPPromptDescriptor] = []
        var rejections: [Rejection] = []
        var seenNames: Set<String> = []
        var reportedRepeats: Set<String> = []
        var unnamedCount = 0
        var unnamedRow: Int?

        for raw in rawPrompts {
            guard let object = raw.objectValue,
                  let promptName = object["name"]?.stringValue, !promptName.isEmpty else {
                unnamedCount += 1
                let row = Rejection(toolName: unnamedToolName, reason: unnamedReason(count: unnamedCount))
                if let unnamedRow {
                    rejections[unnamedRow] = row
                } else {
                    unnamedRow = rejections.count
                    rejections.append(row)
                }
                continue
            }
            guard seenNames.insert(promptName).inserted else {
                if reportedRepeats.insert(promptName).inserted {
                    rejections.append(Rejection(toolName: promptName, reason: repeatedNameReason))
                }
                continue
            }
            var parsedArgs: [MCPPromptDescriptor.Argument] = []
            var rejectedReason: String?
            if let rawArgs = object["arguments"]?.arrayValue {
                for rawArg in rawArgs {
                    guard let argObj = rawArg.objectValue,
                          let argName = argObj["name"]?.stringValue, !argName.isEmpty else { continue }
                    if MCPTextSanitizer.containsStrippedCharacters(argName) {
                        rejectedReason = "Argument “\(MCPTextSanitizer.visibleLine(argName))” contains hidden characters."
                        break
                    }
                    let argDesc = MCPTextSanitizer.sanitize(argObj["description"]?.stringValue ?? "")
                    let isRequired = argObj["required"]?.boolValue ?? false
                    parsedArgs.append(MCPPromptDescriptor.Argument(
                        name: argName, description: argDesc, isRequired: isRequired))
                }
            }
            if let rejectedReason {
                rejections.append(Rejection(toolName: promptName, reason: rejectedReason))
                continue
            }
            let rawTitle = object["title"]?.stringValue ?? promptName
            let cleanedTitle = MCPTextSanitizer.singleLine(rawTitle)
            let displayTitle = cleanedTitle.isEmpty ? promptName : cleanedTitle
            let displayDescription = MCPTextSanitizer.sanitize(object["description"]?.stringValue ?? "")
            let pinKey = "prompt:\(promptName)"
            prompts.append(MCPPromptDescriptor(
                pinKey: pinKey,
                promptName: promptName,
                displayTitle: displayTitle,
                displayDescription: displayDescription,
                arguments: parsedArgs,
                pinHash: MCPPinHasher.hash(rawTool: raw),
                rawPrompt: raw,
                strippedHiddenCharacters: MCPTextSanitizer.containsStrippedCharacters(in: raw)))
        }
        return PromptOutcome(prompts: prompts, rejections: rejections)
    }

    private static func resourceDescriptor(
        raw: JSONValue,
        object: [String: JSONValue],
        pinKey: String,
        name: String,
        modelFacingName: String,
        target: MCPResourceTarget,
        inputSchema: JSONSchema
    ) -> MCPToolDescriptor {
        let rawDescription = object["description"]?.stringValue ?? ""
        let sanitized = MCPTextSanitizer.sanitize(rawDescription)
        let rawAnnotations = object["annotations"]?.objectValue ?? [:]
        let rawTitle = object["title"]?.stringValue
            ?? rawAnnotations["title"]?.stringValue
            ?? name
        let cleanedTitle = MCPTextSanitizer.singleLine(rawTitle)
        let title = cleanedTitle.isEmpty ? modelFacingName : cleanedTitle
        var stated: [MCPToolAnnotations.Hint: Bool] = [.readOnly: true]
        for (key, hint) in [
            ("readOnlyHint", MCPToolAnnotations.Hint.readOnly),
            ("destructiveHint", .destructive),
            ("idempotentHint", .idempotent),
            ("openWorldHint", .openWorld),
        ] {
            if let value = rawAnnotations[key]?.boolValue { stated[hint] = value }
        }
        return MCPToolDescriptor(
            originalName: pinKey,
            modelFacingName: modelFacingName,
            displayDescription: sanitized,
            inputSchema: inputSchema,
            outputSchema: nil,
            annotations: MCPToolAnnotations(title: title, stated: stated),
            headerParams: [],
            callShapeDependsOnEra: false,
            pinHash: MCPPinHasher.hash(rawTool: raw),
            rawTool: raw,
            strippedHiddenCharacters: MCPTextSanitizer.containsStrippedCharacters(in: raw),
            argumentConstraints: [:],
            resourceTarget: target)
    }

    private static func hiddenVariableReason(in variables: [String]) -> String? {
        for variable in variables where MCPTextSanitizer.containsStrippedCharacters(variable) {
            return "Template variable “\(MCPTextSanitizer.visibleLine(variable))” contains hidden characters."
        }
        return nil
    }

    private static func templateInputSchema(uriTemplate: String, variables: [String]) -> JSONSchema {
        let cleanedTemplate = MCPTextSanitizer.singleLine(uriTemplate)
        var props: [String: JSONSchemaProperty] = [:]
        for variable in variables {
            props[variable] = JSONSchema.string("Value for {\(variable)} in \(cleanedTemplate).")
        }
        return JSONSchema.object(properties: props, required: variables)
    }

    private static func descriptor(
        raw: JSONValue, object: [String: JSONValue], originalName: String, modelFacingName: String,
        era: MCPProtocolEra?
    ) throws -> MCPToolDescriptor {
        let rawDescription = object["description"]?.stringValue ?? ""
        let sanitized = MCPTextSanitizer.sanitize(rawDescription)
        let rawSchema = object["inputSchema"] ?? .object(["type": .string("object")])
        let headers = try headerAdmission(inputSchema: rawSchema, era: era)

        return MCPToolDescriptor(
            originalName: originalName,
            modelFacingName: modelFacingName,
            displayDescription: sanitized,
            inputSchema: try MCPSchemaProjection.project(rawSchema),
            outputSchema: object["outputSchema"],
            annotations: MCPToolAnnotations(raw: object["annotations"]),
            headerParams: headers.params,
            callShapeDependsOnEra: headers.annotated,
            pinHash: MCPPinHasher.hash(rawTool: raw),
            rawTool: raw,
            // Over the WHOLE frame — name, title, description, every schema string — because
            // the sheet's banner speaks for the tool, and until 2026-09-23 it looked only at
            // the description while an enum value carried the payload.
            strippedHiddenCharacters: MCPTextSanitizer.containsStrippedCharacters(in: raw))
    }

    /// The tool's header parameters in the session's `era`, and whether its schema carries an
    /// `x-mcp-header` annotation at all (`MCPToolDescriptor.callShapeDependsOnEra`) — or the
    /// reason the whole tool is excluded.
    ///
    /// **The era decides whether the keyword exists.** `x-mcp-header` is the 2026-07-28
    /// revision's, written for a client speaking it: a LEGACY session (2025-11-25 and earlier)
    /// has no header channel — every argument travels in the body (`MCPArgumentCoercion`) — so
    /// there the keyword is no keyword: no header parameter, and no exclusion for one the modern
    /// rules would refuse. The reference client reads it the same way (python-sdk
    /// `_absorb_tool_listing` checks `find_invalid_x_mcp_header` only for a modern negotiated
    /// version). A session whose era is not known gets the modern rules — failing closed. The
    /// annotation is still recorded in both eras: the tool's call is assembled differently in
    /// the two, which is what pins a step's frozen call to its era. The pin itself is over what
    /// the server sent (`MCPPinHasher`), so it is one hash whatever the era it was listed in.
    /// Until 2026-10-28 the modern rules applied in every era, and a legacy server lost
    /// tools it serves correctly.
    ///
    /// In the modern era, every property the schema asks to have mirrored into a header — or
    /// the reason the whole tool is excluded. The 2026-07-28 revision (Streamable HTTP, "Custom
    /// Headers from Tool Parameters", "Schema Extension") says which, and every rule is applied
    /// here, at admission:
    /// "Clients using the Streamable HTTP transport MUST reject tool definitions where any
    /// `x-mcp-header` value violates these constraints. Rejection means the client MUST exclude
    /// the invalid tool from the result of `tools/list`" — which `build` does, row and reason
    /// included ("SHOULD log a warning … including the tool name and the reason").
    ///
    /// - "MUST only be applied to properties that are statically reachable from the schema root:
    ///   reachable via a chain consisting solely of `properties` keys. The chain MUST NOT pass
    ///   through `items` (or any other array keyword), composition keywords (`oneOf`, `anyOf`,
    ///   `allOf`, `not`), conditional keywords (`if`/`then`/`else`), or `$ref`. … An
    ///   `x-mcp-header` annotation anywhere else makes the annotation — and thus the tool
    ///   definition — invalid." Every subschema position is walked (`subschemaKeywords`), and an
    ///   annotation found off a pure `properties` chain — or on the root, which is no property —
    ///   excludes the tool. A `$ref` is never followed, so a chain cannot pass through one; what it
    ///   points into (`$defs`, `definitions`) is off the chain. Data is not walked: a property
    ///   NAMED `x-mcp-header`, or the key inside an `enum` or `default` value, is no annotation.
    /// - "MUST NOT be empty", "MUST match HTTP field-name token syntax", "MUST NOT contain control
    ///   characters": `MCPHeaderParam.make`; an annotation whose value is not text names no token.
    /// - "MUST only be applied to parameters with primitive types (integer, string, boolean).
    ///   Parameters with type `number` are not permitted": the property's `type` must be one of
    ///   the three, as one string — the reading the reference client takes; a list of types, or
    ///   none, is not a primitive type.
    /// - "Integer values MUST be within the safe range": a rule on VALUES, applied to each call
    ///   (`MCPArgumentCoercion`); a schema's own bounds do not break it.
    /// - "MUST be case-insensitively unique among all `x-mcp-header` values in the `inputSchema`":
    ///   exact duplicates included. Kept, two names equal but for case put two lines on the
    ///   approval card and ONE on the request — a field name is case-insensitive, and the second
    ///   write replaced the first.
    ///
    /// Until 2026-10-28 only top-level properties were read, and only their names checked
    /// (letters, digits and "-", at most 64): a nested header was never sent, a `number` or a
    /// repeated name was admitted, and a spec-valid `Tenant_Id` excluded its tool.
    ///
    /// Sorted by path so two listings of the same catalogue produce identical descriptors — a
    /// descriptor that differed only in ordering would read as a changed tool to every `Hashable`
    /// consumer. Walked with an explicit stack, keywords in order: a server's schema may be deep,
    /// and the walk visits each node once.
    private static func headerAdmission(
        inputSchema: JSONValue, era: MCPProtocolEra?
    ) throws -> (params: [MCPHeaderParam], annotated: Bool) {
        let found = annotations(in: inputSchema)
        guard era?.carriesHeaderParameters ?? true else { return ([], !found.isEmpty) }
        var annotated: [(path: [String], schema: [String: JSONValue])] = []
        for (path, trail, schema) in found {
            guard let path, !path.isEmpty else {
                throw MCPHeaderParamError.notStaticallyReachable(
                    location: trail.isEmpty ? "the schema root" : "/" + trail.joined(separator: "/"))
            }
            annotated.append((path, schema))
        }
        return (try headerParams(of: annotated), !found.isEmpty)
    }

    /// Every schema node carrying `x-mcp-header`, in walk order: its `properties` chain when every
    /// step to it was a `properties` key (nil once one was anything else), and where it is, for a
    /// refusal to name.
    private static func annotations(
        in inputSchema: JSONValue
    ) -> [(path: [String]?, trail: [String], schema: [String: JSONValue])] {
        var found: [(path: [String]?, trail: [String], schema: [String: JSONValue])] = []
        // `path` is the property chain when every step so far was a `properties` key, and nil
        // once a step was anything else; `trail` is where the node is, for a refusal to name.
        var stack: [(path: [String]?, trail: [String], node: JSONValue)] = [([], [], inputSchema)]
        while let (path, trail, node) = stack.popLast() {
            guard case .object(let schema) = node else { continue }
            if schema[MCPHeaderParam.schemaKey] != nil {
                found.append((path, trail, schema))
            }
            for keyword in schema.keys.sorted().reversed() {
                guard let value = schema[keyword] else { continue }
                if keyword == "properties" {
                    guard case .object(let properties) = value else { continue }
                    for name in properties.keys.sorted().reversed() {
                        guard let sub = properties[name] else { continue }
                        stack.append((path.map { $0 + [name] }, trail + [keyword, name], sub))
                    }
                } else if subschemaKeywords.contains(keyword) {
                    switch value {
                    case .object(let object) where mapSubschemaKeywords.contains(keyword):
                        for name in object.keys.sorted().reversed() {
                            guard let sub = object[name] else { continue }
                            stack.append((nil, trail + [keyword, name], sub))
                        }
                    case .array(let list):
                        for (index, sub) in list.enumerated().reversed() {
                            stack.append((nil, trail + [keyword, String(index)], sub))
                        }
                    default:
                        stack.append((nil, trail + [keyword], value))
                    }
                }
            }
        }
        return found
    }

    /// The header parameters of the annotated properties, checked in path order — or the reason
    /// the tool is excluded.
    private static func headerParams(
        of annotated: [(path: [String], schema: [String: JSONValue])]
    ) throws -> [MCPHeaderParam] {
        var params: [MCPHeaderParam] = []
        var propertyByName: [String: String] = [:]
        for (path, schema) in inPathOrder(annotated) {
            let argument = path.joined(separator: ".")
            guard case .string(let rawName)? = schema[MCPHeaderParam.schemaKey] else {
                throw MCPHeaderParamError.nameNotText(argument: argument)
            }
            let param = try MCPHeaderParam.make(argumentPath: path, rawName: rawName)
            guard case .string(let type)? = schema["type"], primitiveTypes.contains(type) else {
                throw MCPHeaderParamError.notPrimitive(argument: argument, type: describedType(schema["type"]))
            }
            if let first = propertyByName[rawName.lowercased()] {
                throw MCPHeaderParamError.duplicateName(first: first, second: argument)
            }
            propertyByName[rawName.lowercased()] = argument
            params.append(param)
        }
        return params
    }

    /// The annotated properties in path order — what makes two listings of one catalogue
    /// produce identical descriptors.
    private static func inPathOrder(
        _ annotated: [(path: [String], schema: [String: JSONValue])]
    ) -> [(path: [String], schema: [String: JSONValue])] {
        annotated.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    /// The types a header may carry.
    private static let primitiveTypes: Set<String> = ["integer", "string", "boolean"]

    /// Every keyword whose value is a subschema, a list of them, or a map of them — the schema
    /// positions an annotation can sit in off a `properties` chain. JSON Schema 2020-12's
    /// applicators, with draft-07's spellings beside them (`additionalItems`, `definitions`,
    /// `dependencies`); `items` is walked as one schema or, draft-07, as a list.
    private static let subschemaKeywords: Set<String> = [
        "items", "prefixItems", "additionalItems", "contains", "unevaluatedItems",
        "additionalProperties", "unevaluatedProperties", "propertyNames", "patternProperties",
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
        "dependentSchemas", "dependencies", "$defs", "definitions", "contentSchema",
    ]

    /// The ones whose value is a map from names to subschemas.
    private static let mapSubschemaKeywords: Set<String> = [
        "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions",
    ]

    /// A property's `type` as a refusal names it.
    private static func describedType(_ type: JSONValue?) -> String {
        switch type {
        case .string(let name)?: "“\(MCPTextSanitizer.visibleLine(name))”"
        case .array?: "a list of types"
        case nil: "not declared"
        default: "not a type name"
        }
    }
}
