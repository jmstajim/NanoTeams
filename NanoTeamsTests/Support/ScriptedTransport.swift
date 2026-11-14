import Foundation

@testable import NanoTeams

/// An `MCPTransport` that answers from a script, with no HTTP at all.
///
/// This is the half of the seam that makes `MCPClient`'s rules testable: correlation, the two
/// timers, cancellation, the era probe and the server-request arms are all exercised against
/// frames a test writes by hand, at whatever timing it chooses.
///
/// **A locked class, not an actor**, and not by preference: `MCPTransport` is declared
/// `nonisolated`, and under the TEST target's isolation settings (`InferIsolatedConformances`
/// with no module-wide `-default-isolation`) that pushes `nonisolated` onto the conforming
/// type's declaration — which is invalid on an `actor` and on its synchronous initializer.
/// The app target's own `StreamableHTTPTransport` is an actor and compiles, because that
/// target IS `-default-isolation=MainActor`. A lock says the same thing here and compiles in
/// both modes (2026-09-20).
final class ScriptedTransport: MCPTransport, @unchecked Sendable {

    /// What the server does when a method arrives.
    enum Answer: Sendable {
        case result(JSONValue)
        case error(code: Int, message: String, data: JSONValue? = nil)
        /// Takes the frame and never answers — what a hung server looks like.
        case silence
        /// Answers with arbitrary frames, in order: progress notifications before a result,
        /// a frame for a request nobody made, a malformed correlation.
        case frames([JSONRPCIncoming])
        /// `send` itself never returns until the task running it is cancelled — a POST whose
        /// reply never comes, which only closing the request can end.
        case hangUntilCancelled
        /// `send` itself throws.
        case transportFailure(MCPTransportError)
        /// `send` throws something that is NOT an `MCPTransportError` — the defensive arm a
        /// future transport could reach, and the only way to exercise it.
        case foreignFailure
    }

    private let lock = NSLock()

    /// Per method, consumed in order; the last one repeats so a test need only script what it
    /// cares about. An unscripted method answers `methodNotFound`, which is what a real server
    /// that has never heard of it does.
    private var answers: [String: [Answer]] = [:]
    private var continuation: AsyncStream<MCPIncomingEvent>.Continuation?
    private var stream: AsyncStream<MCPIncomingEvent>?
    private var handedOut = false

    private var sentFrames: [MCPOutgoingFrame] = []
    private var sentHints: [MCPSendHints] = []
    private var cancelledIDs: [JSONRPCID] = []
    private var era: MCPProtocolEra?
    private var protocolVersion: String?
    private var budget: TimeInterval?
    private var connects = 0
    private var answerIndex: [String: Int] = [:]
    private var connectError: MCPTransportError?
    private var abandonedSends = 0
    private var closes = 0
    private var closesReturned = 0
    private var closeDelaySeconds: TimeInterval = 0
    private var closeDelayIgnoresCancellation = false
    private var closesHeld = false
    private var heldCloses: [CheckedContinuation<Void, Never>] = []
    private var connectsHeldUntilClosed = false
    /// A held connect's continuation, resumed `true` by a close and `false` by its bound.
    private var connectsAwaitingClose: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var connectsGivenUp = 0
    private var notificationsHang = false
    private var responsesHang = false
    private var abandonedNotifications = 0
    private var abandonedResponses = 0

    init(answers: [String: [Answer]] = [:]) {
        self.answers = answers
    }

    // MARK: - Reading, for assertions

    var sent: [MCPOutgoingFrame] { lock.withLock { sentFrames } }
    var hints: [MCPSendHints] { lock.withLock { sentHints } }
    var cancelled: [JSONRPCID] { lock.withLock { cancelledIDs } }
    var adoptedEra: MCPProtocolEra? { lock.withLock { era } }
    var adoptedProtocolVersion: String? { lock.withLock { protocolVersion } }
    var closeBudget: TimeInterval? { lock.withLock { budget } }
    var connectCount: Int { lock.withLock { connects } }
    /// How many `.hangUntilCancelled` sends ended because their task was cancelled.
    var abandonedSendCount: Int { lock.withLock { abandonedSends } }
    /// How many times `close` was called — the half of "every opened transport but one is
    /// closed" a test cannot see from `connectCount` alone.
    var closeCount: Int { lock.withLock { closes } }
    var isClosed: Bool { closeCount > 0 }
    /// How many `close` calls have RETURNED — past the delay `setCloseDelay` imposes. A
    /// transport whose close was asked for and has not returned is still closing: a legacy
    /// server's `DELETE` in flight.
    var closeReturnedCount: Int { lock.withLock { closesReturned } }
    /// Notification sends (`hangNotifications`) that ended because their task was cancelled —
    /// a courtesy frame given up on rather than waited for.
    var abandonedNotificationCount: Int { lock.withLock { abandonedNotifications } }
    /// Response sends (`hangResponses`) that ended because their task was cancelled.
    var abandonedResponseCount: Int { lock.withLock { abandonedResponses } }
    /// Held connects (`holdConnectsUntilClosed`) that nobody closed within their bound.
    var givenUpConnectCount: Int { lock.withLock { connectsGivenUp } }

