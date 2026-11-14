import Foundation
import Synchronization

/// Which URLs this client will talk to at all.
///
/// The rules are a whitelist, and each one closes a specific hole:
///
///  - **`https`, or `http` only on loopback.** An unencrypted MCP request carries the whole
///    tool call — arguments included — in clear text. The one exception is a server running
///    on this machine (a desktop app's own server), where the traffic never touches a wire.
///  - **No userinfo.** `https://user:pass@host/` puts a credential in a string that is
///    persisted, logged and shown in Settings. It is also the classic way to make a URL look
///    like it points somewhere it does not: `https://api.bank.example@evil.test/`.
///  - **No private, link-local, carrier-NAT, multicast or broadcast addresses.** A server at
///    `192.168.1.2` is a machine on the user's network that they did not necessarily mean to
///    hand tool calls to, and `169.254.169.254` is the cloud metadata endpoint. Judged on the
///    ADDRESS, however it is written: an IPv6 literal that carries an IPv4 address the network
///    may route to — mapped, compatible, SIIT-translated, NAT64, 6to4 — by that IPv4 address,
///    and an IPv4 literal in any spelling but four plain decimal numbers is refused outright —
///    the resolver reads `2852039166`, `10.1`, `012.0.0.1`, `0x0a.0.0.1` and `10.0.0.5.` by
///    `inet_aton`'s rules, a person reads them otherwise, and that difference is the trick.
///    Until 2026-09-23 every one of those passed (F15); the translated forms and the
///    site-local range passed until its second review.
///  - **No loopback that is another machine's.** The IPv4 inside a SIIT, NAT64 or 6to4 address
///    is dialled by the translator or the relay, so its `127.0.0.0/8` is THAT machine's own
///    loopback — a service it listens to only locally. Refused; the mapped and compatible
///    forms are this machine's addresses and keep the loopback exemption. It passed until the
///    third pass of that review.
///
/// **What it does NOT do, stated rather than implied:** it never resolves a hostname. A name
/// that resolves to `10.0.0.5` passes, because the check would have to be repeated at connect
/// time — the address can change between the check and the connection — and a resolver here
/// would be a second, weaker firewall. The redirect delegate is the layer that catches the
/// version of this that matters: a permitted host handing the connection to a forbidden one.
nonisolated enum MCPEndpointPolicy {

    private static let _configuredHostedServerPort = Atomic<UInt16>(HostedMCPConstants.defaultPort)

    /// Updates the active/configured hosted MCP server port so self-connection attempts
    /// to `127.0.0.1:<port>`, `localhost:<port>`, or `[::1]:<port>` are refused (§10.2).
    static func setConfiguredHostedServerPort(_ port: UInt16) {
        _configuredHostedServerPort.store(port, ordering: .relaxed)
    }

    static func configuredHostedServerPort() -> UInt16 {
        _configuredHostedServerPort.load(ordering: .relaxed)
    }

    /// Returns the URL to use, or throws with the reason the user has to fix.
    static func validate(_ urlString: String, hostedServerPort: UInt16? = nil) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            throw Failure.notAURL(trimmed)
        }
        return try validate(url, hostedServerPort: hostedServerPort)
    }

    static func validate(_ url: URL, hostedServerPort: UInt16? = nil) throws -> URL {
        guard let scheme = url.scheme?.lowercased() else { throw Failure.missingScheme(url.absoluteString) }
        guard scheme == "http" || scheme == "https" else { throw Failure.unsupportedScheme(scheme) }
        guard url.user == nil, url.password == nil else { throw Failure.userInfoPresent }
        guard let host = url.host, !host.isEmpty else { throw Failure.missingHost(url.absoluteString) }

        let normalized = LoopbackHost.normalize(host)
        if scheme == "http", !LoopbackHost.isLoopback(normalized) {
            throw Failure.plainHTTPOffLoopback(host: normalized)
        }
        if !LoopbackHost.isLoopback(normalized) {
            if let range = forbiddenRange(of: normalized) {
                throw Failure.forbiddenAddress(host: normalized, range: range)
            }
            if isShorthandIPv4(normalized) {
                throw Failure.shorthandAddress(host: normalized)
            }
        }
        if isThisMachineLoopback(normalized) {
            let effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
            let blockedPort = Int(hostedServerPort ?? configuredHostedServerPort())
            if effectivePort == blockedPort {
                throw Failure.hostedSelfConnection(port: blockedPort)
            }
        }
        return url
    }

    /// `true` without telling the caller why — for a live-validating text field, where the
    /// reason is fetched separately only when it is about to be shown.
    static func allows(_ urlString: String, hostedServerPort: UInt16? = nil) -> Bool {
        (try? validate(urlString, hostedServerPort: hostedServerPort)) != nil
    }

    /// Every spelling of this machine's loopback the resolver accepts — the long form of `::1`
    /// and a zone included (`LoopbackHost.isLoopbackAddress`), which the plaintext rule above
    /// deliberately does not read. Until 2026-11-08 this asked `isLoopback` plus the mapped and
    /// compatible forms, and `https://[0:0:0:0:0:0:0:1]:<port>` passed the self-connection check.
    private static func isThisMachineLoopback(_ normalizedHost: String) -> Bool {
        LoopbackHost.isLoopbackAddress(normalizedHost)
    }

    // MARK: - Address ranges

    /// The name of the range a literal address falls in, or `nil` if it is a hostname or a
    /// public address. Named rather than boolean so the message can say which rule fired.
    ///
    /// Read by the address, not by how it is written: IPv4 as the resolver reads it
    /// (`inet_aton`, so `10.1` and `012.0.0.1` are the 10/8 addresses they are), IPv6 parsed
    /// (`inet_pton`), and an IPv6 literal that carries an IPv4 address judged by that address
    /// (`embeddedIPv4`).
    static func forbiddenRange(of host: String) -> String? {
        if let octets = ipv4Octets(host) { return forbiddenIPv4Range(octets) }
        if let bytes = ipv6Bytes(host) { return forbiddenIPv6Range(bytes) }
        return nil
    }

    /// An IPv4 literal written any other way than four plain decimal numbers — one number for
    /// the whole address, fewer than four parts, an octal or hex part, a leading zero, a
    /// trailing dot. Refused even when it points somewhere public: the resolver and a person
    /// read it differently. The canonical spelling of an address is its four bytes in decimal,
    /// so a literal is shorthand exactly when writing back what it names gives other text.
    static func isShorthandIPv4(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        return octets.map(String.init).joined(separator: ".") != host
    }

    private static func forbiddenIPv4Range(_ o: [UInt8]) -> String? {
        switch (o[0], o[1]) {
        case (0, _): return "0.0.0.0/8"
        case (10, _): return "10.0.0.0/8"
        case (100, 64...127): return "100.64.0.0/10"
        case (169, 254): return "169.254.0.0/16"
        case (172, 16...31): return "172.16.0.0/12"
        case (192, 168): return "192.168.0.0/16"
        case (224...239, _): return "224.0.0.0/4"
        case (240...255, _): return "240.0.0.0/4"
        default: return nil
        }
    }

    private static func forbiddenIPv6Range(_ bytes: [UInt8]) -> String? {
        if bytes.allSatisfy({ $0 == 0 }) { return "::/128" }
        switch embeddedIPv4(bytes) {
        case .thisMachine(let octets)?:
            return forbiddenIPv4Range(octets)
        case .anotherMachine(let octets)?:
            // The IPv4 table leaves 127/8 out because there it means THIS machine; here the
            // translator or the relay dials it, and it means that one.
            return octets[0] == 127 ? "127.0.0.0/8 (the loopback of a translator or relay)" : forbiddenIPv4Range(octets)
        case nil:
            break
        }
        // RFC 8215's local-use translation prefix exists to carry NON-global IPv4, at a place
        // in the address that depends on a prefix length only the network's operator knows —
        // so it is refused whole rather than decoded.
        if bytes[0...5] == [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01] { return "64:ff9b:1::/48" }
        switch bytes[0] {
        case 0xFC, 0xFD: return "fc00::/7"
        case 0xFE where bytes[1] & 0xC0 == 0x80: return "fe80::/10"
        // Site-local: deprecated (RFC 3879), still a private network's address.
        case 0xFE where bytes[1] & 0xC0 == 0xC0: return "fec0::/10"
        case 0xFF: return "ff00::/8"
        default: return nil
        }
    }

    /// The IPv4 address an IPv6 literal carries, and whose address it is.
    private enum EmbeddedIPv4 {
        /// Mapped or compatible: an address of THIS machine's own stack, judged as the IPv4
        /// literal would be — its loopback included.
        case thisMachine([UInt8])
        /// SIIT-translated, NAT64 or 6to4: dialled by a translator or a relay, from its side of
        /// the network — so its loopback is that machine's, not this one's.
        case anotherMachine([UInt8])
    }

    /// The IPv4 address an IPv6 literal carries — the one that is dialled when the network
    /// maps, translates or tunnels it — or `nil` for an address that carries none:
    ///  - mapped `::ffff:a.b.c.d` and compatible `::a.b.c.d` (deprecated, still routed by some
    ///    stacks; `::1`, loopback, is judged before this and is not one) — this machine;
    ///  - SIIT's IPv4-translated `::ffff:0:a.b.c.d` (RFC 2765) — the translator;
    ///  - NAT64's well-known prefix `64:ff9b::/96` (RFC 6052): on an IPv6-only network the
    ///    translator dials the last 32 bits;
    ///  - 6to4 `2002:AABB:CCDD::/48` (RFC 3056): the relay tunnels to bytes 2–5.
    /// Until the second review of group C (2026-09-23) only the first two were read, and
    /// `[64:ff9b::a9fe:a9fe]` reached the metadata endpoint through a translator that does not
    /// filter; until its third pass the last three were judged as this machine's, and
    /// `[64:ff9b::7f00:1]` reached the translator's own loopback.
    private static func embeddedIPv4(_ bytes: [UInt8]) -> EmbeddedIPv4? {
        if let octets = LoopbackHost.thisMachineIPv4(inIPv6: bytes) { return .thisMachine(octets) }
        let last32 = Array(bytes[12..<16])
        let zeroes = { (range: Range<Int>) in bytes[range].allSatisfy { $0 == 0 } }
        if zeroes(0..<8), bytes[8] == 0xFF, bytes[9] == 0xFF, zeroes(10..<12) { return .anotherMachine(last32) }
        if bytes[0...3] == [0x00, 0x64, 0xFF, 0x9B], zeroes(4..<12) { return .anotherMachine(last32) }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return .anotherMachine(Array(bytes[2..<6])) }
        return nil
    }

    /// The parsers live with the rest of "where does this address land" (`LoopbackHost`), so the
    /// ranges judged here and the loopback recognised there read every literal the same way.
    private static func ipv4Octets(_ host: String) -> [UInt8]? { LoopbackHost.ipv4Octets(host) }
    private static func ipv6Bytes(_ host: String) -> [UInt8]? { LoopbackHost.ipv6Bytes(host) }

    // MARK: - Failure

    /// Read by the server editor beside the URL field and by the server row's status. Each
    /// case names the repair, because "invalid URL" leaves the user guessing which rule they
    /// broke.
    nonisolated enum Failure: Error, Hashable, LocalizedError {
        case notAURL(String)
        case missingScheme(String)
        case unsupportedScheme(String)
        case missingHost(String)
        case userInfoPresent
        case plainHTTPOffLoopback(host: String)
        case forbiddenAddress(host: String, range: String)
        /// An IPv4 address in a spelling other than four plain decimal numbers.
        case shorthandAddress(host: String)
        /// Loopback URL targeting NanoTeams' own hosted MCP server port (§10.2).
        case hostedSelfConnection(port: Int)

        var errorDescription: String? { message }

        /// Non-optional for the same reason `MCPTransportError.message` is.
        var message: String {
            switch self {
            case .notAURL:
                return "Enter a full address, starting with https://."
            case .missingScheme:
                return "Add https:// to the front of the address."
            case .unsupportedScheme(let scheme):
                return "This client speaks HTTP only — replace \(scheme):// with https://."
            case .missingHost:
                return "The address names no host. Add the server's hostname after https://."
            case .userInfoPresent:
                return "Remove the username and password from the address — put the token in the token field instead."
            case .plainHTTPOffLoopback(let host):
                return "Use https:// for \(host) — plain HTTP is allowed only for a server on this machine."
            case .forbiddenAddress(let host, let range):
                return "\(host) is in the \(range) range, which this client does not connect to. Use the server's public address."
            case .shorthandAddress(let host):
                return "Write \(host) as four plain decimal numbers, like 93.184.216.34 — this client does not read shorthand, octal or hex addresses."
            case .hostedSelfConnection(let port):
                return "Port \(port) is NanoTeams' own server for external agents — connecting NanoTeams to itself is not allowed."
            }
        }
    }
}

/// Whether a redirect may be followed.
///
/// Same origin only, and the destination is re-validated. A cross-origin redirect is how a
/// permitted host hands the connection — and, without this, the `Authorization` header —
/// to one that was never allowed; `URLSession` follows redirects by default and re-attaches
/// headers on a same-host hop, so the refusal has to be explicit.
nonisolated enum MCPRedirectPolicy {

    /// The origin is `URLOrigin` — scheme, host and port with the default port spelled out, so
    /// `https://x` and `https://x:443` are one origin and `https://x:8443` is another — the same
    /// value the re-point check compares, so the two rules cannot drift apart.
    static func allows(from source: URL, to destination: URL) -> Bool {
        guard (try? MCPEndpointPolicy.validate(destination)) != nil,
              let from = URLOrigin(source), let to = URLOrigin(destination)
        else { return false }
        return from == to
    }
}
