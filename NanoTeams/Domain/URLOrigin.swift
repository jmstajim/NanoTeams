import Foundation

/// The server an address reaches: its scheme, its host and its port, with the scheme's default
/// port spelled out.
///
/// The ONE spelling of "the same server", read by every rule that asks it: the redirect policy
/// (`MCPRedirectPolicy` — a hop that leaves the origin would take the `Authorization` header
/// with it), the re-point check (`MCPServerConfig.isRepointed(from:)` — a save that leaves it
/// loses every secret and approval the old origin was given), and the name of every Keychain
/// account a server's secrets live in (`accountSegment`). Until the second review of group D
/// (2026-09-24) the first two each kept its own copy, parsed by a different Foundation type,
/// and an IPv6 literal came out as `::1` in one and `[::1]` in the other; a normalization fixed
/// in one would not have reached the other.
///
/// Domain, not Services, so both can read it: the host rule lives here and `LoopbackHost`
/// normalizes through it (`normalizedHost`), rather than Domain reaching into Services.
nonisolated struct URLOrigin: Hashable, Sendable {

    /// Lowercased.
    let scheme: String
    /// `normalizedHost` of the URL's host: brackets off, lowercased.
    let host: String
    /// The URL's port, or the scheme's default; `nil` for a scheme with none this client knows.
    let port: Int?

    /// `nil` for a URL that names no server — no scheme, or no host.
    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let rawHost = url.host else { return nil }
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? Self.defaultPort(for: scheme)
    }

    /// The same, for an address as typed: surrounding whitespace ignored, `nil` when it does not
    /// parse.
    init?(_ urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.init(url)
    }

    /// A host as two spellings of one compare: an IPv6 literal without its brackets — `URL.host`
    /// drops them on macOS, a hand-typed host may not — and every letter lowercased.
    static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    /// This origin as ONE path segment of a Keychain account name
    /// (`<server id>/<segment>/bearer`, `MCPServerConfig.originAccountPrefix`): what binds a
    /// secret to the address it was entered for. A connection reads only the accounts its own
    /// origin spells, so a value typed for any other address is never read by it — whatever
    /// order a save, a failure and a reload happen in.
    ///
    /// `<scheme>:<host>:<port>`, spelled for a person reading Keychain Access —
    /// `https:example.com:443`, `http:[::1]:3845`, the default port written out, and nothing
    /// after the last `:` for a scheme with none. The host has its `%`, `/`, `[` and `]`
    /// percent-escaped in one pass, and is written inside brackets when it holds a `:`.
    ///
    /// **Injective over (`scheme`, `host`, `port`)** — equal origins give equal segments by
    /// construction (a function of the triple), and different ones different segments: the
    /// scheme holds no `:` (Foundation ends it at the first one) and the port is decimal digits
    /// or nothing, so the segment's FIRST `:` ends the scheme and its LAST begins the port, and
    /// the middle is the spelled host. That spelling is injective too — the escape is undone by
    /// reading `%XX` back (a `%` is always one), and a bracketed spelling holds a `:` while an
    /// unbracketed one never does. So no host, however it is written, can make two origins
    /// share a segment, and no segment holds a `/`.
    var accountSegment: String {
        let escaped = Self.percentEscaping(host, ["/", "[", "]"])
        let spelledHost = host.contains(":") ? "[\(escaped)]" : escaped
        return "\(scheme):\(spelledHost):\(port.map(String.init) ?? "")"
    }

    /// `text` with every `%`, and every one of `characters`, written as the `%XX` of its UTF-8
    /// bytes — in one pass, so an escape is never escaped again and the result reads back to
    /// exactly `text`.
    static func percentEscaping(_ text: String, _ characters: Set<Character>) -> String {
        var escaped = ""
        for character in text {
            if character == "%" || characters.contains(character) {
                escaped += character.utf8.map { String(format: "%%%02X", $0) }.joined()
            } else {
                escaped.append(character)
            }
        }
        return escaped
    }

    /// The port a URL of `scheme` reaches when it names none.
    static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
