import Foundation

/// What a built-in tool does with an argument its schema does not declare — the cell every
/// such key gets (`ToolHandler.undeclaredArguments`), so none is dropped without a word.
///
/// Until 2026-11-09 an undeclared key was simply never read. `search {"pattern":…, "path":…}`
/// — grep's vocabulary, and qwen3.6's on LM Studio — lost both: the call was refused with
/// "empty query requires file_glob or paths", a false diagnosis of a call that HAD a keyword,
/// and the corrected retry `{"query":…, "path":…}` lost the scope silently and searched the
/// whole work folder under `ok:true`.
nonisolated enum UndeclaredArgument: Hashable, Sendable {
    /// Another spelling of the declared argument `of`: renamed before dispatch and reported in
    /// the result. `sets` gives declared arguments the meaning the spelling carries when the
    /// model left them unset (`pattern` is a regular expression wherever it comes from, so
    /// `search` reads it with `mode: "regex"`); `detail` is the sentence the note adds when it
    /// did.
    case alias(of: String, detail: String? = nil, sets: [String: String] = [:])
    /// Read by the handler itself, outside the schema (`ask_supervisor_form`'s top-level
    /// `questions`, lifted into the form).
    case readByHandler
    /// Carries nothing the tool acts on; removed before dispatch and reported, with `reason` —
    /// a clause that completes "Ignored `key`: …".
    case ignored(reason: String)
}