    func script(_ method: String, _ answers: [Answer]) {
        lock.withLock { self.answers[method] = answers }
    }

    func setConnectError(_ error: MCPTransportError?) {
        lock.withLock { connectError = error }
    }

    /// `close` takes this long before it returns — a legacy `DELETE` the server sits on. Real
    /// time, and whatever the budget: the point is a close a caller has to wait through.
    ///
    /// A cancelled caller cuts the wait short, unless `ignoringCancellation`: then the close
    /// takes its whole time whoever is cancelled — a `DELETE` already on the wire, which
    /// cancelling the task that waits for it does not un-send. The ordering a restart's guard
    /// exists for needs that: an older restart's close outliving a newer restart's connect.
    func setCloseDelay(_ seconds: TimeInterval, ignoringCancellation: Bool = false) {
        lock.withLock {
            closeDelaySeconds = seconds
            closeDelayIgnoresCancellation = ignoringCancellation
        }
    }

    /// Every `close` from here on is counted and then HELD — not returning, whoever is cancelled —
    /// until `releaseCloses()`: a legacy `DELETE` the server sits on, for a test that orders
    /// events around the moment it returns instead of reading a delay off the wall clock.
    func holdCloses() {
        lock.withLock { closesHeld = true }
    }

    /// Every `connect` from here on waits until this transport is CLOSED — whoever is cancelled
    /// meanwhile — and then throws `.closed`: a connect only the close ends. `MCPTransport` asks
    /// that of `close` and not of cancellation, so a caller that must end an attempt closes it
    /// rather than waiting for it. Bounded like `.hangUntilCancelled`: a connect nobody closes
    /// gives up after ten seconds, is counted (`givenUpConnectCount`) and throws `.timedOut`, so
    /// a regression that waits for the attempt before closing it fails its test instead of
    /// hanging the run.
    func holdConnectsUntilClosed() {
        lock.withLock { connectsHeldUntilClosed = true }
    }

    /// Lets every held close return, and every later one run through.
    func releaseCloses() {
        let held: [CheckedContinuation<Void, Never>] = lock.withLock {
            closesHeld = false
            defer { heldCloses = [] }
            return heldCloses
        }
        for continuation in held { continuation.resume() }
    }

    /// Every NOTIFICATION `send` hangs until its task is cancelled — a server that accepts the
    /// connection and never answers the POST. Bounded, like `.hangUntilCancelled`.
    func hangNotifications(_ hang: Bool = true) {
        lock.withLock { notificationsHang = hang }
    }

    /// Every RESPONSE `send` — this client answering a server's request — hangs the same way.
    func hangResponses(_ hang: Bool = true) {
        lock.withLock { responsesHang = hang }
    }

    // MARK: - MCPTransport

    func connect() async throws {
        let failure: MCPTransportError? = lock.withLock {
            connects += 1
            // A fresh stream on the first connect and on every connect after a close — what
            // a real server offers a client that reconnects.
            if continuation == nil {
                let (stream, continuation) = AsyncStream<MCPIncomingEvent>.makeStream(
                    bufferingPolicy: .unbounded)
                self.stream = stream
                self.continuation = continuation
                handedOut = false
            }
            return connectError
        }
        if lock.withLock({ connectsHeldUntilClosed }) { try await waitUntilClosed() }
        if let failure { throw failure }
    }

