import Foundation

/// An arbitrary JSON value that round-trips through `Codable` and renders back byte-stably.
///
/// Two callers need exactly this and nothing else. The app's own tool parameters are
/// `JSONSchema`, a three-level ladder authored in Swift (CLAUDE.md #46), which can hold
/// neither of them:
///
///  - **A native `tool_calls` turn.** Ollama's `/api/chat` sends and expects `arguments`
///    as an OBJECT, so replaying an assistant turn means encoding the call's
///    `argumentsJSON` string back into structure, and reading one means decoding structure
///    into the string every downstream consumer already reads (`StepToolCall.argumentsJSON`).
///  - **A foreign MCP schema.** An `inputSchema` an external server wrote is arbitrary
///    depth and arbitrary keys; the app carries it verbatim, projects an allowlisted
///    subset of it into prose for the model, and hashes it for the trust pin.
///
/// Objects render with their keys SORTED (`canonicalJSONString`, which `stableString`
/// spells for the wire), which is what makes a call's bytes deterministic across resends —
/// the property the prompt-prefix cache and `PromptPrefixFingerprint` depend on — and what
/// makes a tool pin stable across launches.
///
/// **Why `int` and `double` are separate cases.** Collapsing integers into `Double` costs
/// exact integers above 2^53: an MCP argument carrying an account or an order id would
/// reach a financial API rounded, silently. The canonical rendering still prints an
/// integral `double` without a fractional tail, so `2` and `2.0` cannot pin differently.
nonisolated enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // `Bool` is tried before the numeric cases: JSONDecoder will happily read `true`
        // as `1` through `Int`, and a schema's `"readOnly": true` would then be pinned —
        // and rendered back to the reviewer — as a number.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not JSON — expected null, a boolean, a number, a string, an array or an object.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            // An integral double encodes as an integer, so `{"depth":1}` does not come back
            // as `{"depth":1.0}` — a byte the model never wrote and the server never cached.
            if value.isFinite, value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Text

nonisolated extension JSONValue {

    /// The value parsed from `json`, or `nil` when the text is not a JSON value.
    ///
    /// Goes through `JSONSerialization` rather than `JSONDecoder` for one reason: the
    /// decoder cannot tell `1` from `1.0` (both satisfy `Int` first), while the
    /// serializer's `NSNumber` carries the spelling the document used.
    init?(json: String) {
        let data = Data(json.utf8)
        guard !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let value = JSONValue.fromFoundation(any)
        else { return nil }
        self = value
    }

    /// The value as compact JSON text with sorted keys — the one spelling every reader of
    /// a call's arguments sees, whichever provider produced it. An alias for
    /// `canonicalJSONString()`, kept because the wire's readers call it that.
    var stableString: String { canonicalJSONString() }

    /// Whether this is a JSON object — the only shape a tool's arguments may take.
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

// MARK: - Accessors

nonisolated extension JSONValue {

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Reads an integer, accepting a `Double` that happens to be integral — a server
    /// writing `1.0` where the spec says integer is sloppy, not hostile.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.isFinite && value == value.rounded() && abs(value) < 9.007e15:
            return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member lookup on an object; `nil` for every other case, so a caller can walk a
    /// foreign document without checking the shape at each step.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}

// MARK: - Foundation bridging

nonisolated extension JSONValue {

    /// Converts a `JSONSerialization` output (or any plist-shaped `Any`) into a `JSONValue`.
    /// Returns `nil` for anything JSON cannot hold — a `Date`, a `URL`, a non-finite
    /// `Double` — rather than substituting a placeholder, because the caller is deciding
    /// whether to trust a foreign document and a silent substitution is a lie about it.
    static func fromFoundation(_ value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            return fromNSNumber(number)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            var converted: [JSONValue] = []
            converted.reserveCapacity(array.count)
            for element in array {
                guard let value = fromFoundation(element) else { return nil }
                converted.append(value)
            }
            return .array(converted)
        case let dictionary as [String: Any]:
            var converted: [String: JSONValue] = [:]
            converted.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = fromFoundation(element) else { return nil }
                converted[key] = value
            }
            return .object(converted)
        default:
            return nil
        }
    }

    /// `NSNumber` erases the difference between `true` and `1` — both answer `1` to
    /// `intValue`. The CoreFoundation type id is the only reliable discriminator, and
    /// without it every boolean in a foreign schema would pin as a number.
    private static func fromNSNumber(_ number: NSNumber) -> JSONValue? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        // `objCType` distinguishes an integer literal from a fractional one. JSONSerialization
        // hands back `__NSCFNumber` for both, so the encoded type character is what says which
        // spelling the document used.
        let type = String(cString: number.objCType)
        if type == "f" || type == "d" {
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return .double(double)
        }
        return .int(number.intValue)
    }

    /// Converts back to the `Any` tree `JSONSerialization` expects — the shape an MCP
    /// `tools/call` params payload is assembled from.
    func toFoundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map { $0.toFoundation() }
        case .object(let value): return value.mapValues { $0.toFoundation() }
        }
    }
}

