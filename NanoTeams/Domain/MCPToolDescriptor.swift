import Foundation

// MARK: - Annotations

/// What a server SAYS about one of its tools. Every stated field is the server's own claim, and
/// every other one the spec's default — which is why the defaults matter more than the values.
///
/// The spec's defaults are pessimistic — a tool that says nothing is assumed to write, to
/// destroy, and to reach the open world — and this type keeps them. The alternative,
/// defaulting an absent `destructiveHint` to `false` for every tool, would let a server lower
/// its own friction by staying silent, which is the cheapest attack there is.
///
/// The one default that does not apply is the spec's own exception: `destructiveHint` (like
/// `idempotentHint`) is "meaningful only when `readOnlyHint` is false", so its `true` default
/// is a default for a tool that WRITES. A tool STATED read-only that says nothing about
/// destruction reads not destructive, and not stated — the usual way to mark a read tool
/// (GitHub's MCP server states `readOnlyHint` alone on its read tools). Until 2026-09-24 the
/// default counted against it: a trusted server's read tools never cleared a call, the model
/// was told the server marked the tool "read-only and destructive at once", and the card
/// printed "treated as: destructive". A server that STATES both still contradicts itself, and
/// the harsher reading counts (`MCPPermissionService`, step 3).
///
/// The reading lives here and nowhere else: every construction path goes through
/// `init(title:stated:)`, which fills each hint the server left out from
/// `specDefault(of:given:)`, so the policy, the chips and the editor's runs-unattended answer
/// read one set of four booleans and cannot read a claim two ways.
///
/// Annotations only ever RAISE friction here, with exactly one exception: `readOnlyHint` on a
/// server the user marked trusted lets a call through under `.semiAutomatic`. That exception
/// is why `isTrusted` is a deliberate switch and not a default.
///
/// Not `Codable`: nothing persists a reading — a pin keeps the server's raw text, and every
/// value is read afresh from it. The conformance, and a legacy decode that marked every hint
/// stated, were kept alive by their own tests alone until 2026-10-28.
nonisolated struct MCPToolAnnotations: Hashable, Sendable {

    /// The four hints the spec defines, in the order a person needs them.
    nonisolated enum Hint: String, Hashable, Sendable, CaseIterable {
        case readOnly, destructive, idempotent, openWorld
    }

    /// The server's display title for the tool. Sanitized like every other server string.
    let title: String?
    let readOnlyHint: Bool
    let destructiveHint: Bool
    let idempotentHint: Bool
    let openWorldHint: Bool
    /// The hints the server actually STATED — a JSON boolean under the hint's own key. Every
    /// other one holds `specDefault(of:given:)` by construction: counted by the policy exactly
    /// like a stated one, and never shown to a person as something the server said (F54). A
    /// tool whose server sent no annotations at all states none.
    let statedHints: Set<Hint>

    /// The spec's own defaults, which are what an absent annotations object means.
    static let specDefaults = MCPToolAnnotations(title: nil, stated: [:])

    /// The designated initializer, and the only place a hint's value is decided: what the
    /// server stated, else the spec's default given what it did state.
    init(title: String?, stated: [Hint: Bool]) {
        func reading(_ hint: Hint) -> Bool { stated[hint] ?? Self.specDefault(of: hint, given: stated) }
        self.title = title
        readOnlyHint = reading(.readOnly)
        destructiveHint = reading(.destructive)
        idempotentHint = reading(.idempotent)
        openWorldHint = reading(.openWorld)
        statedHints = Set(stated.keys)
    }

    /// What a hint the server left out reads as. The spec's pessimistic defaults — writes,
    /// destroys, is not idempotent, reaches the open world — except where the spec says the
    /// hint does not apply: `destructiveHint` is meaningful only for a tool that is not
    /// read-only, so beside a STATED `readOnlyHint: true` it reads `false`. (`idempotentHint`
    /// is the spec's other such hint; its default is already `false`, which draws nothing and
    /// clears nothing.)
    static func specDefault(of hint: Hint, given stated: [Hint: Bool]) -> Bool {
        switch hint {
        case .readOnly: false
        case .destructive: stated[.readOnly] != true
        case .idempotent: false
        case .openWorld: true
        }
    }

    /// Reads a server's `annotations` object. Anything absent, or present with the wrong JSON
    /// type, is not stated and reads its spec default — a string `"false"` is not a boolean,
    /// and reading it as one would let a server disable a guard through a type confusion.
    init(raw: JSONValue?) {
        guard case .object(let object)? = raw else {
            self = .specDefaults
            return
        }
        let title = object["title"]?.stringValue.map(MCPTextSanitizer.singleLine)
        var stated: [Hint: Bool] = [:]
        for (key, hint) in [("readOnlyHint", Hint.readOnly), ("destructiveHint", .destructive),
                            ("idempotentHint", .idempotent), ("openWorldHint", .openWorld)] {
            if let value = object[key]?.boolValue { stated[hint] = value }
        }
        self.init(title: (title?.isEmpty ?? true) ? nil : title, stated: stated)
    }

    func value(of hint: Hint) -> Bool {
        switch hint {
        case .readOnly: readOnlyHint
        case .destructive: destructiveHint
        case .idempotent: idempotentHint
        case .openWorld: openWorldHint
        }
    }

    /// What the review sheet and the approval card show — one reading, so the two cannot
    /// disagree about the same tool.
    var chips: MCPAnnotationChips { MCPAnnotationChips(self) }
}

