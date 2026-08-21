import Foundation
import Network

/// A real WebSocket peer, in-process, on an ephemeral loopback port.
///
/// Exists because `URLSessionWebSocketChannel` is a translation layer over `URLSessionWebSocketTask`
/// and there is no way to exercise a SUCCESSFUL send or receive without something on the other end.
/// The alternative was to leave the adapter's happy path untested and explain it away in the
/// coverage ledger — which would have left the app's first and only websocket transport pinned by
/// nothing but its failure paths.
///
/// Binds port 0 and reports what the OS assigned, so parallel test hosts cannot collide.
final class LoopbackWebSocketServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-websocket-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and resolves once the OS has assigned a port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OneShot()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else { return }
                    resumed.fire { continuation.resume(returning: port) }
                case .failed(let error):
                    resumed.fire { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections = []
        }
    }

    deinit { listener.cancel() }

    /// Echoes every frame back in the shape it arrived, so a round trip through the adapter can be
    /// asserted on both directions at once.
    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard error == nil, let context else { return }
            if let data, !data.isEmpty {
                connection.send(
                    content: data, contentContext: context, isComplete: true,
                    completion: .contentProcessed { _ in })
            }
            self?.receive(on: connection)
        }
    }
}

/// A continuation may be resumed exactly once, and `stateUpdateHandler` can fire repeatedly.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        let alreadyFired = lock.withLock {
            let was = fired
            fired = true
            return was
        }
        guard !alreadyFired else { return }
        body()
    }
}