// MARK: - Canonical rendering

nonisolated extension JSONValue {

    /// A byte-stable rendering: object members sorted by key, no insignificant whitespace,
    /// integral numbers rendered without a fractional part, slashes unescaped.
    ///
    /// This is the pin input (`MCPPinHasher`), the wire's `stableString`, and the `enum`
    /// rendering for non-string values in `MCPSchemaProjection`. `JSONEncoder` with
    /// `.sortedKeys` produces the same bytes today, but its sort is documented as "a
    /// modified ordering" rather than specified, and it re-encodes `Double` through
    /// `NSNumber` — neither is a contract worth hanging a trust decision on. Sorting here
    /// is by unicode scalars, explicitly.
    func canonicalJSONString() -> String {
        var out = ""
        appendCanonical(to: &out)
        return out
    }

    /// The canonical rendering laid out for a person to read: one member or element per line,
    /// indented two spaces per level, `": "` after a key, empty containers on their own line
    /// as `{}` / `[]`. Same members, same order, same escapes, same numbers as
    /// `canonicalJSONString()` — whitespace between tokens is the only difference — so a reader
    /// of this is reading exactly the text a pin was taken over.
    ///
    /// DISPLAY ONLY: nothing hashes, compares or sends it. The review sheet's raw schema printed
    /// the canonical line and wrapped it mid-token (F53).
    func prettyJSONString() -> String {
        var out = ""
        appendPretty(to: &out, depth: 0)
        return out
    }

    private func appendPretty(to out: inout String, depth: Int) {
        let inner = String(repeating: "  ", count: depth + 1)
        let outer = String(repeating: "  ", count: depth)
        switch self {
        case .array(let elements) where !elements.isEmpty:
            out += "[\n"
            for (index, element) in elements.enumerated() {
                if index > 0 { out += ",\n" }
                out += inner
                element.appendPretty(to: &out, depth: depth + 1)
            }
            out += "\n" + outer + "]"
        case .object(let members) where !members.isEmpty:
            out += "{\n"
            for (index, key) in Self.canonicalKeyOrder(members).enumerated() {
                if index > 0 { out += ",\n" }
                out += inner
                Self.appendQuoted(key, to: &out)
                out += ": "
                members[key]?.appendPretty(to: &out, depth: depth + 1)
            }
            out += "\n" + outer + "}"
        default:
            appendCanonical(to: &out)
        }
    }

    /// Object members in the canonical order: by unicode scalars, explicitly.
    private static func canonicalKeyOrder(_ members: [String: JSONValue]) -> [String] {
        members.keys.sorted { lhs, rhs in
            Array(lhs.unicodeScalars).lexicographicallyPrecedes(Array(rhs.unicodeScalars)) { $0.value < $1.value }
        }
    }

    private func appendCanonical(to out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            // JSON has no spelling for infinity or NaN. Such a value cannot arrive by
            // decoding (both `fromFoundation` and `JSONDecoder` refuse it) — only by
            // construction in code — and rendering it as `null` keeps the canonical form
            // total instead of throwing from a hash.
            out += value.isFinite ? Self.canonicalDouble(value) : "null"
        case .string(let value):
            Self.appendQuoted(value, to: &out)
        case .array(let elements):
            out += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { out += "," }
                element.appendCanonical(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in Self.canonicalKeyOrder(members).enumerated() {
                if index > 0 { out += "," }
                Self.appendQuoted(key, to: &out)
                out += ":"
                members[key]?.appendCanonical(to: &out)
            }
            out += "}"
        }
    }

    /// Renders a finite `Double` in the shortest form that round-trips, dropping the
    /// `.0` tail Swift adds to integral values so `2` and `2.0` cannot pin differently
    /// through the `int`/`double` split.
    private static func canonicalDouble(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    /// RFC 8259 §7 string escaping, leaving `/` alone to match the wire encoder's
    /// `.withoutEscapingSlashes`. Control characters are escaped as `\u00XX` rather than
    /// emitted raw, so a description carrying an ANSI escape cannot break the canonical
    /// form it is being hashed through.
    private static func appendQuoted(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
