import Foundation

/// One websocket frame, in the two shapes a transport can hand back.
///
/// An enum rather than a text-only `receiveText()`, so that "skip a binary frame and keep waiting"
/// stays a POLICY owned by the testable layer above, and the transport adapter below stays a total
/// one-to-one translation with nothing in it worth testing.
nonisolated enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

nonisolated enum WebSocketChannelError: Error, Equatable {
    /// A frame arrived in a shape this app's `WebSocketFrame` cannot represent — a future
    /// `URLSessionWebSocketTask.Message` case. Surfaced rather than mapped to empty data: a
    /// silently-empty frame would be indistinguishable from one the peer really sent.
    case unsupportedFrame
}

/// One open bidirectional channel.
nonisolated protocol WebSocketChannel: Sendable {
    func send(_ frame: WebSocketFrame) async throws
    /// The next frame. Throws when the peer closes or the transport fails.
    func receive() async throws -> WebSocketFrame
    /// Idempotent, SYNCHRONOUS, and safe from any context — deliberately not `async`, so it can
    /// run inside a `defer` and inside a cancellation handler, neither of which may await. A
    /// channel that can only be closed with an `await` is a channel that leaks on cancellation.
    func close()
}

/// Opens channels. The DIP seam: production connects a real socket, tests script frames.
///
/// Takes a whole `URLRequest` rather than a `URL` for the same reason `NetworkSession` does — it
/// is what `URLRequest.applyLMStudioBearer` mutates, so authentication stays one story across both
/// transports instead of two.
nonisolated protocol WebSocketConnecting: Sendable {
    func connect(_ request: URLRequest) async throws -> any WebSocketChannel
}