/// A tool's annotations as a person reads them: what the server CLAIMED, what the app ASSUMES
/// where it said nothing, and — when the server states read-only and destructive at once —
/// that it contradicts itself.
///
/// The review sheet and the approval card both render this, and only this (F31, F54). Until
/// 2026-09-24 the sheet read `displayChips` and the card rebuilt its own chips with the
/// idempotent and open-world hints zeroed, so the two disagreed about the same tool; a tool that
/// claimed read-only AND destructive showed only a reassuring "read-only", although that very
/// pair is why the policy held the call; and a server that said nothing was shown as having
/// claimed "writes · destructive · open world". Until 2026-10-28 a hint stated `false` drew no
/// chip, so `{"destructiveHint": false}` — the usual way to mark a write tool that destroys
/// nothing — was shown nowhere, under a lead that said the server claimed nothing (F54 the
/// other way round).
nonisolated struct MCPAnnotationChips: Hashable, Sendable {

    /// One thing the server STATED about the tool, as a person reads it.
    nonisolated struct Chip: Hashable, Sendable, Identifiable {
        /// How the chip is drawn.
        ///
        /// `.caution` marks a claim that names one of the risks the spec's defaults assume —
        /// it writes, it destroys, it reaches the open world. Annotations only ever raise
        /// friction, so the policy takes such a claim at its word, and a person should too.
        /// `.neutral` is every other claim, and above all the ones that LOWER concern —
        /// read-only, not destructive, idempotent, closed world: the server's word about itself,
        /// which the policy believes only from a server the person marked trusted, and only
        /// for read-only. Such a claim is never drawn in a warning tone, which would make a
        /// reassurance look like an alarm. "Not idempotent" says a repeat is not harmless, which
        /// no policy reads, and is neutral too.
        nonisolated enum Tone: Hashable, Sendable {
            case neutral, caution
        }

        let hint: MCPToolAnnotations.Hint
        let label: String
        let tone: Tone

        var id: MCPToolAnnotations.Hint { hint }

        init(hint: MCPToolAnnotations.Hint, stated value: Bool) {
            self.hint = hint
            switch (hint, value) {
            case (.readOnly, true): (label, tone) = ("read-only", .neutral)
            case (.readOnly, false): (label, tone) = ("writes", .caution)
            case (.destructive, true): (label, tone) = ("destructive", .caution)
            case (.destructive, false): (label, tone) = ("not destructive", .neutral)
            case (.idempotent, true): (label, tone) = ("idempotent", .neutral)
            case (.idempotent, false): (label, tone) = ("not idempotent", .neutral)
            case (.openWorld, true): (label, tone) = ("open world", .caution)
            case (.openWorld, false): (label, tone) = ("closed world", .neutral)
            }
        }
    }

    /// The claimed chips as one row, and the note that qualifies them drawn right after the
    /// last of them (`MCPAnnotationChipsView`).
    nonisolated struct ClaimedRow: Hashable, Sendable {
        let chips: [Chip]
        let note: String?
    }

    /// What the server said — one chip per hint it STATED, in either polarity, in the order a
    /// person needs them: whether it writes, whether it destroys, whether a repeat is harmless,
    /// whether it reaches the open world.
    let claimed: [Chip]
    /// What the policy assumes where the server stated nothing — the spec's defaults, as
    /// `MCPToolAnnotations` reads them — in the same order, and only the ones that read as
    /// something: a tool left not idempotent is assumed nothing worth a word. A tool stated
    /// read-only has nothing assumed about destruction: the hint does not apply to it.
    let assumed: [String]
    /// The server stated no hint at all — the one case the lead says it claimed nothing. Read
    /// off the statements, not off the chips: until 2026-10-28 the lead asked whether a chip
    /// had been drawn, and a server whose every statement was `false` was said to have claimed
    /// nothing.
    let statedNothing: Bool
    /// The server STATED read-only and STATED destructive — it contradicts itself. The policy
    /// counts the harsher reading, so both chips are shown and the pair is named.
    ///
    /// Stated, not merely read — and by construction nothing else can hold both: a tool stated
    /// read-only that says nothing about destruction reads not destructive
    /// (`MCPToolAnnotations.specDefault(of:given:)`). Until 2026-09-24 that most common pair was
    /// read destructive from the spec's default, and labelled first "Read-only and destructive
    /// at once", then "Read-only does not clear a call on its own while destructive is assumed".
    let isContradictory: Bool

    init(_ annotations: MCPToolAnnotations) {
        var claimed: [Chip] = []
        var assumed: [String] = []
        for hint in MCPToolAnnotations.Hint.allCases {
            let value = annotations.value(of: hint)
            if annotations.statedHints.contains(hint) {
                claimed.append(Chip(hint: hint, stated: value))
            } else if let word = Self.assumedWord(hint, value: value) {
                assumed.append(word)
            }
        }
        self.claimed = claimed
        self.assumed = assumed
        statedNothing = annotations.statedHints.isEmpty
        isContradictory = annotations.statedHints.isSuperset(of: [.readOnly, .destructive])
            && annotations.readOnlyHint && annotations.destructiveHint
    }

    /// What a hint the server left out is assumed to be, in words — `nil` when its default
    /// reads as nothing worth a word (not destructive beside a stated read-only, not
    /// idempotent). A default never reads read-only, so "read-only" is never assumed.
    private static func assumedWord(_ hint: MCPToolAnnotations.Hint, value: Bool) -> String? {
        switch hint {
        case .readOnly: value ? "read-only" : "writes"
        case .destructive: value ? "destructive" : nil
        case .idempotent: value ? "idempotent" : nil
        case .openWorld: value ? "open world" : nil
        }
    }

    /// The claimed chips with `note` beside them — `nil` when the server claimed nothing, so a
    /// note that qualifies the claims never stands where no claim does. Until 2026-10-28 the
    /// approval card drew its note beside the WHOLE block, where it floated mid-card or at the
    /// card's far right, away from the chips it qualified.
    func claimedRow(note: String?) -> ClaimedRow? {
        guard !claimed.isEmpty else { return nil }
        return ClaimedRow(chips: claimed, note: note)
    }

    /// What the policy assumes, in words — `nil` when the server stated every hint that reads
    /// as something. "The server claimed nothing" only when it stated nothing at all; beside
    /// any statement, what it left out is "not stated".
    var assumedLine: String? {
        guard !assumed.isEmpty else { return nil }
        let lead = statedNothing ? "The server claimed nothing — treated as: " : "Not stated — treated as: "
        return lead + assumed.joined(separator: ", ")
    }

    /// The contradiction named — `nil` unless the server stated both.
    var contradictionNote: String? {
        isContradictory
            ? "Read-only and destructive at once — the destructive reading is the one that counts."
            : nil
    }
}

