import XCTest

@testable import NanoTeams

/// The one production websocket adapter. Deliberately thin — everything worth testing lives in
/// `LMStudioWebSocketRPC` above it — so what is pinned here is the translation and the two
/// properties the layer above depends on: a refused connection surfaces as a THROW rather than a
/// hang, and `close()` is idempotent because it runs from `defer` on every path.
final class URLSessionWebSocketTests: XCTestCase {

    /// Port 1 needs root to bind, so nothing on a developer Mac or a CI runner answers there.
    private let unreachable = URL(string: "ws://127.0.0.1:1/system")!

    func testReceive_onARefusedConnection_throwsRatherThanHanging() async throws {
        let channel = try await URLSessionWebSocketConnector()
            .connect(URLRequest(url: unreachable))
        defer { channel.close() }

        do {
            _ = try await channel.receive()
            XCTFail("a refused connection must surface as an error")
        } catch {
            // Which error is the transport's business; that there IS one is ours.
        }
    }

    func testSend_onARefusedConnection_throwsRatherThanHanging() async throws {
        let channel = try await URLSessionWebSocketConnector()
            .connect(URLRequest(url: unreachable))
        defer { channel.close() }

        do {
            try await channel.send(.text("{}"))
            // Some transports buffer the first frame and only fail on the next read; either way
            // the failure must arrive, and it must not be a hang.
            _ = try await channel.receive()
            XCTFail("a refused connection must surface as an error")
        } catch {
            // expected
        }
    }

    /// `close()` runs from a `defer` and could also run from a cancellation path, so a second call
    /// has to be harmless rather than a second cancel on a reused task.
    func testClose_isIdempotent() async throws {
        let channel = try await URLSessionWebSocketConnector()
            .connect(URLRequest(url: unreachable))
        channel.close()
        channel.close()
        channel.close()
    }

    /// The frame enum exists so "skip what we cannot read and keep waiting" stays a decision the
    /// testable layer makes. That requires the two shapes to be distinguishable.
    func testFrame_textAndBinaryAreDistinct() {
        XCTAssertNotEqual(WebSocketFrame.text(""), WebSocketFrame.binary(Data()))
        XCTAssertEqual(WebSocketFrame.text("a"), WebSocketFrame.text("a"))
        XCTAssertEqual(WebSocketFrame.binary(Data([1])), WebSocketFrame.binary(Data([1])))
    }

    // MARK: - A real peer

    /// The adapter's happy path, against an in-process WebSocket server on an ephemeral loopback
    /// port. Everything above it is driven by scripted doubles, so without this the only transport
    /// this app has would be pinned exclusively by its failure paths — a send that never
    /// succeeded, a receive that never returned.
    func testSendAndReceive_againstARealPeer_roundTripBothFrameShapes() async throws {
        let server = try LoopbackWebSocketServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/system"))
        let channel = try await URLSessionWebSocketConnector().connect(URLRequest(url: url))
        defer { channel.close() }

        try await channel.send(.text("{\"hello\":true}"))
        let text = try await channel.receive()
        XCTAssertEqual(text, .text("{\"hello\":true}"))

        try await channel.send(.binary(Data([4, 2])))
        let binary = try await channel.receive()
        XCTAssertEqual(binary, .binary(Data([4, 2])))
    }

    /// And the dialect layer over a real socket, so the handshake this app actually performs is
    /// exercised end to end rather than only against a scripted channel.
    func testRPC_overARealSocket_readsThePeersReply() async throws {
        let server = try LoopbackWebSocketServer()
        let port = try await server.start()
        defer { server.stop() }

        // The echo peer replies with whatever it is sent, so the auth frame comes back as the
        // "auth reply" — which is not `{"success":true}`, and the RPC must therefore refuse it
        // rather than proceed. That is the correct behaviour and the only deterministic one a
        // pure echo can produce.
        let rpc = LMStudioWebSocketRPC(
            connector: URLSessionWebSocketConnector(),
            tokenResolver: StubLLMTokenResolver(),
            timeout: .seconds(2))
        let result = await rpc.call(
            namespace: "system", endpoint: "version",
            baseURLString: "http://127.0.0.1:\(port)", as: EchoedVersion.self)

        XCTAssertNil(result, "an echo is not an approval, and must not be read as one")
    }

    private struct EchoedVersion: Decodable, Sendable {
        var version: String
    }

    // MARK: - The translation

    /// Both directions, without a socket. This is the whole reason the mapping is a static
    /// function rather than an inline `switch` inside the two async calls: inline, it was
    /// reachable only through a live server, and a live server is not something a unit test may
    /// require.
    func testMessage_mapsBothFrameShapes() {
        switch URLSessionWebSocketChannel.message(from: .text("hi")) {
        case .string(let text): XCTAssertEqual(text, "hi")
        default: XCTFail("a text frame must become a string message")
        }
        switch URLSessionWebSocketChannel.message(from: .binary(Data([7, 8]))) {
        case .data(let data): XCTAssertEqual(data, Data([7, 8]))
        default: XCTFail("a binary frame must become a data message")
        }
    }

    func testFrame_mapsBothMessageShapes() throws {
        XCTAssertEqual(try URLSessionWebSocketChannel.frame(from: .string("hi")), .text("hi"))
        XCTAssertEqual(
            try URLSessionWebSocketChannel.frame(from: .data(Data([7]))), .binary(Data([7])))
    }

    /// Round trip, so the pair cannot drift apart: a mapping that is right in one direction and
    /// wrong in the other reads as working right up until a reply comes back.
    func testMessageAndFrame_roundTrip() throws {
        for original in [WebSocketFrame.text("x"), .binary(Data([1, 2, 3])), .text("")] {
            let round = try URLSessionWebSocketChannel.frame(
                from: URLSessionWebSocketChannel.message(from: original))
            XCTAssertEqual(round, original)
        }
    }
}
