import Foundation

/// The Add/Edit-server sheet's draft, and every rule about whether it can be saved.
///
/// Pure and separate from the sheet for the usual reason and one particular one: the rules it
/// enforces are the client's first line of defence — a slug that collides silently merges two
/// servers' namespaces, and an address off loopback over plain HTTP is a credential on the
/// wire. Those belong somewhere a test can reach without a window.
///
/// The secret NEVER round-trips through a config: `bearerToken` and a header's `value` are
/// typed here and handed to `MCPServerManager.save` as an `MCPServerSecretEdit`, and
/// `makeConfig()` carries only names. What the Keychain already holds reaches this type as
/// account NAMES only (`storedSecretKeys`), so it can say "leave blank to keep" where there is
/// something to keep — and nowhere else.
nonisolated struct MCPServerEditorState: Equatable, Sendable {

    /// One Keychain-backed request header.
    nonisolated struct HeaderDraft: Identifiable, Equatable, Sendable {
        let id: UUID
        var name: String
        var value: String
        /// The name this row had when the sheet opened; `nil` for a row added in this edit.
        /// The secret is keyed by the name, so this is what lets a rename MOVE the stored
        /// value rather than orphan it (F42).
        let originalName: String?

        init(id: UUID = UUID(), name: String = "", value: String = "", originalName: String? = nil) {
            self.id = id
            self.name = name
            self.value = value
            self.originalName = originalName
        }

        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// What stops this draft being saved. Each case names the repair rather than the rule,
    /// because the person reading it is mid-edit and wants the next keystroke.
    nonisolated enum Problem: Hashable, Sendable {
        case slugMissing
        case slugMalformed
        case slugTaken(String)
        case urlRejected(String)
        case headerNameMalformed(String)
        case headerNameReserved(String)
        case headerNameRepeated(String)
        case headerValueMissing(String)
        case bearerMissing

        var message: String {
            switch self {
            case .slugMissing:
                return "Give the server a short name — it prefixes every tool the model sees."
            case .slugMalformed:
                return "The short name may use lowercase letters, digits and underscores only, "
                    + "starting with a letter or digit, up to \(MCPToolNaming.maxSlugLength) characters."
            case .slugTaken(let slug):
                return "Another server already uses “\(slug)”. Pick a different short name."
            case .urlRejected(let reason):
                return reason
            case .headerNameMalformed(let name):
                return "“\(name)” is not a usable header name. Use letters, digits and hyphens."
            case .headerNameReserved(let name):
                return "“\(name)” is set by this client. Remove the row, or rename the header."
            case .headerNameRepeated(let name):
                return "“\(name)” is listed twice. Remove one of the rows."
            case .headerValueMissing(let name):
                return "Paste the value for “\(name)”, or remove the row."
            case .bearerMissing:
                return "Paste the token, or set Authentication to None."
            }
        }
    }

    /// The server being edited, as stored; `nil` while adding. An edit starts from it and
    /// overwrites only what the sheet shows (`makeConfig`), and it is what tells a new address
    /// from the old one (`isRepointing`).
    private(set) var original: MCPServerConfig?
    /// Which of the original's Keychain accounts hold a value — names only.
    private(set) var storedSecretKeys: Set<String> = []
    /// Set by any change to a field the sheet shows, and by a Save press. Until then the
    /// problems stay hidden: a blank Add sheet does not greet the person with errors for fields
    /// they have not touched (F49).
    private(set) var isEdited = false
    private(set) var hasAttemptedSave = false

    var slugText: String = "" { didSet { noteEdit(slugText != oldValue) } }
    var displayName: String = "" { didSet { noteEdit(displayName != oldValue) } }
    var urlString: String = "" { didSet { noteEdit(urlString != oldValue) } }
    var authorization: MCPAuthorizationMode = .none { didSet { noteEdit(authorization != oldValue) } }
    /// As typed. Empty on an EDIT keeps what is stored — when something is (`bearerIsKept`).
    var bearerToken: String = "" { didSet { noteEdit(bearerToken != oldValue) } }
    var headers: [HeaderDraft] = [] { didSet { noteEdit(headers != oldValue) } }
    /// ON for a new server: connecting is what lists its tools for review, and a listed tool
    /// still reaches no prompt until a person approves it — the per-tool review is the
    /// admission gate, not this switch (decision of 2026-09-23). A config decoded without the
    /// field still reads off (`MCPServerConfig.init(from:)`).
    var isEnabled: Bool = true { didSet { noteEdit(isEnabled != oldValue) } }
    var isTrusted: Bool = false { didSet { noteEdit(isTrusted != oldValue) } }
    var approvalMode: MCPApprovalMode = .manual { didSet { noteEdit(approvalMode != oldValue) } }
    var judgeStrictness: MCPJudgeStrictness = .standard { didSet { noteEdit(judgeStrictness != oldValue) } }

    var showsJudgeControls: Bool { approvalMode == .auto }

    var serverID: UUID? { original?.id }

    /// The id a NEW server is saved under, minted once with the draft: a Save the Keychain
    /// refused and a second press write under the same id, so the retry overwrites whatever the
    /// first attempt left rather than stranding it under an id no server will ever have (review
    /// of group D, 2026-09-24). An edit saves under the stored server's id instead.
    private let newServerID = UUID()

    // MARK: - Starting points

    /// An existing server. Its secrets stay in the Keychain; `storedSecretKeys` says only
    /// which of its accounts hold one.
    static func from(config: MCPServerConfig, storedSecretKeys: Set<String> = []) -> MCPServerEditorState {
        let http = config.transport.http
        var state = MCPServerEditorState()
        state.original = config
        state.storedSecretKeys = storedSecretKeys
        state.slugText = config.slug.rawValue
        state.displayName = config.displayName
        state.urlString = http.urlString
        state.authorization = http.authorization
        state.headers = http.secretHeaderNames.map { HeaderDraft(name: $0, originalName: $0) }
        state.isEnabled = config.isEnabled
        state.isTrusted = config.isTrusted
        state.approvalMode = config.approvalMode
        state.judgeStrictness = config.judgeStrictness
        state.isEdited = false
        return state
    }

    // MARK: - The secrets an edit must be given

    /// The typed address reaches a different server than the stored one: another scheme, host
    /// or port. Everything the old address was given is then cleared on save, so every secret
    /// must be typed again (F22).
    var isRepointing: Bool {
        guard let original else { return false }
        return !MCPHTTPConfig.reachSameServer(original.transport.http.urlString, urlString)
    }

    /// A blank token field keeps a stored token: the server sent one, the Keychain holds it,
    /// and the address still reaches the same server. Read under the ORIGINAL config's account —
    /// the origin the token was entered for (`MCPServerConfig.originAccountPrefix`); a new
    /// address names other accounts, so there is nothing there to keep.
    ///
    /// The ONE predicate behind both the placeholder ("Leave blank to keep the stored token")
    /// and the requirement (`requiresBearer`): a blank is refused exactly where there is
    /// nothing to keep.
    var bearerIsKept: Bool {
        guard let original, !isRepointing, original.transport.http.authorization == .staticBearer
        else { return false }
        return storedSecretKeys.contains(original.bearerSecretKey)
    }

    /// Whether a blank token field is refused: under Bearer, whenever no stored token is kept —
    /// a new server, a new address, a server switching TO a token (F42), and a stored server
    /// whose Keychain entry is missing or unreadable. Until the second review of group D
    /// (2026-09-24) that last one could be saved blank under a "Paste the token" placeholder,
    /// and went on reading 401.
    private var requiresBearer: Bool {
        authorization == .staticBearer && !bearerIsKept
    }

    /// A blank value field keeps a stored value: the row carried a header the stored server
    /// sent, the Keychain holds a value under that ORIGINAL name — at the original origin's
    /// account — and the address still reaches the same server. A renamed row keeps it too — the
    /// save moves it to the new name, within that origin.
    ///
    /// The ONE predicate behind both the placeholder and the requirement (`requiresValue`).
    func keepsStoredValue(_ header: HeaderDraft) -> Bool {
        guard let original, !isRepointing, let name = header.originalName else { return false }
        return storedSecretKeys.contains(original.secretKey(forHeader: name))
    }

    /// Whether a blank value is refused: whenever the row keeps no stored value — a row added
    /// in this edit, every row of a new server, every row once the address is another
    /// server's, and a stored row whose Keychain value is missing (F42's corrected rule).
    private func requiresValue(_ header: HeaderDraft) -> Bool {
        !keepsStoredValue(header)
    }

    var bearerPlaceholder: String {
        bearerIsKept ? "Leave blank to keep the stored token" : "Paste the token"
    }

    func valuePlaceholder(for header: HeaderDraft) -> String {
        keepsStoredValue(header) ? "Leave blank to keep" : "Value"
    }

    /// Under a typed secret too short to be scrubbed from what the server's tools return — the
    /// result scrub skips a value under `MCPRedaction.Credentials.Literals.minimumBytes` UTF-8
    /// bytes, because cutting a short value out of an answer corrupts every word it spells.
    /// Counted after trimming, as the Keychain stores it and the scrub reads it.
    static func isTooShortToRedact(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count < MCPRedaction.Credentials.Literals.minimumBytes
    }

    /// States the consequence, not the constant: a person who pasted a key needs to know what
    /// happens to it, not the byte count the scrub uses.
    static let shortSecretWarning =
        "Too short to be removed from tool results: if the server echoes it back, the model reads it."

    // MARK: - What the sheet shows

    /// Whether the token field carries `shortSecretWarning` — only while the sheet shows the
    /// field, under Bearer. Decided here rather than in the sheet's `body`, so the rule has a
    /// test and the sheet reads one value.
    var showsShortTokenWarning: Bool {
        authorization == .staticBearer && Self.isTooShortToRedact(bearerToken)
    }

    /// Whether a header row carries `shortSecretWarning` under its value.
    func showsShortValueWarning(for header: HeaderDraft) -> Bool {
        Self.isTooShortToRedact(header.value)
    }

    /// Whether the trust switch can be changed. Greyed out, not cleared, under a mode that does
    /// not read the mark: the stored mark counts again the moment the mode reads it.
    var isTrustMarkEditable: Bool { approvalMode.readsTrustMark }

    /// The caption under the greyed-out trust switch — the modes that read the mark — and
    /// `nil` while the selected mode reads it.
    var trustMarkCaption: String? {
        isTrustMarkEditable ? nil : MCPApprovalMode.trustMarkCaption
    }

    // MARK: - Validation

    var trimmedSlug: String { slugText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the sheet shows `problems` yet: after a change to any field, or a Save press.
    var revealsProblems: Bool { isEdited || hasAttemptedSave }

    /// A field's value MOVED. Not every write is an edit: a text field writes its binding back
    /// unchanged when it loses focus, and that alone must not reveal the problems.
    private mutating func noteEdit(_ moved: Bool) {
        if moved { isEdited = true }
    }

    /// Save was pressed. Reveals the problems even on an untouched draft, so a Save that did
    /// nothing says why.
    mutating func noteSaveAttempt() { hasAttemptedSave = true }

    /// Everything wrong with the draft, in the order a person would fix it, each once — equal
    /// problems would give the banner's rows equal identities (#22, F56).
    ///
    /// `existing` is every configured server INCLUDING this one — the slug check skips the row
    /// carrying our own id, so re-saving an unchanged server is not a collision with itself.
    func problems(existing: [MCPServerConfig]) -> [Problem] {
        var problems: [Problem] = []

        if trimmedSlug.isEmpty {
            problems.append(.slugMissing)
        } else if MCPServerSlug(trimmedSlug) == nil {
            problems.append(.slugMalformed)
        } else if existing.contains(where: { $0.slug.rawValue == trimmedSlug && $0.id != serverID }) {
            problems.append(.slugTaken(trimmedSlug))
        }

        do {
            _ = try MCPEndpointPolicy.validate(urlString)
        } catch let failure as MCPEndpointPolicy.Failure {
            problems.append(.urlRejected(failure.message))
        } catch {
            problems.append(.urlRejected(MCPEndpointPolicy.Failure.notAURL(urlString).message))
        }

        var seen = Set<String>()
        for header in headers {
            let name = header.trimmedName
            guard !name.isEmpty else { continue }
            let folded = name.lowercased()
            if MCPHTTPConfig.reservedHeaderNames.contains(folded) {
                problems.append(.headerNameReserved(name))
            } else if !Self.isUsableHeaderName(name) {
                problems.append(.headerNameMalformed(name))
            } else if !seen.insert(folded).inserted {
                problems.append(.headerNameRepeated(name))
            } else if header.trimmedValue.isEmpty, requiresValue(header) {
                problems.append(.headerValueMissing(name))
            }
        }

        if requiresBearer, bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.bearerMissing)
        }

        var listed = Set<Problem>()
        return problems.filter { listed.insert($0).inserted }
    }

    func isValid(existing: [MCPServerConfig]) -> Bool {
        problems(existing: existing).isEmpty
    }

    /// An RFC 7230 field-name, narrowed to what a person would actually type. Not a parser —
    /// the transport never interpolates this into a request line, it hands it to Foundation.
    static func isUsableHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    // MARK: - Producing a server

    /// The config this draft describes, or `nil` when it still has problems. Carries header
    /// NAMES only — a value typed here lives in the Keychain and nowhere else.
    ///
    /// An edit starts from the stored config and overwrites only the fields the sheet shows:
    /// the per-server timeouts and the plain headers — which no field here edits — come through
    /// untouched. Until 2026-09-24 the config was rebuilt from the sheet's fields alone, and
    /// every edit, a rename or a flip of the switch included, reset both to their defaults
    /// (F43).
    func makeConfig(existing: [MCPServerConfig]) -> MCPServerConfig? {
        guard isValid(existing: existing),
              let slug = MCPServerSlug(trimmedSlug)
        else { return nil }

        let http = MCPHTTPConfig(
            urlString: urlString,
            headers: original?.transport.http.headers ?? [:],
            secretHeaderNames: headers.map(\.trimmedName).filter { !$0.isEmpty },
            authorization: authorization)
        guard var config = original else {
            return MCPServerConfig(
                id: newServerID, slug: slug, displayName: displayName, transport: .http(http),
                isEnabled: isEnabled, isTrusted: isTrusted, approvalMode: approvalMode,
                judgeStrictness: judgeStrictness)
        }
        config.slug = slug
        config.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.transport = .http(http)
        config.isEnabled = isEnabled
        config.isTrusted = isTrusted
        config.approvalMode = approvalMode
        config.judgeStrictness = judgeStrictness
        return config
    }

    /// What was typed for the Keychain, and each row's original name — the input of
    /// `MCPSecretChangePlan`, which decides what the save writes, moves and clears.
    var secretEdit: MCPServerSecretEdit {
        MCPServerSecretEdit(
            bearer: bearerToken,
            headers: headers.filter { !$0.trimmedName.isEmpty }.map {
                MCPServerSecretEdit.Header(name: $0.trimmedName, originalName: $0.originalName, value: $0.value)
            })
    }
}