// MARK: - Header parameters

/// An input property the server wants mirrored into an HTTP header, beside its value in the
/// JSON body (`x-mcp-header`; the modern era only — `MCPArgumentCoercion.coerce`).
///
/// The name is fixed by the client, not by the server: whatever the server asks for lands
/// under the `Mcp-Param-` prefix. Letting a server name the header outright would let it write
/// `Authorization`, or `Mcp-Session-Id`, and have the client overwrite its own.
///
/// Which properties may carry one, and under what name, is the 2026-07-28 revision's rule
/// (Streamable HTTP, "Custom Headers from Tool Parameters", "Schema Extension") — applied when a
/// tool is admitted (`MCPToolDescriptorFactory`), so a descriptor only ever holds parameters the
/// spec allows: a statically reachable property (`argumentPath`, a chain of `properties` keys) of
/// type integer, string or boolean, named by a token unique among the tool's header names
/// ignoring case.
nonisolated struct MCPHeaderParam: Hashable, Sendable, Codable {

    /// The chain of `properties` keys from the schema root to the property whose value this
    /// header carries — one key for a top-level property. "Header extraction is defined as
    /// reading the instance value at the exact property path of the annotated property."
    let argumentPath: [String]
    /// The full header name, prefix included.
    let headerName: String

    static let prefix = "Mcp-Param-"
    /// The schema extension key a server uses to ask for this.
    static let schemaKey = "x-mcp-header"

    /// The property as a person — or the model, in a refusal — reads it: its path, dot-joined.
    var argumentName: String { argumentPath.joined(separator: ".") }

    /// Builds the header name, or throws with the reason the whole TOOL is refused. The name
    /// rule is the spec's, exactly: "MUST NOT be empty" and "MUST match HTTP field-name token
    /// syntax (`1*tchar`, RFC 9110 Section 5.1)" — which also rules out every control character,
    /// CR and LF ("MUST NOT contain control characters"). Every name that rule accepts is
    /// accepted, whatever its length (the ABNF has no bound), and nothing is trimmed: a space is
    /// not a `tchar`, at either end or inside. Until 2026-10-28 only letters, digits and
    /// "-" were accepted, trimmed, and cut at 64 characters, so a spec-valid `Tenant_Id` excluded
    /// its whole tool.
    ///
    /// A tool whose header parameter cannot be expressed is not partially usable: sending the
    /// value in the body without the header it asks for is a request a conforming modern server
    /// rejects ("Client omits header but value is in body").
    static func make(argumentPath: [String], rawName: String) throws -> MCPHeaderParam {
        let argument = argumentPath.joined(separator: ".")
        guard !rawName.isEmpty else { throw MCPHeaderParamError.emptyName(argument: argument) }
        guard rawName.unicodeScalars.allSatisfy(isTokenCharacter) else {
            throw MCPHeaderParamError.illegalCharacters(argument: argument)
        }
        return MCPHeaderParam(argumentPath: argumentPath, headerName: prefix + rawName)
    }

    /// RFC 9110 §5.6.2 `tchar`: "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
    /// "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA — ASCII only.
    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~": true
        default: false
        }
    }
}

