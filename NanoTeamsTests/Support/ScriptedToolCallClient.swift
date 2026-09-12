import Foundation
@testable import NanoTeams

// MARK: - Scripted tool-call client

/// Drives the step's tool loop one scripted turn at a time. Clamps to the LAST
/// entry once the script is exhausted, so a test that expects the loop to settle
/// ends its script with the settling turn.
final class ScriptedToolCallClient: LLMClient, @unchecked Sendable {
    enum Turn {
        case toolCall(name: String, argumentsJSON: String)
        case text(String)
        /// Yields nothing and holds the connection until cancelled — for tests
        /// that assert the loop did NOT terminate.
        case hang
        case error(Error)
    }

    private let lock = NSLock()
    private var _callCount = 0
    private var _toolNamesPerRequest: [[String]] = []
    private let script: [Turn]
    /// Called synchronously at the top of each `streamChat`, with the request's 0-based
    /// index — before the scripted turn is produced. A test that needs to change the
    /// world BETWEEN two of the loop's iterations hooks it here.
    var onRequest: (@Sendable (Int) -> Void)?

    init(script: [Turn]) {
        precondition(!script.isEmpty)
        self.script = script
    }

    var callCount: Int { lock.withLock { _callCount } }
    /// The `tools` array of every request, in order — what the wire advertised.
    var toolNamesPerRequest: [[String]] { lock.withLock { _toolNamesPerRequest } }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let (turn, index): (Turn, Int) = lock.withLock {
            let i = min(_callCount, script.count - 1)
            let index = _callCount
            _callCount += 1
            _toolNamesPerRequest.append(tools.map(\.name))
            return (script[i], index)
        }
        onRequest?(index)
        return AsyncThrowingStream { continuation in
            switch turn {
            case .toolCall(let name, let args):
                continuation.yield(StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(
                        index: 0, id: "call_\(UUID().uuidString.prefix(6))",
                        name: name, argumentsDelta: args)
                ]))
                continuation.finish()
            case .text(let t):
                continuation.yield(StreamEvent(contentDelta: t))
                continuation.finish()
            case .error(let e):
                continuation.finish(throwing: e)
            case .hang:
                let producer = Task.detached {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
