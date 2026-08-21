import XCTest

@testable import NanoTeams

/// The LM Studio RPC dialect, driven by a scripted channel so every rule measured against the live
/// server on 2026-08-19 is pinned without a server.
final class LMStudioWebSocketRPCTests: XCTestCase {

    private let base = "http://127.0.0.1:1234"

    private func makeRPC(
        _ channel: ScriptedChannel,
        timeout: Duration = .milliseconds(200)
    ) -> LMStudioWebSocketRPC {
        LMStudioWebSocketRPC(
            connector: ScriptedConnector(channel: channel),
            tokenResolver: StubLLMTokenResolver(),
            timeout: timeout)
    }

    private struct Version: Decodable, Sendable, Equatable {
        var version: String
        var build: Int?
    }

    private func authOK() -> WebSocketFrame { .text(#"{"success":true}"#) }
    private func versionResult(callId: Int = 1) -> WebSocketFrame {
        .text(#"{"type":"rpcResult","callId":\#(callId),"result":{"version":"0.4.21","build":2}}"#)
    }

    /// Waits briefly for a condition a cancelled child task is expected to satisfy. The deadline
    /// path returns from `call` before the losing task has finished unwinding, so asserting
    /// immediately would be a race rather than a check.
    private func eventually(
        _ condition: @escaping @Sendable () -> Bool, within: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - The handshake

    /// Without this frame the server answers NOTHING — not a refusal, silence. So it goes first,
    /// and all three keys must be in it.
    func testCall_sendsTheAuthFrameFirst_withAllThreeKeys() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        let first = channel.sentFrames.first ?? ""
        XCTAssertTrue(first.contains("\"authVersion\":1"), first)
        XCTAssertTrue(first.contains("\"clientIdentifier\":"), first)
        XCTAssertTrue(first.contains("\"clientPasskey\":"), first)
    }

    /// A number, not a string: the server validates the shape and a quoted 1 would be refused.
    func testAuthFrame_encodesAuthVersionAsANumber() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertFalse(channel.sentFrames.first?.contains("\"authVersion\":\"1\"") ?? true)
    }

    /// THE fragile fact of this whole feature. Measured: an `rpcCall` carrying `"parameter":{}` or
    /// `"parameter":null` is refused with "Expected void", and only an ABSENT key answers. This
    /// asserts the encoded bytes because a Swift optional field would encode as `null` or vanish
    /// depending on encoder settings a future refactor will change — and nothing else in the suite
    /// would notice the difference.
    func testRPCCallFrame_hasNoParameterKeyAtAll() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        let rpcFrame = channel.sentFrames.last ?? ""
        XCTAssertTrue(rpcFrame.contains("\"type\":\"rpcCall\""), rpcFrame)
        XCTAssertTrue(rpcFrame.contains("\"endpoint\":\"version\""), rpcFrame)
        XCTAssertFalse(rpcFrame.contains("parameter"), "the key must be absent, not null: \(rpcFrame)")
    }

    func testCall_returnsTheDecodedResult() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertEqual(result, Version(version: "0.4.21", build: 2))
    }

    // MARK: - Refusals