/// Why a tool's `x-mcp-header` breaks the spec's rules, and so why the tool is excluded
/// ("Clients using the Streamable HTTP transport MUST reject tool definitions where any
/// `x-mcp-header` value violates these constraints"). Each names the property — its path — so
/// the server's author can fix it.
nonisolated enum MCPHeaderParamError: Error, Equatable, LocalizedError {
    case emptyName(argument: String)
    case illegalCharacters(argument: String)
    /// The annotation's value is not a string, so it names no token.
    case nameNotText(argument: String)
    /// The property is not declared an integer, a string or a boolean — `type` names what it is.
    case notPrimitive(argument: String, type: String)
    /// The annotation sits somewhere other than a property reached through `properties` alone.
    case notStaticallyReachable(location: String)
    /// Two properties ask for header names equal ignoring case.
    case duplicateName(first: String, second: String)

    /// Read by the server-detail row that explains why a tool was dropped — a human debugging
    /// someone else's server. Names the property so the server's author can fix it.
    var errorDescription: String? { message }

    /// Non-optional for the same reason `MCPTransportError.message` is.
    var message: String {
        switch self {
        case .emptyName(let argument):
            return "Property “\(argument)” asks to be sent as a header but names none."
        case .illegalCharacters(let argument):
            return "Property “\(argument)” asks for a header name with characters an HTTP header name "
                + "cannot hold (letters, digits and !#$%&'*+-.^_`|~ only)."
        case .nameNotText(let argument):
            return "Property “\(argument)” asks to be sent as a header, but its header name is not text."
        case .notPrimitive(let argument, let type):
            return "Property “\(argument)” asks to be sent as a header, but its type is \(type); "
                + "only an integer, a string or a boolean may be."
        case .notStaticallyReachable(let location):
            return "The schema asks for a header at \(location), which is not a property reached "
                + "through “properties” alone."
        case .duplicateName(let first, let second):
            return "Properties “\(first)” and “\(second)” ask for the same header name."
        }
    }
}