    /// A held connect: returns by throwing — `.closed` once a close arrives, `.timedOut` if none
    /// does within ten seconds. Deaf to cancellation on purpose.
    private func waitUntilClosed() async throws {
        let id = UUID()
        let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alreadyClosed: Bool = lock.withLock {
                guard closes == 0 else { return true }
                connectsAwaitingClose[id] = continuation
                return false
            }
            if alreadyClosed { return continuation.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                let waiting: CheckedContinuation<Bool, Never>? = self.lock.withLock {
                    guard let waiting = self.connectsAwaitingClose.removeValue(forKey: id) else { return nil }
                    self.connectsGivenUp += 1
                    return waiting
                }
                waiting?.resume(returning: false)
            }
        }
        throw closed ? MCPTransportError.closed : MCPTransportError.timedOut
    }

    func adopt(era: MCPProtocolEra, protocolVersion: String) async {
        lock.withLock {
            self.era = era
            self.protocolVersion = protocolVersion
        }
    }

    /// When set, every NOTIFICATION `send` throws it. Requests are unaffected.
    private var notificationFailure: (any Error)?

    func failNotifications(with error: MCPTransportError) {
        lock.withLock { notificationFailure = error }
    }

    /// Every NOTIFICATION `send` throws something that is not an `MCPTransportError`.
    func failNotificationsWithAForeignError() {
        lock.withLock { notificationFailure = ForeignFailure() }
    }

    /// Not an `MCPTransportError`, on purpose.
    struct ForeignFailure: Error {}

    @discardableResult
    func send(_ frame: MCPOutgoingFrame, hints: MCPSendHints) async throws -> MCPSendOutcome {
        lock.withLock {
            sentFrames.append(frame)
            sentHints.append(hints)
        }
        guard case .request(let request) = frame else {
            // A notification never reaches the answer table — it has no id to key one by.
            // The knob is how a test makes the notification path itself fail.
            if case .notification = frame {
                if let error = lock.withLock({ notificationFailure }) { throw error }
                if lock.withLock({ notificationsHang }) {
                    try await hangUntilCancelled { $0.abandonedNotifications += 1 }
                }
            } else if lock.withLock({ responsesHang }) {
                try await hangUntilCancelled { $0.abandonedResponses += 1 }
            }
            return .accepted
        }

        switch nextAnswer(for: request.method) {
        case .silence:
            return .accepted
        case .hangUntilCancelled:
            try await hangUntilCancelled { $0.abandonedSends += 1 }
            return .accepted
        case .transportFailure(let error):
            throw error
        case .foreignFailure:
            throw ForeignFailure()
        case .result(let value):
            push(.response(JSONRPCResponse(id: request.id, outcome: .result(value))))
        case .error(let code, let message, let data):
            push(.response(JSONRPCResponse(
                id: request.id, outcome: .failure(JSONRPCError(code: code, message: message, data: data)))))
        case .frames(let frames):
            for incoming in frames { push(rebind(incoming, to: request.id)) }
        }
        return .answered
    }

    func events() async -> AsyncStream<MCPIncomingEvent> {
        lock.withLock {
            guard let stream, !handedOut else { return AsyncStream { $0.finish() } }
            handedOut = true
            return stream
        }
    }

    func cancel(requestID: JSONRPCID) async {
        lock.withLock { cancelledIDs.append(requestID) }
    }

    func close(budget: TimeInterval) async {
        let (delay, ignoresCancellation, awaitingClose): (TimeInterval, Bool, [CheckedContinuation<Bool, Never>]) =
            lock.withLock {
                closes += 1
                self.budget = budget
                defer { connectsAwaitingClose = [:] }
                return (closeDelaySeconds, closeDelayIgnoresCancellation, Array(connectsAwaitingClose.values))
            }
        // The close was asked for: a connect held until then ends now, whatever this close then
        // waits for.
        for connect in awaitingClose { connect.resume(returning: true) }
        // Only a held close suspends here: an unheld one takes no extra hop, so a test that
        // never holds sees the close it always saw.
        if lock.withLock({ closesHeld }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let held: Bool = lock.withLock {
                    guard closesHeld else { return false }
                    heldCloses.append(continuation)
                    return true
                }
                if !held { continuation.resume() }
            }
        }
        if delay > 0, ignoresCancellation {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        } else if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        let continuation: AsyncStream<MCPIncomingEvent>.Continuation? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(.closed)
        continuation?.finish()
        lock.withLock { closesReturned += 1 }
    }

    /// Waits until the calling task is cancelled, then counts it and throws — or, if nobody
    /// ever cancels, gives up after ten seconds and returns: bounded, so a regression that
    /// never cancels leaves a failed test rather than a task spinning for the rest of the run.
    private func hangUntilCancelled(counting count: (ScriptedTransport) -> Void) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard Task.isCancelled else { return }
        lock.withLock { count(self) }
        throw MCPTransportError.closed
    }

    // MARK: - Pushing frames a test writes

    /// Sends a frame the client never asked for — a notification, or a legacy server request.
    func push(_ frame: JSONRPCIncoming) {
        lock.withLock { continuation }?.yield(.frame(frame))
    }

    func pushFailure(_ error: MCPTransportError) {
        lock.withLock { continuation }?.yield(.failed(error))
    }

    func pushRequestFailure(_ id: JSONRPCID, _ error: MCPTransportError) {
        lock.withLock { continuation }?.yield(.requestFailed(id, error))
    }

    func pushStreamLoss(_ error: MCPTransportError) {
        lock.withLock { continuation }?.yield(.streamLost(error))
    }

    func pushSessionLost() {
        lock.withLock { continuation }?.yield(.sessionLost)
    }

    /// Fills in the request's id on a scripted response whose id was left at zero, so a test
    /// can script "progress, then the result" without knowing which id the client allocated.
    private func rebind(_ frame: JSONRPCIncoming, to id: JSONRPCID) -> JSONRPCIncoming {
        guard case .response(let response) = frame, response.id == .number(0) else { return frame }
        return .response(JSONRPCResponse(id: id, outcome: response.outcome))
    }

    private func nextAnswer(for method: String) -> Answer {
        lock.withLock {
            guard let scripted = answers[method], !scripted.isEmpty else {
                return .error(code: MCPErrorCode.methodNotFound, message: "no such method")
            }
            let index = answerIndex[method] ?? 0
            answerIndex[method] = index + 1
            return scripted[min(index, scripted.count - 1)]
        }
    }
}