    func testCall_authRefused_neverSendsTheRPCCall() async {
        let channel = ScriptedChannel(incoming: [.text(#"{"success":false}"#)])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertNil(result)
        XCTAssertEqual(channel.sentFrames.count, 1, "only the auth frame should have been sent")
    }

    /// A reply with no `success` key is not an approval. Treating "unrecognised" as "yes" is how a
    /// protocol change turns into a hang.
    func testCall_authReplyWithoutSuccessKey_isARefusal() async {
        let channel = ScriptedChannel(incoming: [.text(#"{"greeting":"hi"}"#)])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertNil(result)
        XCTAssertEqual(channel.sentFrames.count, 1)
    }

    /// The server's own way of saying "that endpoint does not exist". Ending the wait here rather
    /// than at the deadline is what makes a wrong endpoint name fail fast instead of slowly.
    func testCall_warningNamingOurEndpoint_endsTheWaitImmediately() async {
        let warning = WebSocketFrame.text(
            #"{"type":"communicationWarning","warning":"Received rpcCall for unknown endpoint, endpoint = version","kind":"rpcEndpointUnknown"}"#)
        let channel = ScriptedChannel(incoming: [authOK(), warning])

        let started = ContinuousClock.now
        let result = await makeRPC(channel, timeout: .seconds(5)).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertNil(result)
        XCTAssertLessThan(
            started.duration(to: .now), .seconds(2),
            "a knowable failure must not wait out the deadline")
    }

    func testCall_connectFailure_returnsNilWithoutThrowing() async {
        let rpc = LMStudioWebSocketRPC(
            connector: FailingConnector(),
            tokenResolver: StubLLMTokenResolver(),
            timeout: .milliseconds(200))
        let result = await rpc.call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)
        XCTAssertNil(result)
    }

    func testCall_unusableBaseURL_returnsNilAndOpensNothing() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: "not a url", as: Version.self)

        XCTAssertNil(result)
        XCTAssertTrue(channel.sentFrames.isEmpty)
    }

    // MARK: - Frames that are not our answer

    /// A socket answering someone else's question is not our result.
    func testCall_ignoresAFrameWithAnotherCallID() async {
        let channel = ScriptedChannel(incoming: [
            authOK(),
            .text(#"{"type":"rpcResult","callId":99,"result":{"version":"9.9.9"}}"#),
            versionResult(),
        ])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertEqual(result?.version, "0.4.21")
    }

    func testCall_skipsBinaryAndNonJSONFrames() async {
        let channel = ScriptedChannel(incoming: [
            authOK(),
            .binary(Data([0x00, 0x01])),
            .text("not json"),
            versionResult(),
        ])
        let result = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertEqual(result?.version, "0.4.21")
    }

    /// A server that connects, authenticates and then goes quiet is the failure mode a websocket
    /// adds over a request/response call, and the single deadline is what bounds it.
    func testCall_silentServer_isBoundedByTheDeadline() async {
        let channel = ScriptedChannel(incoming: [authOK()], stallAfterScript: true)
        let started = ContinuousClock.now
        let result = await makeRPC(channel, timeout: .milliseconds(150)).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)

        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
    }

    // MARK: - The channel is always released

    func testCall_closesTheChannel_onSuccess() async {
        let channel = ScriptedChannel(incoming: [authOK(), versionResult()])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)
        let closed = await eventually { channel.closeCount >= 1 }
        XCTAssertTrue(closed)
    }

    func testCall_closesTheChannel_onAuthRefusal() async {
        let channel = ScriptedChannel(incoming: [.text(#"{"success":false}"#)])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)
        let closed = await eventually { channel.closeCount >= 1 }
        XCTAssertTrue(closed)
    }

    func testCall_closesTheChannel_onDeadline() async {
        let channel = ScriptedChannel(incoming: [authOK()], stallAfterScript: true)
        _ = await makeRPC(channel, timeout: .milliseconds(100)).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)
        let closed = await eventually { channel.closeCount >= 1 }
        XCTAssertTrue(closed, "a socket abandoned at the deadline still has to be released")
    }

    func testCall_closesTheChannel_whenTheStreamEnds() async {
        let channel = ScriptedChannel(incoming: [authOK()])
        _ = await makeRPC(channel).call(
            namespace: "system", endpoint: "version", baseURLString: base, as: Version.self)
        let closed = await eventually { channel.closeCount >= 1 }
        XCTAssertTrue(closed)
    }

    /// Cancelling the caller must end the read loop, not leave a task reading a socket nobody is
    /// waiting on. The loop's own `Task.isCancelled` check is what does it — the deadline handles
    /// a silent server, but nothing else handles a caller that walked away.
    func testCall_cancelledCaller_stopsReadingAndReleasesTheChannel() async {
        let channel = ScriptedChannel(incoming: [authOK()], stallAfterScript: true)
        let rpc = makeRPC(channel, timeout: .seconds(30))
        // Locals, not `self.base`: a `Task` closure is `sending`, and XCTestCase is not Sendable.
        let endpoint = base

        let task = Task {
            await rpc.call(
                namespace: "system", endpoint: "version", baseURLString: endpoint, as: Version.self)
        }
        // Let the exchange get past the handshake and into the read loop before cancelling.
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        let closed = await eventually { channel.closeCount >= 1 }
        XCTAssertTrue(closed, "an abandoned socket still has to be released")
    }

    // MARK: - URL derivation

    func testWebSocketURL_swapsTheSchemeAndAppendsTheNamespace() {
        XCTAssertEqual(
            LMStudioWebSocketRPC.webSocketURL(
                baseURLString: "http://127.0.0.1:1234", namespace: "system")?.absoluteString,
            "ws://127.0.0.1:1234/system")
        XCTAssertEqual(
            LMStudioWebSocketRPC.webSocketURL(
                baseURLString: "https://box.local:1234", namespace: "runtime")?.absoluteString,
            "wss://box.local:1234/runtime")
    }

    func testWebSocketURL_trailingSlashDoesNotDouble() {
        XCTAssertEqual(
            LMStudioWebSocketRPC.webSocketURL(
                baseURLString: "http://127.0.0.1:1234/", namespace: "system")?.absoluteString,
            "ws://127.0.0.1:1234/system")
    }

    func testWebSocketURL_keepsAPathTheUserTyped() {
        XCTAssertEqual(
            LMStudioWebSocketRPC.webSocketURL(
                baseURLString: "http://box.local/lm", namespace: "system")?.absoluteString,
            "ws://box.local/lm/system")
    }

    func testWebSocketURL_alreadyWebSocketSchemes_arePassedThrough() {
        XCTAssertEqual(
            LMStudioWebSocketRPC.webSocketURL(
                baseURLString: "ws://127.0.0.1:1234", namespace: "system")?.absoluteString,
            "ws://127.0.0.1:1234/system")
    }

    /// A guess would be worse than nothing: this app talks to whatever endpoint the user typed.
    func testWebSocketURL_degenerateInputs_areNil() {
        for bad in ["", "   ", "not a url", "ftp://box.local", "file:///tmp"] {
            XCTAssertNil(
                LMStudioWebSocketRPC.webSocketURL(baseURLString: bad, namespace: "system"),
                "expected nil for \(bad)")
        }
    }
}

// MARK: - Doubles

private final class ScriptedChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [WebSocketFrame]
    private var sent: [String] = []
    private var closes = 0
    private let stallAfterScript: Bool

    init(incoming: [WebSocketFrame], stallAfterScript: Bool = false) {
        self.incoming = incoming
        self.stallAfterScript = stallAfterScript
    }

    var sentFrames: [String] { lock.withLock { sent } }
    var closeCount: Int { lock.withLock { closes } }

    func send(_ frame: WebSocketFrame) async throws {
        if case .text(let text) = frame { lock.withLock { sent.append(text) } }
    }

    func receive() async throws -> WebSocketFrame {
        let next: WebSocketFrame? = lock.withLock {
            incoming.isEmpty ? nil : incoming.removeFirst()
        }
        if let next { return next }
        guard stallAfterScript else { throw WebSocketChannelError.unsupportedFrame }
        // Cancellable, so the deadline can actually reclaim this task.
        try await Task.sleep(for: .seconds(30))
        throw WebSocketChannelError.unsupportedFrame
    }

    func close() { lock.withLock { closes += 1 } }
}

private struct ScriptedConnector: WebSocketConnecting {
    let channel: ScriptedChannel
    func connect(_: URLRequest) async throws -> any WebSocketChannel { channel }
}

private struct FailingConnector: WebSocketConnecting {
    func connect(_: URLRequest) async throws -> any WebSocketChannel {
        throw LLMClientError.missingResponse
    }
}