// MARK: - Argument Constraints

/// One numeric bound (`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`) extracted
/// from a tool's `inputSchema` for preflight validation (`MCPArgumentCoercion`).
nonisolated struct MCPNumericBound: Hashable, Sendable {
    let value: Double
    let isExclusive: Bool
}

/// Scalar constraints (`enum`/`const` and numeric bounds) on one schema node.
nonisolated struct MCPValueConstraint: Hashable, Sendable {
    let allowedStrings: [String]?
    let lowerBound: MCPNumericBound?
    let upperBound: MCPNumericBound?

    init(
        allowedStrings: [String]? = nil,
        lowerBound: MCPNumericBound? = nil,
        upperBound: MCPNumericBound? = nil
    ) {
        self.allowedStrings = allowedStrings
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var isEmpty: Bool {
        allowedStrings == nil && lowerBound == nil && upperBound == nil
    }
}

/// Value-level constraints for one top-level parameter of a tool, plus its second-level object
/// leaves (`properties`) or array elements (`items`).
nonisolated struct MCPArgumentConstraint: Hashable, Sendable {
    let value: MCPValueConstraint
    let properties: [String: MCPValueConstraint]?
    let items: MCPValueConstraint?

    init(
        value: MCPValueConstraint = MCPValueConstraint(),
        properties: [String: MCPValueConstraint]? = nil,
        items: MCPValueConstraint? = nil
    ) {
        self.value = value
        self.properties = properties
        self.items = items
    }

    var isEmpty: Bool {
        value.isEmpty && (properties?.isEmpty ?? true) && (items?.isEmpty ?? true)
    }
}

// MARK: - Resource Target & Prompt Descriptor (D-M3)

/// How a synthesized resource tool maps its invocation to `resources/read`.
nonisolated enum MCPResourceTarget: Hashable, Sendable {
    /// A static resource from `resources/list`, read by its exact `uri`.
    case staticResource(uri: String)
    /// A parameterized resource template from `resources/templates/list`, whose RFC 6570
    /// `{variable}` placeholders are expanded from the tool's string arguments before calling
    /// `resources/read`.
    case template(uriTemplate: String, variables: [String])

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Extracts RFC 6570 `{variable}` names in appearance order, deduplicated.
    static func variables(in uriTemplate: String) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        var index = uriTemplate.startIndex
        while index < uriTemplate.endIndex {
            guard uriTemplate[index] == "{" else {
                index = uriTemplate.index(after: index)
                continue
            }
            let bodyStart = uriTemplate.index(after: index)
            guard let closeIndex = uriTemplate[bodyStart...].firstIndex(of: "}") else { break }
            let expr = uriTemplate[bodyStart..<closeIndex]
            for rawSpec in expr.split(separator: ",") {
                let trimmed = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    found.append(trimmed)
                }
            }
            index = uriTemplate.index(after: closeIndex)
        }
        return found
    }

    /// Expands this target into the concrete URI to send in `resources/read`.
    /// Each variable value is percent-encoded using RFC 3986 unreserved characters so an
    /// argument cannot break out of its URI segment or inject path/query delimiters.
    func resolveURI(arguments: JSONValue) throws -> String {
        switch self {
        case .staticResource(let uri):
            return uri
        case .template(let uriTemplate, let variables):
            let dict = arguments.objectValue ?? [:]
            var values: [String: String] = [:]
            for variable in variables {
                guard let raw = dict[variable], let text = Self.scalarString(raw) else {
                    throw MCPClientError.rpc(
                        code: MCPErrorCode.invalidParams,
                        message: "Missing required template variable “\(variable)”.",
                        data: nil)
                }
                values[variable] = text
            }
            return Self.expand(uriTemplate: uriTemplate, values: values)
        }
    }

    private static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    private static func encodeComponent(_ value: String) -> String {
        var result = value
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) {
            result = encoded
        }
        return result
    }

    private static func expand(uriTemplate: String, values: [String: String]) -> String {
        var out = ""
        var index = uriTemplate.startIndex
        while index < uriTemplate.endIndex {
            guard uriTemplate[index] == "{" else {
                out.append(uriTemplate[index])
                index = uriTemplate.index(after: index)
                continue
            }
            let bodyStart = uriTemplate.index(after: index)
            guard let closeIndex = uriTemplate[bodyStart...].firstIndex(of: "}") else {
                out.append(contentsOf: uriTemplate[index...])
                break
            }
            let specs = uriTemplate[bodyStart..<closeIndex].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let parts = specs.compactMap { values[$0].map(encodeComponent) }
            out.append(parts.joined(separator: ","))
            index = uriTemplate.index(after: closeIndex)
        }
        return out
    }
}

