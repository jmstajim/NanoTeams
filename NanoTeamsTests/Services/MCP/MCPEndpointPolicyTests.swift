import XCTest

@testable import NanoTeams

/// The whitelist that decides which addresses this client will talk to, and the rule that
/// keeps a permitted host from handing the connection to a forbidden one.
final class MCPEndpointPolicyTests: XCTestCase {

    private func reason(_ urlString: String) -> String {
        do {
            _ = try MCPEndpointPolicy.validate(urlString)
            return ""
        } catch let failure as MCPEndpointPolicy.Failure {
            return failure.errorDescription ?? ""
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Accepted

    func testAcceptsHTTPSAnywhereAndHTTPOnLoopback() throws {
        for url in ["https://trade-room.example/mcp", "https://example.com:8443/mcp",
                    "http://127.0.0.1:3845/mcp", "http://localhost:3845/mcp", "http://[::1]:3845/mcp",
                    "https://127.0.0.1:3845/mcp"] {
            XCTAssertNoThrow(try MCPEndpointPolicy.validate(url), url)
            XCTAssertTrue(MCPEndpointPolicy.allows(url), url)
        }
    }

    func testTrimsSurroundingSpaceBeforeJudging() throws {
        XCTAssertEqual(try MCPEndpointPolicy.validate("  https://example.com/mcp  ").absoluteString,
                       "https://example.com/mcp")
    }

    // MARK: - Refused

    /// An unencrypted MCP request carries the whole tool call — arguments included — in clear
    /// text. The exception is a server on this machine, where nothing touches a wire.
    func testRefusesPlainHTTPOffLoopbackAndNamesTheRepair() {
        XCTAssertTrue(reason("http://example.com/mcp").contains("https://"), reason("http://example.com/mcp"))
        XCTAssertFalse(MCPEndpointPolicy.allows("http://192.168.1.2:3845/mcp"))
    }

    /// `https://trade-room.example@evil.test/` is the classic way to make a URL look
    /// like it points somewhere it does not, and the credential would be persisted in plain
    /// text besides.
    func testRefusesUserInfo() {
        XCTAssertTrue(reason("https://user:pass@example.com/mcp").contains("username"))
        XCTAssertTrue(reason("https://trade-room.example@evil.test/mcp").contains("username"))
    }

    /// `169.254.169.254` is the cloud metadata endpoint; the rest are machines on the user's
    /// own network that they did not necessarily mean to hand tool calls to.
    func testRefusesPrivateLinkLocalAndCarrierRangesOverHTTPSToo() {
        for (host, range) in [("10.0.0.1", "10.0.0.0/8"), ("172.16.0.1", "172.16.0.0/12"),
                              ("172.31.255.1", "172.16.0.0/12"), ("192.168.1.2", "192.168.0.0/16"),
                              ("169.254.169.254", "169.254.0.0/16"), ("100.64.0.1", "100.64.0.0/10"),
                              ("0.0.0.0", "0.0.0.0/8"), ("224.0.0.1", "224.0.0.0/4"),
                              ("255.255.255.255", "240.0.0.0/4")] {
            let text = reason("https://\(host)/mcp")
            XCTAssertTrue(text.contains(range), "\(host): \(text)")
        }
    }

    /// `172.15` and `172.32` are public; a range check that used a prefix string would catch
    /// them by accident.
    func testTheRangeEdgesAreTheRealOnes() {
        XCTAssertTrue(MCPEndpointPolicy.allows("https://172.15.0.1/mcp"))
        XCTAssertTrue(MCPEndpointPolicy.allows("https://172.32.0.1/mcp"))
        XCTAssertTrue(MCPEndpointPolicy.allows("https://100.63.0.1/mcp"))
        XCTAssertTrue(MCPEndpointPolicy.allows("https://100.128.0.1/mcp"))
        XCTAssertFalse(MCPEndpointPolicy.allows("https://100.127.0.1/mcp"))
    }

    func testRefusesIPv6UniqueLocalLinkLocalAndMulticast() {
        for (host, range) in [("[fc00::1]", "fc00::/7"), ("[fd12:3456::1]", "fc00::/7"),
                              ("[fe80::1]", "fe80::/10"), ("[ff02::1]", "ff00::/8")] {
            XCTAssertTrue(reason("https://\(host)/mcp").contains(range), host)
        }
        XCTAssertTrue(MCPEndpointPolicy.allows("https://[2606:4700::1]/mcp"), "a public v6 address is fine")
    }

    /// A forbidden address written another way is the same address. IPv4-mapped and
    /// IPv4-compatible IPv6 carry an IPv4 address in their last 32 bits, and the resolver reads
    /// an IPv4 literal by `inet_aton`'s rules: one decimal number for the whole address, short
    /// forms, octal and hex parts, a trailing dot. Every one of these lands in a range this
    /// client refuses — the metadata endpoint among them — and every one passed.
    ///
    /// RED until 2026-09-23 (review F15).
    func testAForbiddenAddressWrittenAnotherWayIsStillRefused() {
        let hosts = [
            "[::ffff:169.254.169.254]", "[::ffff:a9fe:a9fe]", "[::a9fe:a9fe]", "[::ffff:10.0.0.1]",
            "[0:0:0:0:0:ffff:c0a8:0102]", "[fe80::1%25en0]", "[FE80::1]",
            "2852039166", "10.1", "012.0.0.1", "0x0a.0.0.1", "10.0.0.5.", "0xa9fea9fe", "192.168.513",
        ]
        for host in hosts {
            XCTAssertFalse(MCPEndpointPolicy.allows("https://\(host)/mcp"), host)
        }
    }

    /// Every standard IPv6 form that carries an IPv4 address the network may route to is judged
    /// by that address: NAT64 (`64:ff9b::/96`, RFC 6052 — on an IPv6-only network the
    /// translator dials the IPv4 address in its last 32 bits), SIIT's IPv4-translated
    /// `::ffff:0:a.b.c.d` (RFC 2765), and 6to4 (`2002::/16`, RFC 3056 — bytes 2–5). The message
    /// names the IPv4 range, the rule that fired.
    ///
    /// RED until the second review of group C (2026-09-23): only the mapped and compatible forms
    /// were read, and `https://[64:ff9b::a9fe:a9fe]/` reached the metadata endpoint on a
    /// translator that does not filter.
    func testAnIPv6AddressCarryingAForbiddenIPv4IsJudgedByIt() {
        let cases: [(host: String, range: String)] = [
            ("[64:ff9b::a00:5]", "10.0.0.0/8"),
            ("[64:ff9b::10.0.0.5]", "10.0.0.0/8"),
            ("[64:ff9b::a9fe:a9fe]", "169.254.0.0/16"),
            ("[64:FF9B:0:0:0:0:c0a8:101]", "192.168.0.0/16"),
            ("[::ffff:0:a00:5]", "10.0.0.0/8"),
            ("[::ffff:0:169.254.169.254]", "169.254.0.0/16"),
            ("[2002:a00:5::1]", "10.0.0.0/8"),
            ("[2002:c0a8:101::]", "192.168.0.0/16"),
            ("[2002:a9fe:a9fe:1:2:3:4:5]", "169.254.0.0/16"),
        ]
        for (host, range) in cases {
            let text = reason("https://\(host)/mcp")
            XCTAssertTrue(text.contains(range), "\(host): \(text)")
        }
    }

    /// The IPv4 inside a translated or tunnelled address is dialled by ANOTHER machine — the
    /// NAT64 gateway, the SIIT translator, the 6to4 relay — so its 127.0.0.0/8 is that machine's
    /// loopback: a service it listens to only locally, a router's admin API. Refused, and the
    /// message says whose loopback it is. The mapped and compatible forms are THIS machine's
    /// addresses, judged as they were (`testTheMappedLoopbackKeepsTheJudgementItHad`).
    ///
    /// RED until the third pass of group C's second review (2026-09-23): the embedded address
    /// was judged by the IPv4 table, which leaves 127/8 out because there it means this machine.
    func testTheLoopbackOfATranslatorOrRelayIsRefused() {
        for host in ["[64:ff9b::7f00:1]", "[64:ff9b::127.0.0.1]", "[2002:7f00:1::1]", "[::ffff:0:7f00:1]",
                     "[64:ff9b::7f12:3456]", "[2002:7fff:ffff:1:2:3:4:5]", "[::ffff:0:127.9.9.9]"] {
            let text = reason("https://\(host)/mcp")
            XCTAssertTrue(text.contains("127.0.0.0/8"), "\(host): \(text)")
            XCTAssertTrue(text.contains("translator or relay"), "\(host): \(text)")
            XCTAssertFalse(MCPEndpointPolicy.allows("https://\(host)/mcp"), host)
        }
    }

    /// The mapped and compatible forms carry an address of THIS machine, and the 127/8 in them
    /// is judged exactly as before: allowed over https, and — since only a literal loopback name
    /// or address opens plain http — refused over http.
    func testTheMappedLoopbackKeepsTheJudgementItHad() {
        for host in ["[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[::127.0.0.1]"] {
            XCTAssertTrue(MCPEndpointPolicy.allows("https://\(host)/mcp"), "\(host): \(reason("https://\(host)/mcp"))")
            XCTAssertTrue(reason("http://\(host)/mcp").contains("plain HTTP"), reason("http://\(host)/mcp"))
        }
    }

    /// Two prefixes are refused whole. RFC 8215's local-use translation prefix `64:ff9b:1::/48`
    /// exists precisely to carry NON-global IPv4 — where its 32 bits sit depends on a prefix
    /// length only the operator knows, so it is not decoded. And the deprecated site-local
    /// `fec0::/10` is a private network's address like `fc00::/7`.
    ///
    /// RED until the second review of group C (2026-09-23): both passed.
    func testTheLocalUseTranslationPrefixAndSiteLocalAreRefused() {
        let cases: [(host: String, range: String)] = [
            ("[64:ff9b:1::a00:5]", "64:ff9b:1::/48"),
            ("[64:ff9b:1:abcd::5db8:d822]", "64:ff9b:1::/48"),
            ("[fec0::1]", "fec0::/10"),
            ("[FEFF:1::1]", "fec0::/10"),
        ]
        for (host, range) in cases {
            let text = reason("https://\(host)/mcp")
            XCTAssertTrue(text.contains(range), "\(host): \(text)")
        }
    }

    /// And what those rules must not reach: a translated or 6to4 address carrying a PUBLIC IPv4
    /// is the public address, and a global unicast address beside the 6to4 block, a plain
    /// public one and a hostname are ordinary.
    func testATranslatedPublicAddressAndItsNeighboursStillPass() {
        for url in ["https://[64:ff9b::5db8:d822]/mcp", "https://[64:ff9b::93.184.216.34]/mcp",
                    "https://[::ffff:0:808:808]/mcp", "https://[2002:5db8:d822::1]/mcp",
                    "https://[2003::1]/mcp", "https://[2606:4700:4700::1111]/mcp",
                    "https://mcp.example.com/mcp"] {
            XCTAssertTrue(MCPEndpointPolicy.allows(url), "\(url): \(reason(url))")
        }
    }

    /// A mapped address is judged by the IPv4 address it carries, and the message names that
    /// range — the rule that fired, not a generic refusal.
    func testAMappedAddressIsRefusedWithItsIPv4Range() {
        let text = reason("https://[::ffff:169.254.169.254]/mcp")
        XCTAssertTrue(text.contains("169.254.0.0/16"), text)
    }

    /// An IPv4 address in any spelling but four plain decimal numbers is refused even when it
    /// points somewhere public: a person reads `012.0.0.1` as twelve and the resolver as ten,
    /// and that difference IS the trick. The message says how to write it.
    func testAShorthandIPv4AddressIsRefusedEvenWhenItIsPublicAndSaysHowToWriteIt() {
        let text = reason("https://134744072/mcp")
        XCTAssertFalse(text.isEmpty, "8.8.8.8 as one number")
        XCTAssertTrue(text.contains("four"), text)
        XCTAssertFalse(MCPEndpointPolicy.allows("https://8.8.010.8/mcp"), "a leading zero is octal to the resolver")
    }

    /// What the rule must not reach: a public mapped address, a hostname with a trailing dot, a
    /// hostname that starts with digits, a plain public address in either family.
    func testCanonicalAddressesAndHostnamesStillPass() {
        for url in ["https://[::ffff:8.8.8.8]/mcp", "https://example.com./mcp", "https://1password.com/mcp",
                    "https://8.8.8.8/mcp", "https://[2606:4700::1]/mcp", "https://123.example/mcp",
                    "https://0.example/mcp"] {
            XCTAssertTrue(MCPEndpointPolicy.allows(url), url)
        }
    }

    func testRefusesSchemesThisClientDoesNotSpeak() {
        XCTAssertTrue(reason("ws://example.com/mcp").contains("https://"))
        XCTAssertTrue(reason("file:///etc/passwd").contains("https://"))
        XCTAssertTrue(reason("stdio:///usr/bin/server").contains("https://"))
    }

    func testRefusesSomethingThatIsNotAnAddressAtAll() {
        XCTAssertFalse(reason("").isEmpty)
        XCTAssertFalse(reason("   ").isEmpty)
        XCTAssertFalse(reason("example.com/mcp").isEmpty, "a bare host names no scheme")
        XCTAssertFalse(reason("https://").isEmpty)
    }

    /// Stated rather than implied: a hostname is never resolved. The redirect delegate is the
    /// layer that catches the version of this that matters.
    func testAHostnameIsNotResolved() {
        XCTAssertTrue(MCPEndpointPolicy.allows("https://internal.corp/mcp"))
    }

    func testEveryFailureNamesARepair() {
        let failures: [MCPEndpointPolicy.Failure] = [
            .notAURL("x"), .missingScheme("x"), .unsupportedScheme("ws"), .missingHost("x"),
            .userInfoPresent, .plainHTTPOffLoopback(host: "example.com"),
            .forbiddenAddress(host: "10.0.0.1", range: "10.0.0.0/8"),
            .shorthandAddress(host: "10.1"),
            .hostedSelfConnection(port: 47321),
        ]
        for failure in failures {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure)")
        }
    }

    func testAssess_loopbackMatchingConfiguredHostedServerPort_isRejectedAsSelfConnection() {
        MCPEndpointPolicy.setConfiguredHostedServerPort(47321)
        defer { MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort) }

        for url in [
            "http://127.0.0.1:47321/mcp",
            "http://localhost:47321/mcp",
            "http://[::1]:47321/mcp",
            "https://[::ffff:127.0.0.1]:47321/mcp",
            // Every other spelling of this machine's loopback the resolver accepts (review
            // 2026-11-08): only `https` reaches the check, since plain HTTP to a spelling the
            // plaintext rule does not read is refused before it.
            "https://[0:0:0:0:0:0:0:1]:47321/mcp",
            "https://[::0001]:47321/mcp",
            "https://[::1%25lo0]:47321/mcp",
            "https://localhost.:47321/mcp",
            "https://[::127.0.0.1]:47321/mcp",
        ] {
            XCTAssertThrowsError(try MCPEndpointPolicy.validate(url)) { error in
                XCTAssertEqual(error as? MCPEndpointPolicy.Failure, .hostedSelfConnection(port: 47321), url)
            }
            XCTAssertFalse(MCPEndpointPolicy.allows(url), url)
        }
        XCTAssertTrue(MCPEndpointPolicy.allows("http://127.0.0.1:47322/mcp"))
    }

    /// Moving the parsers to `LoopbackHost` changed no verdict the plaintext rule gives: a
    /// shorthand or long-form loopback spelling over plain HTTP is still refused.
    func testPlainHTTPToALoopbackSpellingThePlaintextRuleDoesNotReadIsStillRefused() {
        for url in ["http://127.1:8080/mcp", "http://[0:0:0:0:0:0:0:1]:8080/mcp", "http://localhost.:8080/mcp"] {
            XCTAssertFalse(MCPEndpointPolicy.allows(url), url)
        }
    }

    // MARK: - Redirects

    /// `URLSession` follows redirects by default AND re-attaches headers on a same-host hop,
    /// so a `302` is how a permitted host hands the `Authorization` header to another one.
    func testARedirectMayNotLeaveTheOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/mcp"))
        XCTAssertTrue(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "https://example.com/v2/mcp"))))
        XCTAssertFalse(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "https://evil.test/mcp"))))
        XCTAssertFalse(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "http://example.com/mcp"))))
        XCTAssertFalse(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "https://example.com:8443/mcp"))))
    }

    /// The destination is re-validated, so a same-origin redirect cannot be used to reach an
    /// address the endpoint policy refuses in the first place.
    func testARedirectDestinationMustItselfBeAllowed() throws {
        let source = try XCTUnwrap(URL(string: "http://127.0.0.1:3845/mcp"))
        XCTAssertTrue(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "http://127.0.0.1:3845/v2"))))
        XCTAssertFalse(MCPRedirectPolicy.allows(
            from: try XCTUnwrap(URL(string: "https://user:p@example.com/a")),
            to: try XCTUnwrap(URL(string: "https://user:p@example.com/b"))))
    }

    /// The origin a redirect is judged by spells the default port out and folds case: a hop to
    /// the same server written differently is still the same origin (`URLOrigin`).
    func testARedirectToTheSameOriginSpelledDifferentlyIsAllowed() throws {
        let source = try XCTUnwrap(URL(string: "https://Example.COM/mcp"))
        XCTAssertTrue(MCPRedirectPolicy.allows(from: source, to: try XCTUnwrap(URL(string: "https://example.com:443/v2"))))
        XCTAssertTrue(MCPRedirectPolicy.allows(
            from: try XCTUnwrap(URL(string: "http://[::1]:3845/mcp")),
            to: try XCTUnwrap(URL(string: "http://[::1]:3845/v2"))))
    }

    /// A hostname falls in no numeric range, which is what makes the policy silent about it
    /// rather than wrong about it.
    func testAHostnameAndAPublicAddressBelongToNoForbiddenRange() {
        XCTAssertNil(MCPEndpointPolicy.forbiddenRange(of: "example.com"))
        XCTAssertNil(MCPEndpointPolicy.forbiddenRange(of: "8.8.8.8"))
        XCTAssertNil(MCPEndpointPolicy.forbiddenRange(of: "2606:4700::1"))
        XCTAssertNil(MCPEndpointPolicy.forbiddenRange(of: "not.an.address.at.all"))
        XCTAssertNil(MCPEndpointPolicy.forbiddenRange(of: "999.1.1.1"))
    }

    func testTheUnspecifiedIPv6AddressIsRefused() {
        XCTAssertEqual(MCPEndpointPolicy.forbiddenRange(of: "::"), "::/128")
    }
}
