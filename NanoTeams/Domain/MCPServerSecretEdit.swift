import Foundation

/// What the server editor typed for the Keychain, and which stored header each row started as.
/// Never persisted: it lives from the Save press to the Keychain write.
///
/// A blank value means "keep what is stored", never "clear it": the sheet cannot show a stored
/// secret, so a blank field is what every untouched row looks like. What a save CLEARS is decided
/// from what the edit removed — a row, a rename, an authentication mode, an address
/// (`MCPSecretChangePlan`) — never from a blank.
///
/// The empty edit, `MCPServerSecretEdit()`, types nothing: a header it has no row for is kept
/// under its own name. It is what a save with no editor behind it passes.
nonisolated struct MCPServerSecretEdit: Equatable, Sendable {

    /// One secret header row as it stood at Save.
    nonisolated struct Header: Equatable, Sendable {
        /// The header name as saved, trimmed.
        let name: String
        /// The name the row carried when the sheet opened; `nil` for a row added in this edit.
        /// A header's secret is keyed by its NAME, so a rename is a move of the stored value,
        /// and only this tells a renamed row from a new one.
        let originalName: String?
        /// As typed, trimmed. Empty keeps whatever the row's original key holds.
        let value: String

        init(name: String, originalName: String? = nil, value: String = "") {
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.originalName = originalName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// As typed, trimmed. Empty keeps the stored token.
    let bearer: String
    let headers: [Header]

    init(bearer: String = "", headers: [Header] = []) {
        self.bearer = bearer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = headers
    }
}