/// One prompt listed by `prompts/list`, pinned and reviewed before it can appear in the `/`
/// skills picker (`SkillsPickerButton`).
nonisolated struct MCPPromptDescriptor: Hashable, Sendable, Identifiable {
    nonisolated struct Argument: Codable, Hashable, Sendable {
        let name: String
        let description: String
        let isRequired: Bool
    }

    var id: String { pinKey }
    /// Pin key in `MCPTrustStore` (`"prompt:<promptName>"`).
    let pinKey: String
    /// The server's own prompt name sent in `prompts/get`.
    let promptName: String
    /// Cleaned single-line display title.
    let displayTitle: String
    /// Cleaned prose description.
    let displayDescription: String
    /// Sanitized prompt arguments.
    let arguments: [Argument]
    /// SHA-256 over the canonical prompt definition.
    let pinHash: String
    /// The raw prompt JSON as sent by the server (kept for the review sheet and diff).
    let rawPrompt: JSONValue
    /// Whether any string in the raw prompt contained invisible characters stripped by
    /// `MCPTextSanitizer`.
    let strippedHiddenCharacters: Bool

    /// Projects this prompt into an `MCPToolDescriptor` so `MCPToolReviewSheet` and
    /// `MCPToolChangeReview` can present and diff it with the same review sheet used for tools
    /// and resources.
    func asReviewDescriptor(slug: MCPServerSlug) -> MCPToolDescriptor {
        var properties: [String: JSONSchemaProperty] = [:]
        var required: [String] = []
        for arg in arguments {
            properties[arg.name] = JSONSchema.string(arg.description.isEmpty ? nil : arg.description)
            if arg.isRequired { required.append(arg.name) }
        }
        let folded = MCPToolNaming.foldToolName(promptName)
        let modelName = "mcp__\(slug.rawValue)__prompt__\(folded.isEmpty ? "item" : folded)"
        return MCPToolDescriptor(
            originalName: pinKey,
            modelFacingName: modelName,
            displayDescription: displayDescription,
            inputSchema: JSONSchema.object(
                properties: properties,
                required: required),
            outputSchema: nil,
            annotations: MCPToolAnnotations(title: displayTitle, stated: [.readOnly: true]),
            headerParams: [],
            callShapeDependsOnEra: false,
            pinHash: pinHash,
            rawTool: rawPrompt,
            strippedHiddenCharacters: strippedHiddenCharacters,
            argumentConstraints: [:])
    }
}

// MARK: - Descriptor

