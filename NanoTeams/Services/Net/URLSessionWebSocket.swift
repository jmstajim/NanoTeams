import Foundation

/// The one production `WebSocketConnecting`. Thin by design — everything worth testing lives above
/// it, so this file is a translation layer and nothing else.
nonisolated struct URLSessionWebSocketConnector: WebSocketConnecting {

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(_ request: URLRequest) async throws -> any WebSocketChannel {
        URLSessionWebSocketChannel(session: session, request: request)
    }
}

/// `@unchecked Sendable` rather than an actor, and the reason is `close()`.
///
/// `URLSessionWebSocketTask`'s own `send`/`receive`/`cancel` are thread-safe, so no lock is needed
/// around the socket itself — only around the closed flag, which exists to keep `close()`
/// idempotent. An actor would have forced `close()` to be `async`, and a close that must be
/// awaited cannot run in a `defer` or a cancellation handler, which is exactly where a socket has
/// to be released.
nonisolated final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var isClosed = false

    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ frame: WebSocketFrame) async throws {
        try await task.send(Self.message(from: frame))
    }

    func receive() async throws -> WebSocketFrame {
        try Self.frame(from: try await task.receive())
    }

    /// The translation, lifted out of the socket calls so it can be tested without one.
    ///
    /// It is the only part of this file with a decision in it, and leaving it inline made it
    /// reachable only through a live server — which is exactly the kind of code that ends up
    /// pinned by nothing and excluded from coverage with an apology.
    static func message(from frame: WebSocketFrame) -> URLSessionWebSocketTask.Message {
        switch frame {
        case .text(let text): .string(text)
        case .binary(let data): .data(data)
        }
    }

    static func frame(from message: URLSessionWebSocketTask.Message) throws -> WebSocketFrame {
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw WebSocketChannelError.unsupportedFrame
        }
    }

    func close() {
        let alreadyClosed = lock.withLock {
            let was = isClosed
            isClosed = true
            return was
        }
        guard !alreadyClosed else { return }
        task.cancel(with: .goingAway, reason: nil)
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }
}
