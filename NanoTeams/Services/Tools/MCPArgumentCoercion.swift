import Foundation

/// Turns the loose `[String: Any]` a model emits into the two things a `tools/call` needs:
/// a JSON body shaped the way the server's schema asked for, and the header parameters that
/// schema asked to be mirrored into `Mcp-Param-*` headers.
///
/// **Why coerce at all.** The app's own tools coerce sloppy argument types at their shared
/// seam (`ToolArgumentHelpers`) because silently ignoring what the model asked for is the
/// failure mode, not a safe default — a `search` whose `paths` was dropped searched the whole
/// tree and reported success. An MCP tool has no handler to read its arguments leniently: the
/// body goes on the wire exactly as assembled, and a server that wanted `{"limit": 10}` and
/// got `{"limit": "10"}` answers with its own error, a round trip later. So the same seam has
/// to exist here, and this is it.
///
/// **What it will not do.** It never invents a value, never drops one it could not convert,
/// and never rewrites a value silently: an adopted conversion is reported in `warnings`, which
/// ride into the result's `meta.warnings` (playbook REC.5). A value it cannot convert is
/// passed through unchanged and the SERVER decides — refusing here would be this client
/// claiming to know a schema it only projected.
nonisolated enum MCPArgumentCoercion {

    struct Coerced: Equatable {
        /// Always an object — the empty object for a tool with no parameters.
        let arguments: JSONValue
        /// Header name → value, mirrored from the body — the modern era only.
        let headerParameters: [String: String]
        /// The protocol revision this split was decided for, when it depends on one: `nil` for a
        /// tool whose schema carries no `x-mcp-header`, which is sent the same way in both
        /// (`MCPToolDescriptor.callShapeDependsOnEra` — a legacy-listed tool with one names
        /// `.legacy` although it has no header parameter). A session in another era refuses a
        /// call whose era is set and is not its own (`MCPClientRegistry.callTool`).
        let era: MCPProtocolEra?
        /// Conversions that were adopted, in the wording the model reads.
        let warnings: [String]
    }

    /// Why a call cannot be assembled at all. Each case is a value the model gave a header
    /// parameter that the 2026-07-28 revision gives no header spelling — and each fails the CALL
    /// rather than the value: a header parameter dropped or rewritten would send the server a
    /// different request from the one the model asked for, silently; and sent in the body alone,
    /// a request a conforming server rejects ("Client omits header but value is in body").
    enum Failure: Error, Equatable, LocalizedError {
        /// A list or an object: the spec converts a string, an integer or a boolean, and nothing
        /// else.
        case headerValueNotAScalar(argument: String)
        /// An integer outside ±(2⁵³−1): "Integer values MUST be within the safe range".
        case headerValueOutsideSafeIntegerRange(argument: String)
        /// A string argument outside the schema's declared `enum` or `const` list.
        case valueOutsideEnum(argument: String, value: String, allowed: [String])
        /// A numeric argument outside the schema's declared `minimum`/`maximum` bounds.
        case valueOutOfRange(argument: String, value: String, requirement: String)

        var errorDescription: String? { message }

        /// Non-optional for the same reason `MCPTransportError.message` is. Model-facing: it is
        /// the `INVALID_ARGS` message the call is refused with (`ToolErrorHandler`).
        /// runtime-prompt
        var message: String {
            switch self {
            case .headerValueNotAScalar(let argument):
                return "`\(argument)` is sent to this server as a request header, so it must be "
                    + "a single text, number or boolean value. Send one value, not a list or an object."
            case .headerValueOutsideSafeIntegerRange(let argument):
                return "`\(argument)` is sent to this server as a request header, and a whole number there "
                    + "must lie between -9007199254740991 and 9007199254740991. Send a number in that range."
            case .valueOutsideEnum(let argument, let value, let allowed):
                return "Invalid value \"\(value)\" for `\(argument)`. Allowed values: \(allowed.joined(separator: ", "))."
            case .valueOutOfRange(let argument, let value, let requirement):
                return "`\(argument)` must be \(requirement) (got \(value))."
            }
        }
    }

    /// The body and the header parameters of one call of `descriptor`'s tool — decided HERE, and
    /// only here, from the protocol revision of the session the call goes to (`era`). The approval card's preflight
    /// and the send (`MCPDynamicTool.preflight` / `handle`) both read this one decision, so the
    /// card shows the call the server receives.
    ///
    /// **Modern era (2026-07-28): mirrored, not moved.** The specification, Streamable HTTP,
    /// "Custom Headers from Tool Parameters": "MCP servers MAY designate specific tool parameters
    /// to be mirrored into HTTP headers using an `x-mcp-header` extension property … conforming
    /// clients MUST mirror the designated parameter values into HTTP headers." Its own example
    /// sends `Mcp-Param-Region: us-west1` beside a body whose `arguments` still hold
    /// `"region": "us-west1"`, and its table makes the body authoritative: "Parameter value
    /// provided — Client MUST include the header — Server MUST validate header matches body";
    /// "Parameter value is `null` — Client MUST omit the header"; "Client omits header but value
    /// is in body — Non-conforming client". ("The body remains the source of truth", Transports,
    /// Request Metadata.) So every argument stays in the body, converted by its declared type
    /// like any other, and a header parameter's header spells the converted value — a `null`
    /// sends none. Until 2026-10-28 the value was MOVED out of the body, which a conforming
    /// server rejects as a header that does not match its body.
    ///
    /// **Legacy era (2025-11-25 and earlier): body only.** That revision has no header channel —
    /// the transport writes no `Mcp-Param-*` header for it — so a header parameter is an ordinary
    /// body argument and nothing is refused for being unfit for a header. Until 2026-10-28 the
    /// value left the body in this era too, and was sent nowhere.
    ///
    /// **Which value, and how it is spelled.** Each header parameter's value is read at its
    /// property path in the converted body — "Header extraction is defined as reading the instance
    /// value at the exact property path of the annotated property … If no value is present at that
    /// path in the call arguments, the header is omitted" — so a nested one is read through its
    /// objects, and a step that is missing, is not an object, or is `null` sends no header
    /// (`instanceValue(at:in:)`). Its text is the spec's type conversion ("`string`: Use the value as-is;
    /// `integer`: … decimal string; `boolean`: … lowercase") — `JSONValue.scalarText`. How that
    /// text goes on the wire — as itself, or as the spec's `=?base64?…?=` sentinel — is the
    /// transport's (`StreamableHTTPTransport.headerValue(_:)`): "When a value cannot be safely
    /// represented as a plain ASCII header value (e.g., it contains non-ASCII characters, control
    /// characters, or has leading/trailing whitespace), clients MUST use Base64 encoding". So a
    /// line break, a control character, U+2028/U+2029 or a ZWNJ in a value is SENT, encoded, never
    /// refused: the sentinel carries it whole and no line can be injected. The approval card
    /// spells each one out (`MCPApprovalRequest.argumentsDisplay`). Until 2026-10-28 such a
    /// value was refused — a call the spec says to send.
    ///
    /// What fails the call (`Failure`), in the modern era only: a value with no header spelling at
    /// all — a list or an object — and an integer outside the spec's safe range. The legacy era
    /// has no header, and refuses nothing for one.
    static func coerce(
        args: [String: Any],
        descriptor: MCPToolDescriptor,
        era: MCPProtocolEra
    ) throws(Failure) -> Coerced {
        let schema = descriptor.inputSchema
        let headerParams = descriptor.headerParams
        var warnings: [String] = []
        var body: [String: JSONValue] = [:]
        let properties = schema.properties ?? [:]

        // Sorted so the warning list — and therefore the tool result the wire carries — is a
        // function of the arguments alone, not of dictionary iteration order.
        for key in args.keys.sorted() {
            guard let raw = args[key] else { continue }
            guard let value = JSONValue.fromFoundation(raw) else {
                // A `Date`, a `URL`, a non-finite number: nothing JSON can hold, so there is
                // no body to put it in. Dropping it is reported rather than silent.
                warnings.append("`\(key)` could not be represented as JSON and was not sent.")
                continue
            }
            let (converted, note) = convert(value, to: properties[key], key: key)
            if converted != .null, let constraint = descriptor.argumentConstraints[key] {
                try validateEnum(converted, constraint: constraint, argument: key)
                try validateNumericBounds(converted, constraint: constraint, argument: key)
            }
            body[key] = converted
            if let note { warnings.append(note) }
        }

        var headers: [String: String] = [:]
        if era.carriesHeaderParameters {
            for param in headerParams {
                guard let value = instanceValue(at: param.argumentPath, in: body), value != .null else { continue }
                headers[param.headerName] = try headerText(value, argument: param.argumentName)
            }
        }

        return Coerced(
            arguments: .object(body), headerParameters: headers,
            era: descriptor.callShapeDependsOnEra ? era : nil, warnings: warnings)
    }

    // MARK: - One value

    /// The declared type is a claim by the SERVER about what it wants, so it is what the
    /// conversion aims at. A property the schema does not mention is passed through: the
    /// projection is lossy by construction (`MCPSchemaProjection`), so "not in the schema"
    /// does not mean "not in the server's schema".
    private static func convert(
        _ value: JSONValue, to property: JSONSchemaProperty?, key: String
    ) -> (JSONValue, String?) {
        guard let property else { return (value, nil) }
        switch property.type {
        case "integer":
            guard let number = integer(from: value), number != value else { return (value, nil) }
            return (number, "`\(key)` was read as a number.")
        case "number":
            guard let number = fractional(from: value), number != value else { return (value, nil) }
            return (number, "`\(key)` was read as a number.")
        case "boolean":
            guard let flag = boolean(from: value), flag != value else { return (value, nil) }
            return (flag, "`\(key)` was read as a boolean.")
        case "string":
            guard case .string = value else {
                guard let text = value.scalarText else { return (value, nil) }
                return (.string(text), "`\(key)` was read as text.")
            }
            return (value, nil)
        case "array":
            return array(from: value, key: key)
        case "object":
            // The one conversion that earns its keep on its own. `JSONSchema` is capped at
            // three levels (CLAUDE.md #46), so a deep object reaches the model as a bare
            // `(object)` with its shape in prose — and a model handed that writes the
            // document as a STRING about as often as it writes it as an object.
            if case .string(let text) = value, let parsed = parseDocument(text),
               parsed.objectValue != nil {
                return (parsed, "`\(key)` was read as JSON rather than as text.")
            }
            return (value, nil)
        default:
            return (value, nil)
        }
    }

    private static func array(from value: JSONValue, key: String) -> (JSONValue, String?) {
        if case .array = value { return (value, nil) }
        if case .string(let text) = value, let parsed = parseDocument(text), parsed.arrayValue != nil {
            return (parsed, "`\(key)` was read as a JSON list rather than as text.")
        }
        // A one-element list emitted as a bare value is the same emission quirk
        // `coerceStringArray` was written for, and the same answer applies.
        if case .null = value { return (value, nil) }
        return (.array([value]), "`\(key)` was read as a one-item list.")
    }

    private static func integer(from value: JSONValue) -> JSONValue? {
        switch value {
        case .int: return value
        case .double(let double):
            guard double.rounded() == double, let exact = Int(exactly: double) else { return nil }
            return .int(exact)
        case .string(let text):
            guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .int(parsed)
        default: return nil
        }
    }

    private static func fractional(from value: JSONValue) -> JSONValue? {
        switch value {
        case .double: return value
        case .int(let int): return .double(Double(int))
        case .string(let text):
            guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite else {
                return nil
            }
            return .double(parsed)
        default: return nil
        }
    }

    private static func boolean(from value: JSONValue) -> JSONValue? {
        switch value {
        case .bool: return value
        case .int(let int) where int == 0 || int == 1: return .bool(int == 1)
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return nil
            }
        default: return nil
        }
    }

    /// Reads a JSON document a model wrote inside a string. Only an object or a list counts:
    /// a bare `"5"` is a string that happens to parse, and reading it as a number here would
    /// undo the very distinction the declared type is being used to preserve.
    private static func parseDocument(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue.fromFoundation(object)
    }

    // MARK: - Enum and numeric bounds

    /// Refuses a string value outside the schema's declared `enum` or `const` list.
    static func validateEnum(
        _ value: JSONValue,
        constraint: MCPArgumentConstraint,
        argument: String
    ) throws(Failure) {
        try validateScalarEnum(value, against: constraint.value, argument: argument)
        if case .array(let elements) = value, let itemConstraint = constraint.items {
            for element in elements {
                try validateScalarEnum(element, against: itemConstraint, argument: argument)
            }
        }
        if case .object(let members) = value, let nested = constraint.properties {
            for subKey in members.keys.sorted() {
                guard let member = members[subKey], let subConstraint = nested[subKey] else { continue }
                try validateScalarEnum(
                    member, against: subConstraint, argument: "\(argument).\(subKey)")
            }
        }
    }

    private static func validateScalarEnum(
        _ value: JSONValue,
        against constraint: MCPValueConstraint,
        argument: String
    ) throws(Failure) {
        guard case .string(let text) = value,
              let allowed = constraint.allowedStrings,
              !allowed.isEmpty,
              !allowed.contains(text)
        else { return }
        throw Failure.valueOutsideEnum(argument: argument, value: text, allowed: allowed)
    }

    /// Refuses a numeric value outside the schema's declared `minimum`/`maximum` bounds.
    static func validateNumericBounds(
        _ value: JSONValue,
        constraint: MCPArgumentConstraint,
        argument: String
    ) throws(Failure) {
        try validateScalarNumericBounds(value, against: constraint.value, argument: argument)
        if case .array(let elements) = value, let itemConstraint = constraint.items {
            for element in elements {
                try validateScalarNumericBounds(element, against: itemConstraint, argument: argument)
            }
        }
        if case .object(let members) = value, let nested = constraint.properties {
            for subKey in members.keys.sorted() {
                guard let member = members[subKey], let subConstraint = nested[subKey] else { continue }
                try validateScalarNumericBounds(
                    member, against: subConstraint, argument: "\(argument).\(subKey)")
            }
        }
    }

    private static func validateScalarNumericBounds(
        _ value: JSONValue,
        against constraint: MCPValueConstraint,
        argument: String
    ) throws(Failure) {
        guard constraint.lowerBound != nil || constraint.upperBound != nil else { return }
        let number: Double
        let valueText: String
        switch value {
        case .int(let int):
            number = Double(int)
            valueText = String(int)
        case .double(let double) where double.isFinite:
            number = double
            valueText = formatBound(double)
        default:
            return
        }
        let belowLower = constraint.lowerBound.map {
            $0.isExclusive ? !(number > $0.value) : !(number >= $0.value)
        } ?? false
        let aboveUpper = constraint.upperBound.map {
            $0.isExclusive ? !(number < $0.value) : !(number <= $0.value)
        } ?? false
        guard belowLower || aboveUpper else { return }
        let requirement = numericRequirementText(
            lower: constraint.lowerBound, upper: constraint.upperBound)
        throw Failure.valueOutOfRange(argument: argument, value: valueText, requirement: requirement)
    }

    private static func numericRequirementText(
        lower: MCPNumericBound?,
        upper: MCPNumericBound?
    ) -> String {
        if let lower, let upper, !lower.isExclusive, !upper.isExclusive {
            return "between \(formatBound(lower.value)) and \(formatBound(upper.value))"
        }
        var parts: [String] = []
        if let lower { parts.append(lowerPhrase(lower)) }
        if let upper { parts.append(upperPhrase(upper)) }
        return parts.joined(separator: " and ")
    }

    private static func lowerPhrase(_ bound: MCPNumericBound) -> String {
        let formatted = formatBound(bound.value)
        return bound.isExclusive ? "greater than \(formatted)" : "at least \(formatted)"
    }

    private static func upperPhrase(_ bound: MCPNumericBound) -> String {
        let formatted = formatBound(bound.value)
        return bound.isExclusive ? "less than \(formatted)" : "at most \(formatted)"
    }

    private static func formatBound(_ value: Double) -> String {
        if value.rounded() == value, let exact = Int(exactly: value) {
            return String(exact)
        }
        return String(value)
    }

    // MARK: - Headers

    /// The value at `path` in `body` — each step a member of an object — or `nil` when a step is
    /// missing or is not an object: "If no value is present at that path in the call arguments,
    /// the header is omitted." A `null` found at the path is returned, and omitted by the caller.
    private static func instanceValue(at path: [String], in body: [String: JSONValue]) -> JSONValue? {
        var node = JSONValue.object(body)
        for key in path {
            guard case .object(let members) = node, let next = members[key] else { return nil }
            node = next
        }
        return node
    }

    /// A header value's text, by the spec's type conversion — or the refusal of a value the spec
    /// gives no header spelling. What the text holds is not refused: the transport carries any
    /// text, behind the Base64 sentinel where it is not plain ASCII.
    private static func headerText(
        _ value: JSONValue, argument: String
    ) throws(Failure) -> String {
        guard let text = value.scalarText else {
            throw Failure.headerValueNotAScalar(argument: argument)
        }
        // "Integer values MUST be within the safe range for JavaScript (−2⁵³+1 to 2⁵³−1)". Read
        // off the value, not the schema: an integral double past the bound is an integer too.
        switch value {
        case .int(let int) where int.magnitude > safeIntegerMagnitude:
            throw Failure.headerValueOutsideSafeIntegerRange(argument: argument)
        case .double(let double) where double.rounded() == double && double.magnitude > Double(safeIntegerMagnitude):
            throw Failure.headerValueOutsideSafeIntegerRange(argument: argument)
        default:
            return text
        }
    }

    /// 2⁵³ − 1, the largest integer an IEEE 754 double — a JavaScript number — holds exactly.
    private static let safeIntegerMagnitude: UInt = 9_007_199_254_740_991
}

nonisolated extension JSONValue {
    /// The one-value spelling of this JSON value, or `nil` for a list, an object or null.
    /// `Int` and `Double` print their JSON form rather than Swift's description, so an
    /// integral double does not reach a server as `3.0` where it wrote `3`.
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .int(let int): return String(int)
        case .double(let double):
            if double.rounded() == double, let exact = Int(exactly: double) { return String(exact) }
            return String(double)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }
}
