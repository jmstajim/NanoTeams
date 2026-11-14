import Foundation

/// Is this host the machine the app is running on?
///
/// Two questions, deliberately separate, because two callers mean different things by "local"
/// and collapsing them would be a security bug in one direction and a feature regression in
/// the other:
///
///  - `isLoopback` — traffic that provably never leaves the machine. The MCP endpoint policy
///    asks this before it will allow plain `http`, because an unencrypted request to anything
///    else is readable on the wire.
///  - `isLocalMachine` — loopback plus `0.0.0.0`, the "any interface" spelling a server binds
///    to and a user then types into a settings field. The LM Studio models folder asks this
///    before it will DELETE a file, where the question is "is this server's disk my disk".
///
/// `0.0.0.0` is in the second and not the first on purpose: as a destination macOS routes it
/// to the local host, but it is a wildcard rather than an address, and allowing plaintext to a
/// wildcard is the kind of thing that stops being true when a rule changes elsewhere.
nonisolated enum LoopbackHost {

    /// Strictly 127.0.0.0/8, `::1`, and the `localhost` name.
    static func isLoopback(_ host: String) -> Bool {
        let normalized = normalize(host)
        if normalized == "localhost" || normalized == "::1" { return true }
        return isLoopbackIPv4(normalized)
    }

    /// `isLoopback`, plus the `0.0.0.0` wildcard a user types when their server binds to every
    /// interface.
    static func isLocalMachine(_ host: String) -> Bool {
        isLoopback(host) || normalize(host) == "0.0.0.0"
    }

    /// Convenience over a URL string for callers that hold one.
    static func isLocalMachine(urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else { return false }
        return isLocalMachine(host)
    }

    /// `URL.host` keeps IPv6 literals unbracketed on macOS, but the brackets are stripped
    /// anyway so a hand-typed `[::1]` cannot slip past an equality check. The rule is
    /// `URLOrigin`'s — the one the redirect policy and the re-point check compare origins by —
    /// so what this calls one host is what they call one host.
    static func normalize(_ host: String) -> String {
        URLOrigin.normalizedHost(host)
    }

    /// The whole 127.0.0.0/8 block is loopback, not just 127.0.0.1.
    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    // MARK: - Where a connection lands

    /// Does a connection to `host` reach a loopback address of this machine, however the address
    /// is written? What the self-connection refusal (`MCPEndpointPolicy`) and the `bash`
    /// sandbox's reserved ports (`SeatbeltSandbox.loopbackPort(of:)`) ask — and deliberately not
    /// `isLoopback`, which gates plain HTTP and refuses a spelling a person reads otherwise. Here
    /// every spelling the resolver accepts has to count, or a server dialled through one goes
    /// unguarded (review 2026-11-08):
    ///  - `localhost`, with or without the trailing dot of a fully qualified name, and every name
    ///    under it (RFC 6761 `.localhost`);
    ///  - IPv4 in 127.0.0.0/8 as the resolver reads it (`inet_aton`: `127.1`, `2130706433`);
    ///  - IPv6 `::1` in any spelling, with its zone dropped, and the mapped and compatible forms of
    ///    an address in 127.0.0.0/8 (`::ffff:127.0.0.1`, `::ffff:7f00:1`, `::127.0.0.1`).
    static func isLoopbackAddress(_ host: String) -> Bool {
        let normalized = normalize(host)
        let name = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if let octets = ipv4Octets(normalized) { return octets[0] == 127 }
        guard let bytes = ipv6Bytes(normalized) else { return false }
        if bytes == loopbackIPv6 { return true }
        return thisMachineIPv4(inIPv6: bytes).map { $0[0] == 127 } ?? false
    }

    /// `isLoopbackAddress`, the unspecified addresses (`0.0.0.0`, `::`, which macOS delivers to
    /// this machine), and every address one of this Mac's interfaces holds (`interfaceAddresses`,
    /// read with `getifaddrs`) — so a server reached through the Mac's own LAN address counts too.
    ///
    /// A hostname other than `localhost` is NOT resolved: the address can change between this
    /// answer and the connection, and a resolver here would be a second, weaker firewall
    /// (`MCPEndpointPolicy` declines one for the same reason). `my-mac.local` is therefore not
    /// "this machine" to this predicate, whatever it resolves to.
    static func reachesThisMachine(_ host: String, interfaceAddresses: Set<[UInt8]>) -> Bool {
        if isLoopbackAddress(host) { return true }
        let normalized = normalize(host)
        if let octets = ipv4Octets(normalized) {
            return octets == [0, 0, 0, 0] || interfaceAddresses.contains(octets)
        }
        guard let bytes = ipv6Bytes(normalized) else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if let octets = thisMachineIPv4(inIPv6: bytes) {
            return octets == [0, 0, 0, 0] || interfaceAddresses.contains(octets)
        }
        return interfaceAddresses.contains(withoutEmbeddedScope(bytes))
    }

    /// `reachesThisMachine` against the addresses this Mac's interfaces hold right now.
    static func reachesThisMachine(_ host: String) -> Bool {
        reachesThisMachine(host, interfaceAddresses: interfaceAddresses())
    }

    /// Every address an interface of this Mac holds now — four bytes for IPv4, sixteen for IPv6
    /// (link-local without the interface index the kernel keeps inside it), in network order:
    /// the bytes `ipv4Octets` and `ipv6Bytes` yield. Empty if `getifaddrs` fails.
    static func interfaceAddresses() -> Set<[UInt8]> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: Set<[UInt8]> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var raw = $0.pointee.sin_addr
                    result.insert(withUnsafeBytes(of: &raw) { Array($0) })
                }
            case AF_INET6:
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var raw = $0.pointee.sin6_addr
                    result.insert(withoutEmbeddedScope(withUnsafeBytes(of: &raw) { Array($0) }))
                }
            default:
                continue
            }
        }
        return result
    }

    // MARK: - Address literals

    private static let loopbackIPv6: [UInt8] = Array(repeating: 0, count: 15) + [1]

    /// The four bytes an IPv4 literal names as the resolver reads it — `inet_aton`: one to
    /// four parts, each decimal, octal (`0` prefix) or hex (`0x`), the last filling the
    /// remaining bytes — or `nil` for anything that is not one. A single trailing dot is read
    /// the way the resolver reads it too: as nothing. `MCPEndpointPolicy` judges ranges with it.
    static func ipv4Octets(_ host: String) -> [UInt8]? {
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !bare.isEmpty, bare.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X") })
        else { return nil }
        var address = in_addr()
        guard inet_aton(bare, &address) == 1 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// The sixteen bytes of an IPv6 literal, or `nil` for anything else. A zone (`fe80::1%en0`)
    /// names an interface, not a different address, so it is dropped before the parse. Darwin's
    /// `inet_pton` reads a zone itself — this doc said it did not until the second review of
    /// group C (2026-09-23), and on macOS the strip changes nothing — but the rule does not rest
    /// on that: a libc whose `inet_pton` refuses the zone (glibc's) would make the literal read
    /// as a hostname, and a link-local address would pass. Kept as that guard, deliberately.
    static func ipv6Bytes(_ host: String) -> [UInt8]? {
        guard host.contains(":") else { return nil }
        let address = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        var parsed = in6_addr()
        guard let address, inet_pton(AF_INET6, address, &parsed) == 1 else { return nil }
        return withUnsafeBytes(of: &parsed) { Array($0) }
    }

    /// The IPv4 address an IPv6 literal carries as an address of THIS machine's own stack — mapped
    /// `::ffff:a.b.c.d` or compatible `::a.b.c.d` (deprecated, still routed by some stacks; `::`
    /// and `::1` are not one) — or `nil`. The translated and tunnelled forms carry another
    /// machine's address and are `MCPEndpointPolicy.embeddedIPv4`'s business.
    static func thisMachineIPv4(inIPv6 bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16 else { return nil }
        let last32 = Array(bytes[12..<16])
        let leadingZeroes = { (count: Int) in bytes[0..<count].allSatisfy { $0 == 0 } }
        if leadingZeroes(10), bytes[10] == 0xFF, bytes[11] == 0xFF { return last32 }
        if leadingZeroes(12), !(last32[0..<3].allSatisfy { $0 == 0 }) { return last32 }
        return nil
    }

    /// A link-local address as written (`fe80::1%en0`) and as the kernel reports it (`fe80:4::1`,
    /// the interface index kept in bytes 2–3 by the BSD stack) compared as one address.
    private static func withoutEmbeddedScope(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count == 16, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 else { return bytes }
        var scopeless = bytes
        scopeless[2] = 0
        scopeless[3] = 0
        return scopeless
    }
}
