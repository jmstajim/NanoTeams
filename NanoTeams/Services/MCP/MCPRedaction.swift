import Foundation

/// Removes credentials from anything about to be written down.
///
/// Three destinations need this and they are easy to forget one at a time: the per-server RPC
/// frame log, a transport error that ends up in a tool result the model reads, and the status
/// line under a server in Settings. A server can put a secret into any of them without
/// meaning to — a 401 body that echoes the token it rejected, a `WWW-Authenticate` challenge
/// carrying an `error_description`, a URL with userinfo.
///
/// The patterns are deliberately narrow. A broad "anything that looks like a token" rule would
/// mangle tool names, ids and file paths, and a log nobody can read is a log nobody keeps.
nonisolated enum MCPRedaction {

    static let placeholder = "<redacted>"

    /// Header names whose VALUE is never written down, whatever it holds.
    static let sensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "mcp-session-id", "x-api-key", "api-key",
    ]

    /// Keeps every header NAME — which is the diagnostic value — and replaces the value of
    /// the sensitive ones. A header the user added as a secret is named in the config, so
    /// callers pass those names in `additionalSensitiveNames`.
    static func headers(
        _ headers: [String: String],
        additionalSensitiveNames: some Sequence<String> = [String]()
    ) -> [String: String] {
        let extra = Set(additionalSensitiveNames.map { $0.lowercased() })
        return headers.reduce(into: [:]) { result, pair in
            let folded = pair.key.lowercased()
            result[pair.key] = (sensitiveHeaderNames.contains(folded) || extra.contains(folded))
                ? placeholder
                : text(pair.value)
        }
    }

    /// Scrubs the credential shapes that appear inside free text: an `Authorization`-style
    /// scheme with its value, and the three query/form parameter names that carry one.
    static func text(_ input: String) -> String {
        var output = input
        for pattern in Self.patterns {
            output = pattern.regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: pattern.template)
        }
        return output
    }

    /// Takes out the NanoTeams agent token (`HostedMCPConstants.agentTokenPattern`) and touches
    /// nothing else, at any length.
    ///
    /// For a FULL body kept for a person to read — the External Autovisor's stored calls
    /// (`ExternalAutovisorFullCallStore`). `text` is wrong there: its scheme pattern reads
    /// `basic implementation` or `token streaming` as a credential and leaves the prose
    /// "basic <redacted>". The only secret this server hands out is the agent token, so the
    /// token's own shape is the whole scrub.
    static func agentTokens(_ input: String) -> String {
        guard let regex = agentTokenRegex, input.contains(HostedMCPConstants.tokenPrefix) else { return input }
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }

    private static let agentTokenRegex = try? NSRegularExpression(pattern: HostedMCPConstants.agentTokenPattern)

    /// A URL as it is safe to write down: userinfo removed, query removed. The query is
    /// dropped wholesale rather than filtered because a server is free to name its token
    /// parameter anything.
    static func url(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.path
    }

    /// Truncates a server-controlled body to what a status row can hold, after scrubbing. The
    /// cap is on a HUMAN-facing excerpt, not on a tool result — a tool result is never
    /// truncated (that rule is elsewhere and stays).
    ///
    /// Knows credential SHAPES only. A writer that knows which server it writes about uses
    /// that server's `Credentials.excerpt`, which also scrubs its own values and header names.
    static func excerpt(_ body: String, limit: Int = 500) -> String {
        Credentials.none.excerpt(body, limit: limit)
    }

    // MARK: - One server's own credentials

    /// What ONE server is sent, as a redaction: the names of its secret headers and the
    /// values of its secrets as they went out.
    ///
    /// The patterns above know credential SHAPES and nothing about this server — so a server
    /// configured with `X-Workspace-Key: wk_live_…` that answers `400 Invalid X-Workspace-Key:
    /// wk_live_…` passed straight through them into the tool result the model reads, the
    /// status row and the frame log (until 2026-09-23). This knows the value itself, and the
    /// names. It is built by whoever knows what was sent (`MCPAuthorizer.credentialsToRedact`)
    /// and read at the moment text is written down, never held: a token cached here would be a
    /// token in a heap dump.
    nonisolated struct Credentials: Hashable, Sendable {

        /// Secret header names. The value after one of them goes, whatever it is.
        let headerNames: [String]
        /// Literal secret values. Each goes wherever it appears, in every spelling
        /// `spellings(of:)` lists.
        let values: [String]

        /// The literal floor for ERROR TEXT — a refusal, a status row, the frame log. A value
        /// shorter than this many UTF-8 bytes is not scrubbed there: it is not a credential
        /// worth the name, and cutting it out of every word it happens to spell would leave a
        /// message nobody can read. The same floor the value patterns below use. A tool's DATA
        /// has a higher one (`Literals.minimumBytes`): a cut there corrupts the answer itself.
        static let minimumLiteralBytes = 4

        static let none = Credentials()

        init(headerNames: [String] = [], values: [String] = []) {
            self.headerNames = headerNames
            self.values = values
        }

        /// The generic scrub, plus this server's values and the values after its names.
        func text(_ input: String) -> String {
            var output = Literals(spellings: spellings(atLeast: Self.minimumLiteralBytes)).scrub(input)
            for pattern in namedValuePatterns {
                output = pattern.stringByReplacingMatches(
                    in: output, range: NSRange(output.startIndex..., in: output),
                    withTemplate: "$1=\(MCPRedaction.placeholder)")
            }
            return MCPRedaction.text(output)
        }

        /// This server's literal values and nothing else — no header names, no credential
        /// shapes — spelled once, for a caller about to scrub a tool's DATA with them, over
        /// the data floor (`Literals.minimumBytes`).
        var literals: Literals { Literals(spellings: spellings(atLeast: Literals.minimumBytes)) }

        /// Every value at least `floor` UTF-8 bytes long, in every spelling it takes on its way
        /// back — longest first, so a value containing another is replaced whole rather than
        /// leaving its tail. A string that contains another is at least as long in bytes, so
        /// the byte length orders them.
        private func spellings(atLeast floor: Int) -> [String] {
            var spellings: Set<String> = []
            for value in values where value.utf8.count >= floor {
                spellings.formUnion(Self.spellings(of: value))
            }
            return spellings.sorted { $0.utf8.count > $1.utf8.count }
        }

        /// The value as written; as a JSON string spells it (a quote or a backslash escaped);
        /// with `/` escaped `\/`, which a JSON encoder is free to write and JSONSerialization
        /// does — a base64 or JWT secret carries `/`; and percent-encoded, as a query or form
        /// echo carries it. A spelling identical to another is one spelling.
        private static func spellings(of value: String) -> Set<String> {
            let json = jsonSpelling(of: value)
            var spellings: Set<String> = [value, json]
            if value.contains("/") { spellings.insert(json.replacingOccurrences(of: "/", with: "\\/")) }
            if let percent = value.addingPercentEncoding(withAllowedCharacters: unreserved) {
                spellings.insert(percent)
            }
            return spellings
        }

        /// RFC 3986's unreserved set — the characters no encoder escapes. Anything else is
        /// percent-encoded, so the spelling is the one every encoder agrees on.
        private static let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        /// The literal half of `text(_:)`, for DATA: a tool's answer rather than a message
        /// about it.
        ///
        /// Literal-only on purpose. A tool may legitimately RETURN text shaped like a
        /// credential — one that lists the user's API keys, a page documenting the
        /// `Authorization:` header — and that text is the answer; the shape patterns and the
        /// header-name patterns would cut it out. What must never come back is the secret this
        /// app sent THIS server, and only its own spellings identify it.
        ///
        /// An echo is what this catches, not an adversary: a server that means to hand the
        /// model its own token can encode it in more ways than any scrub can list.
        nonisolated struct Literals: Hashable, Sendable {
            /// The literal floor for DATA, twice the error-text one (`minimumLiteralBytes`).
            /// A result is the answer, and cutting a short value out of it corrupts every word
            /// it happens to spell — a user who marks `X-Env: prod` secret would read
            /// `<redacted>uction` in every file a tool returned. A value under eight bytes is
            /// not a credential worth the name, and the server editor warns under one as it is
            /// typed (`MCPServerEditorState.isTooShortToRedact`).
            static let minimumBytes = 8

            /// Longest first (`spellings(atLeast:)`), every spelling of every value.
            let spellings: [String]

            var isEmpty: Bool { spellings.isEmpty }

            func scrub(_ input: String) -> String {
                var output = input
                for literal in spellings {
                    output = output.replacingOccurrences(of: literal, with: MCPRedaction.placeholder)
                }
                return output
            }

            /// Every string and every KEY of a JSON document, at every depth; numbers,
            /// booleans and null pass as they are.
            func scrub(_ value: JSONValue) -> JSONValue {
                switch value {
                case .string(let text):
                    return .string(scrub(text))
                case .array(let elements):
                    return .array(elements.map { scrub($0) })
                case .object(let members):
                    return .object(scrubbedMembers(members))
                case .null, .bool, .int, .double:
                    return value
                }
            }

            /// A key that held a secret becomes the placeholder, and two such keys — or one and
            /// a key already spelled so — would fold into one and drop a value. So, as
            /// `MCPTextSanitizer.sanitizeData` does for hidden characters: a key the scrub left
            /// alone keeps its name; the rest follow in scalar order, the first taking the
            /// scrubbed name and any other a numbered suffix. Not the visible spelling the
            /// sanitizer falls back to — here that spelling IS the secret. Nothing is dropped,
            /// and the outcome does not depend on dictionary order.
            private func scrubbedMembers(_ members: [String: JSONValue]) -> [String: JSONValue] {
                let scrubbedKeys = Dictionary(uniqueKeysWithValues: members.keys.map { ($0, scrub($0)) })
                let ordered = members.keys.sorted { lhs, rhs in
                    let lhsKept = scrubbedKeys[lhs] == lhs
                    if lhsKept != (scrubbedKeys[rhs] == rhs) { return lhsKept }
                    return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
                }
                var out: [String: JSONValue] = [:]
                for key in ordered {
                    guard let value = members[key], let base = scrubbedKeys[key] else { continue }
                    var name = base
                    var ordinal = 2
                    while out[name] != nil {
                        name = "\(base) (\(ordinal))"
                        ordinal += 1
                    }
                    out[name] = scrub(value)
                }
                return out
            }
        }

        private var namedValuePatterns: [NSRegularExpression] {
            headerNames.compactMap(Self.namedValuePattern(for:))
        }

        /// `MCPRedaction.excerpt` with this server's credentials: scrubbed BEFORE it is cut, so
        /// a secret straddling the cap cannot leave its first half behind.
        func excerpt(_ body: String, limit: Int = 500) -> String {
            let scrubbed = text(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard scrubbed.count > limit else { return scrubbed }
            return String(scrubbed.prefix(limit)) + "…"
        }

        /// How the value reads inside a JSON string — the frame log writes payloads as JSON,
        /// where a quote or a backslash in a secret is escaped.
        private static func jsonSpelling(of value: String) -> String {
            String(JSONValue.string(value).canonicalJSONString().dropFirst().dropLast())
        }

        /// `<name>: value`, `<name>=value`, `"<name>": "value"` — the name matched literally
        /// and in any case, standing alone (not the tail of a longer header name).
        /// The name is escaped before it becomes a pattern, so a name with metacharacters
        /// matches itself and nothing wider — and the pattern always compiles.
        private static func namedValuePattern(for name: String) -> NSRegularExpression? {
            guard !name.isEmpty else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return try? NSRegularExpression(
                pattern: "(?i)((?<![A-Za-z0-9_-])\(escaped))\"?\\s*[=:]\\s*\"?[^\\s\"',;]+\"?")
        }
    }

    // MARK: - Patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let template: String
    }

    /// Compiled once. Each literal is a pattern this client has actually seen a server put a
    /// secret into, not a guess at what one might look like.
    private static let patterns: [Pattern] = {
        let specs: [(String, String)] = [
            // `Authorization: Bearer <token>` and its siblings, wherever the pair appears.
            //
            // `=` is excluded from the interior and allowed only as base64 padding, and the
            // floor is 8 characters. Both are there for one reason: `WWW-Authenticate: Bearer
            // realm="mcp"` is a CHALLENGE, not a credential, and a looser pattern ate `realm`
            // and left the user a status line that said nothing.
            ("(?i)\\b(bearer|basic|token|apikey)\\s+[A-Za-z0-9._~+/-]{8,}={0,2}", "$1 \(placeholder)"),
            // The same value carried as a parameter. The optional quote after the key is what
            // makes the JSON spelling (`"apiKey": "…"`) match as well as the form one.
            ("(?i)\\b(access_token|refresh_token|api[_-]?key|token|secret)\"?\\s*[=:]\\s*\"?[A-Za-z0-9._~+/=-]{4,}\"?",
             "$1=\(placeholder)"),
            // A session id echoed into prose.
            ("(?i)\\b(mcp-session-id)\"?\\s*[=:]\\s*\"?[A-Za-z0-9._~+/=-]{4,}\"?", "$1=\(placeholder)"),
            // NanoTeams hosted MCP agent token (`ntm_<shortId>_<secret>`), wherever it appears.
            (HostedMCPConstants.agentTokenPattern, placeholder),
            // Userinfo inside a URL that reached a message.
            ("(?i)(https?://)[^/@\\s:]+:[^/@\\s]+@", "$1\(placeholder)@"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Pattern(regex: regex, template: template)
        }
    }()
}