/// A built-in tool's undeclared spellings applied to a call's arguments: each alias renamed to
/// the argument it spells, each ignored key removed, everything else refused — the step of
/// `ToolCallArguments.prepare` between the supervisor-ask routing and the type gate.
///
/// Not applied to an MCP tool: its projected schema is lossy, so "not in the schema" is not
/// "not in the server's schema" (`MCPArgumentCoercion`), and the server refuses what it does
/// not know itself.
nonisolated enum ToolArgumentVocabulary {

    enum Outcome {
        /// The arguments the handler receives, and what the model should be told about the
        /// rewrite (REC.5) — `meta.warnings` of the call's result.
        case applied(args: [String: Any], notes: [String])
        /// `INVALID_ARGS` with this message; nothing runs.
        case refused(message: String)
    }

    /// Every top-level key the built-in tool `toolName` reads in some way — declared, an alias,
    /// read by the handler, ignored with a reason — or `nil` for a tool this table does not
    /// describe (an MCP tool, a name nothing handles), about which nothing may be assumed.
    /// The prompt-taught recognizer promotes only these out of a call envelope
    /// (`ToolCallShapeRecognizer`).
    ///
    /// The two supervisor asks accept EACH OTHER's keys here: which of them runs is decided by
    /// the arguments (`SupervisorAskRouting`, after this), so a `form` written beside a call
    /// misnamed `ask_supervisor` must reach the routing — the live shape of 2026-09-10 — rather
    /// than be left out under the name the model got wrong.
    static func acceptedKeys(toolName: String) -> Set<String>? {
        let canonical = ToolRegistry.resolveToolName(toolName)
        let tools = ToolNames.supervisorAskTools.contains(canonical) ? Array(ToolNames.supervisorAskTools) : [canonical]
        var accepted: Set<String>?
        for tool in tools {
            guard let parameters = ToolHandlerRegistry.schema(named: tool)?.parameters else { continue }
            accepted = (accepted ?? [])
                .union(parameters.declaredArgumentNames)
                .union(ToolHandlerRegistry.undeclaredArguments(named: tool).keys)
        }
        return accepted
    }

    /// `nil` when `toolName` is not a built-in tool (an MCP tool, or a name nothing handles).
    static func apply(toolName: String, args: [String: Any]) -> Outcome? {
        guard let parameters = ToolHandlerRegistry.schema(named: toolName)?.parameters else { return nil }
        return apply(
            toolName: toolName, args: args,
            declared: parameters.declaredArgumentNames,
            vocabulary: ToolHandlerRegistry.undeclaredArguments(named: toolName))
    }

    /// The pure rule, over an explicit schema and vocabulary — what the registry's two tables
    /// feed in production and a test feeds directly.
    static func apply(
        toolName: String, args: [String: Any],
        declared: Set<String>, vocabulary: [String: UndeclaredArgument]
    ) -> Outcome {
        var out = args
        var renames: [(from: String, to: String, detail: String?)] = []

        // Sorted on both levels: the gate and the runtime each run this on their own
        // dictionary, and the answer must not depend on which one iterated first. Walking the
        // table in key order appends each argument's aliases already sorted.
        var aliasesByArgument: [String: [String]] = [:]
        for (alias, kind) in vocabulary.sorted(by: { $0.key < $1.key }) {
            if case .alias(let argument, _, _) = kind { aliasesByArgument[argument, default: []].append(alias) }
        }
        for (argument, aliases) in aliasesByArgument.sorted(by: { $0.key < $1.key }) {
            // An alias sent blank or `null` carries nothing — it goes, with nothing to report.
            for alias in aliases where out[alias] != nil && !carriesAValue(out[alias]) {
                out.removeValue(forKey: alias)
            }
            let spellings = ([argument] + aliases).filter { carriesAValue(out[$0]) }
            // Two spellings of one argument are never resolved by picking one: `{"cmd":"ls",
            // "script":"touch x"}` would be judged on one and run as the other.
            guard spellings.count < 2 else {
                return .refused(message: twoSpellingsMessage(
                    tool: toolName, argument: argument, spellings: spellings))
            }
            if let alias = spellings.first, alias != argument {
                out[argument] = out.removeValue(forKey: alias)
                guard case .alias(_, let detail, let sets)? = vocabulary[alias] else { continue }
                // The meaning the spelling carries, only where the model said nothing itself.
                var setAny = false
                for (key, value) in sets where !carriesAValue(out[key]) {
                    out[key] = value
                    setAny = true
                }
                renames.append((alias, argument, sets.isEmpty || setAny ? detail : nil))
            }
        }

        var notes: [String] = []
        if !renames.isEmpty { notes.append(renameNote(tool: toolName, renames: renames)) }
        var unknown: [String] = []
        for key in out.keys.sorted() where !declared.contains(key) && key != ToolRuntime.rawInputKey {
            switch vocabulary[key] {
            case .readByHandler?, .alias?:
                // An alias still here is one the loop above left on purpose — none is: every
                // alias was renamed, removed as blank, or refused. Kept for exhaustiveness.
                continue
            case .ignored(let reason)?:
                out.removeValue(forKey: key)
                notes.append(ignoredNote(key: key, reason: reason))
            case nil:
                // `null` is JSON's word for "not sent" — the type gate reads it the same way.
                if out[key] is NSNull { out.removeValue(forKey: key) } else { unknown.append(key) }
            }
        }
        guard unknown.isEmpty else {
            return .refused(message: unknownArgumentsMessage(
                tool: toolName, keys: unknown, accepted: declared.sorted()))
        }
        return .applied(args: out, notes: notes)
    }

    /// A built-in tool's declared TEXT arguments as text: a number or a boolean the model sent
    /// unquoted is read as its spelling (`search {"query": 404}` searches for "404" — it was
    /// dropped, and the call refused as "an empty query", the incident's own false diagnosis);
    /// an array or an object is refused by name, never dropped. The same conversion
    /// `MCPArgumentCoercion` makes for an MCP tool's text parameter, which the shared type gate
    /// leaves alone for exactly that reason.
    static func readingDeclaredText(args: [String: Any], properties: [String: JSONSchemaProperty]) -> Outcome {
        var out = args
        var notes: [String] = []
        for key in args.keys.sorted() {
            guard properties[key]?.type == "string", let value = args[key],
                  !(value is NSNull), !(value is String) else { continue }
            guard let number = value as? NSNumber else {
                return .refused(message: notTextMessage(key: key, received: ToolArgumentError.jsonTypeName(of: value)))
            }
            out[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? (number.boolValue ? "true" : "false") : number.stringValue
            notes.append(readAsTextNote(key: key))
        }
        return .applied(args: out, notes: notes)
    }

    /// Carries a value: not `null`, and not a string of only whitespace.
    private static func carriesAValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    // MARK: - Shared spellings

    /// The names models reach for instead of a tool's free-text body (`content`, `text`,
    /// `command`), observed across runs before 2026-11-09 and read until then by a resolver
    /// inside each handler — now the same list, declared where the tool is.
    static let bodyAlternatives = [
        "text", "body", "file_content", "data", "value", "plan", "notes", "output", "message", "code",
        "source",
    ]

    /// `names` as aliases of `argument` — a table row per name.
    static func aliases(_ names: [String], of argument: String) -> [String: UndeclaredArgument] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, .alias(of: argument)) })
    }

    /// `file_path` — the path argument's name in the agent harness most local models are tuned
    /// on (its `Read`/`Write`/`Edit`), next to `pattern`/`path`, which qwen3.6 sent to `search`
    /// on 2026-11-09.
    static let filePath: [String: UndeclaredArgument] = ["file_path": .alias(of: "path")]

    // MARK: - What the model reads

    /// runtime-prompt
    ///
    /// A call that sent a key the tool does not take — refused, never run without it: the
    /// key may be the scope, the target or the content the model meant (`search` ran over the
    /// whole work folder without the `path` it was sent). Names only the failing tool's own
    /// arguments (R1.8.3) and ends with the repair (R1.8.1).
    static func unknownArgumentsMessage(tool: String, keys: [String], accepted: [String]) -> String {
        let sent = list(keys, joiner: "or")
        guard !accepted.isEmpty else {
            return "`\(tool)` takes no arguments, so this call with \(sent) did not run. Send it with none."
        }
        let noun = keys.count == 1 ? "argument" : "arguments"
        let pronoun = keys.count == 1 ? "it" : "them"
        return "`\(tool)` has no \(noun) \(sent), so this call did not run. "
            + "Its arguments are \(list(accepted, joiner: "and")): send the value under one of these, "
            + "or omit \(pronoun)."
    }

    /// runtime-prompt
    ///
    /// Two spellings of ONE argument in one call. Neither is chosen — the approval gate and the
    /// runtime would otherwise be free to read different ones.
    static func twoSpellingsMessage(tool: String, argument: String, spellings: [String]) -> String {
        let quantifier = spellings.count == 2 ? "both" : "all"
        return "\(list(spellings.sorted(), joiner: "and")) \(quantifier) give `\(argument)` to `\(tool)`, "
            + "so this call did not run. Send only `\(argument)`."
    }

    /// runtime-prompt
    ///
    /// The renames a call was dispatched under, so the model sends the tool's own names next
    /// time instead of being corrected on every call.
    static func renameNote(
        tool: String, renames: [(from: String, to: String, detail: String?)]
    ) -> String {
        let pairs = renames.map { "`\($0.from)` as `\($0.to)`" }
        let sentence = "Read \(pairs.joined(separator: " and ")), the names `\(tool)` takes."
        return ([sentence] + renames.compactMap(\.detail)).joined(separator: " ")
    }

    /// Whether a `meta.warnings` entry is one of THIS step's notes (a rename, an ignored key, a
    /// value read as text) — so a reader counting some other source's warnings, such as the form
    /// trainer counting its decoder's repairs, can leave these out. Shapes of the builders below.
    static func isNote(_ warning: String) -> Bool {
        (warning.hasPrefix("Read `") && warning.contains(", the names `"))
            || warning.hasPrefix("Ignored `")
            || warning.hasSuffix("` was read as text.")
    }

    /// runtime-prompt
    static func notTextMessage(key: String, received: String) -> String {
        "`\(key)` must be text; received \(received), so this call did not run. Send it as a string."
    }

    /// runtime-prompt
    static func readAsTextNote(key: String) -> String {
        "`\(key)` was read as text."
    }

    /// runtime-prompt
    static func ignoredNote(key: String, reason: String) -> String {
        "Ignored `\(key)`: \(reason)."
    }

    /// `` `a` ``, `` `a` and `b` ``, `` `a`, `b` and `c` `` — backticked, as every argument name
    /// the model reads is.
    private static func list(_ names: [String], joiner: String) -> String {
        let quoted = names.map { "`\($0)`" }
        guard quoted.count > 1 else { return quoted.joined() }
        return quoted.dropLast().joined(separator: ", ") + " \(joiner) " + quoted[quoted.count - 1]
    }
}
