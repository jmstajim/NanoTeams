import XCTest

@testable import NanoTeams

/// Two questions that look like one. Collapsing them would either allow plaintext to a
/// wildcard address or stop the LM Studio model deletion from recognising its own machine.
final class LoopbackHostTests: XCTestCase {

    func testRecognisesTheWholeLoopbackBlock() {
        for host in ["127.0.0.1", "127.0.0.2", "127.255.255.255", "localhost", "LOCALHOST", "::1", "[::1]"] {
            XCTAssertTrue(LoopbackHost.isLoopback(host), host)
            XCTAssertTrue(LoopbackHost.isLocalMachine(host), host)
        }
    }

    /// `0.0.0.0` is the wildcard a server binds to, not an address. macOS routes it to the
    /// local host, but allowing plaintext to a wildcard is the kind of thing that stops being
    /// true when a rule changes elsewhere.
    func testTheWildcardIsLocalButNotLoopback() {
        XCTAssertFalse(LoopbackHost.isLoopback("0.0.0.0"))
        XCTAssertTrue(LoopbackHost.isLocalMachine("0.0.0.0"))
    }

    func testRejectsEverythingElse() {
        for host in ["192.168.1.2", "10.0.0.1", "example.com", "127.0.0", "127.0.0.1.2",
                     "127.0.0.256", "1270.0.0.1", "", "127.a.b.c", "fe80::1"] {
            XCTAssertFalse(LoopbackHost.isLoopback(host), host)
            XCTAssertFalse(LoopbackHost.isLocalMachine(host), host)
        }
    }

    func testReadsTheHostOutOfAURLString() {
        XCTAssertTrue(LoopbackHost.isLocalMachine(urlString: "  http://127.0.0.1:1234  "))
        XCTAssertTrue(LoopbackHost.isLocalMachine(urlString: "https://localhost:8443/mcp"))
        XCTAssertFalse(LoopbackHost.isLocalMachine(urlString: "https://example.com"))
        XCTAssertFalse(LoopbackHost.isLocalMachine(urlString: ""))
        XCTAssertFalse(LoopbackHost.isLocalMachine(urlString: "not a url"))
    }

    /// `URL.host` keeps IPv6 literals unbracketed on macOS, but a hand-typed `[::1]` must not
    /// slip past the equality check either.
    func testNormalisationStripsBracketsAndCase() {
        XCTAssertEqual(LoopbackHost.normalize("[::1]"), "::1")
        XCTAssertEqual(LoopbackHost.normalize("LocalHost"), "localhost")
    }

    /// The models folder asks this before it moves files to the Trash, so its answer must not
    /// change as MCP tightens its own rule.
    func testTheModelsFolderStillAnswersThroughTheSharedPredicate() {
        XCTAssertTrue(LMStudioModelsFolder.isLocalEndpoint(baseURLString: "http://127.0.0.1:1234"))
        XCTAssertTrue(LMStudioModelsFolder.isLocalEndpoint(baseURLString: "http://0.0.0.0:1234"))
        XCTAssertFalse(LMStudioModelsFolder.isLocalEndpoint(baseURLString: "http://192.168.1.5:1234"))
    }

    // MARK: - Where a connection lands

    /// Every spelling the resolver turns into a loopback address counts — the question a
    /// self-connection refusal and the `bash` sandbox's reserved ports ask. `URL.host` hands an
    /// IPv6 literal over unbracketed with its zone decoded (`::1%lo0`), and `localhost.` with its
    /// dot (measured 2026-11-08), so both forms are here.
    func testIsLoopbackAddress_acceptsEverySpellingOfLoopback() {
        for host in [
            "localhost", "LOCALHOST", "localhost.", "mcp.localhost", "[::1]",
            "127.0.0.1", "127.0.0.2", "127.1", "2130706433", "0x7f.1", "127.0.0.1.",
            "::1", "0:0:0:0:0:0:0:1", "::0001", "::1%lo0", "[::1%lo0]",
            "::ffff:127.0.0.1", "::ffff:7f00:1", "::127.0.0.1", "::ffff:127.9.9.9",
        ] {
            XCTAssertTrue(LoopbackHost.isLoopbackAddress(host), host)
        }
    }

    /// A name other than `localhost` is not resolved, an address that only resembles loopback is
    /// not one, and the plaintext rule's own predicate is untouched: `127.1` stays refused there.
    func testIsLoopbackAddress_refusesEverythingElse() {
        for host in [
            "", "example.com", "localhost.example.com", "notlocalhost", "localhost..", "my-mac.local",
            "0.0.0.0", "::", "10.0.0.1", "128.0.0.1", "127.0.0.1.2", "::2", "fe80::1",
            "::ffff:10.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::",
        ] {
            XCTAssertFalse(LoopbackHost.isLoopbackAddress(host), host)
        }
        XCTAssertFalse(LoopbackHost.isLoopback("127.1"), "the plaintext rule keeps refusing shorthand")
        XCTAssertFalse(LoopbackHost.isLoopback("0:0:0:0:0:0:0:1"))
    }

    /// Loopback, the unspecified addresses macOS delivers to this machine, and every address one
    /// of its interfaces holds — the link-local one compared without the interface index BSD keeps
    /// inside the address (`fe80:4::1` in `getifaddrs`, `fe80::1%en0` as written).
    func testReachesThisMachine_loopbackUnspecifiedAndOwnInterfaces() {
        let interfaces: Set<[UInt8]> = [
            [192, 168, 1, 5],
            [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        ]
        for host in [
            "localhost", "127.0.0.1", "::1", "::ffff:127.0.0.1",
            "0.0.0.0", "::", "::ffff:0.0.0.0", "0",
            "192.168.1.5", "::ffff:192.168.1.5", "fe80::1%en0", "fe80:4::1", "[fe80::1%25en0]",
        ] {
            XCTAssertTrue(LoopbackHost.reachesThisMachine(host, interfaceAddresses: interfaces), host)
        }
        for host in [
            "192.168.1.6", "10.0.0.5", "fe80::2%en0", "example.com", "my-mac.local", "", "0.0.0.1",
        ] {
            XCTAssertFalse(LoopbackHost.reachesThisMachine(host, interfaceAddresses: interfaces), host)
        }
    }

    /// The live list holds at least the loopback interface, in the bytes the parser yields.
    func testInterfaceAddresses_includeTheLoopbackInterface() {
        let live = LoopbackHost.interfaceAddresses()
        XCTAssertTrue(live.contains([127, 0, 0, 1]), "\(live)")
        XCTAssertTrue(live.contains(LoopbackHost.ipv6Bytes("::1") ?? []), "\(live)")
        XCTAssertTrue(LoopbackHost.reachesThisMachine("127.0.0.1"))
    }
}