/// One tool of one server, projected into what the rest of the app can use: a name the model
/// can call, a description a person can read, a schema the prompt renderer understands, and
/// the hash that says this is still the tool the user approved.
///
/// Three names live here and they are not interchangeable:
///  - `originalName` goes on the wire in `tools/call` — the server never sees the folded form;
///  - `modelFacingName` is `mcp__<slug>__<tool>`, the only name the model ever writes;
///  - `annotations.title` is the server's display label and reaches no protocol layer at all.
nonisolated struct MCPToolDescriptor: Hashable, Sendable, Identifiable {

    let originalName: String
    let modelFacingName: String
    /// Full description, sanitized, never truncated — this is the model's documentation for
    /// the tool and the text a person approves.
    let displayDescription: String
    /// The projection `MCPSchemaProjection` produced. Prose-rendered into the prompt like
    /// every built-in tool's schema.
    let inputSchema: JSONSchema
    /// The server's declared output schema, unprojected. Shown in the review sheet; nothing
    /// validates against it, because a result that disagrees with it is the server's problem
    /// and dropping the result would lose the role's work.
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations
    let headerParams: [MCPHeaderParam]
    /// Whether a call of this tool is assembled differently in the two protocol eras — whether
    /// the server's `inputSchema` carries `x-mcp-header` anywhere a schema can: the modern era
    /// mirrors such a parameter into a header (or excludes the tool), the legacy one sends the
    /// body alone. Not `!headerParams.isEmpty`: a tool listed in a LEGACY session has no header
    /// parameter — the keyword is not its revision's (`MCPToolDescriptorFactory`) — and is still
    /// called differently once the session speaks the modern era. What a step's frozen call
    /// carries as its era (`MCPToolCall.era`, through `MCPArgumentCoercion.coerce`) and what the
    /// live catalogue reads when a server's session has moved to another era
    /// (`MCPLiveCatalogueIndex.standing(of:)`).
    let callShapeDependsOnEra: Bool
    /// SHA-256 over the canonical form of everything above as the server sent it. The pin.
    let pinHash: String
    /// The frame exactly as it arrived: the review sheet's raw view, and — through its
    /// canonical form — the text an approval records (`MCPToolPin.approvedCanonicalJSON`) and
    /// the "after" side of the diff a changed pin shows. The "before" side is that recorded
    /// text, never a re-fetch: a re-fetch would compare the server against itself.
    let rawTool: JSONValue
    /// Whether the server's frame carried anything `MCPTextSanitizer` strips — in ANY string
    /// of it, not only the description: the name, the title, every key and value of both
    /// schemas. Surfaced in the review sheet: invisible characters in a tool have exactly one
    /// purpose, and a reviewer deciding whether to approve should be told they were there.
    let strippedHiddenCharacters: Bool
    /// Value-level constraints (`enum` and numeric `minimum`/`maximum`) extracted from the tool's
    /// schema for preflight validation before an approval card or outbound call.
    let argumentConstraints: [String: MCPArgumentConstraint]
    /// Non-nil when this descriptor is a synthesized read-only tool backed by `resources/read`
    /// (`resources/list` or `resources/templates/list`).
    let resourceTarget: MCPResourceTarget?

    var isSynthesizedResource: Bool { resourceTarget != nil }

    init(
        originalName: String,
        modelFacingName: String,
        displayDescription: String,
        inputSchema: JSONSchema,
        outputSchema: JSONValue?,
        annotations: MCPToolAnnotations,
        headerParams: [MCPHeaderParam],
        callShapeDependsOnEra: Bool,
        pinHash: String,
        rawTool: JSONValue,
        strippedHiddenCharacters: Bool,
        argumentConstraints: [String: MCPArgumentConstraint]? = nil,
        resourceTarget: MCPResourceTarget? = nil
    ) {
        self.originalName = originalName
        self.modelFacingName = modelFacingName
        self.displayDescription = displayDescription
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.headerParams = headerParams
        self.callShapeDependsOnEra = callShapeDependsOnEra
        self.pinHash = pinHash
        self.rawTool = rawTool
        self.strippedHiddenCharacters = strippedHiddenCharacters
        self.argumentConstraints = argumentConstraints
            ?? MCPSchemaProjection.argumentConstraints(inputSchema: inputSchema, rawTool: rawTool)
        self.resourceTarget = resourceTarget
    }

    var id: String { modelFacingName }

    /// The label a list row and the approval card show: the server's title if it gave one,
    /// else the tool's name — cleaned and on one line, because `originalName` is foreign text
    /// kept raw for the wire, and a right-to-left override in it would disguise which tool a
    /// person is approving. A name with nothing readable left is shown as the model-facing one.
    var displayTitle: String {
        if let title = annotations.title { return title }
        let cleaned = MCPTextSanitizer.singleLine(originalName)
        return cleaned.isEmpty ? modelFacingName : cleaned
    }

    /// First line of the description, for a one-line row.
    var summaryLine: String { MCPTextSanitizer.singleLine(displayDescription) }
}
