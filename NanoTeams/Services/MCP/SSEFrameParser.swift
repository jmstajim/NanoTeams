import Foundation

/// Server-Sent Events, by the specification rather than by one server's habits.
///
/// The app already has `SSEEventParser`, and it is not this: that one is line-oriented and
/// decodes LM Studio's typed events directly (`message.delta`, `chat.end`), because that is
/// the only stream it ever sees. An MCP server's stream carries JSON-RPC frames whose
/// `data` may be split across several lines, and a parser that reads one `data:` line as
/// one frame would hand the codec half a frame — indistinguishable from malformed JSON.
///
/// What the specification says, and this implements:
///  - `field: value`, with exactly one optional space after the colon eaten.
///  - A line with no colon is a field name with an empty value.
///  - A line starting with `:` is a comment. Servers send them as keep-alives; they must
///    not dispatch an event, or every keep-alive would decode as an empty frame.
///  - Several `data:` lines in one event join with `\n`; the trailing newline is dropped.
///  - A blank line dispatches. An event whose data is empty dispatches nothing.
///  - `id:` sets the last event id, which persists across events until reset.
///
/// The one thing added on top: a ceiling. A frame past `MCPConstants.maxFrameBytes` fails
/// the connection LOUDLY instead of truncating — a truncated JSON-RPC frame is
/// indistinguishable from a malformed one, and half a tool result handed to a model reads
/// as a complete answer.
nonisolated struct SSEFrameParser {

    nonisolated struct Frame: Sendable, Hashable {
        /// `event:` if the server sent one, else `message` — the specification's default.
        let event: String
        let data: String
        /// The last id seen on the stream, which the specification says persists past the
        /// event that set it.
        let lastEventID: String?
        /// `retry:` in milliseconds, when this event carried one.
        let retryMilliseconds: Int?
    }

    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case frameTooLarge(bytes: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .frameTooLarge(let bytes, let limit):
                return "The server sent a \(bytes)-byte event, past the \(limit)-byte ceiling. Ask the server to paginate its answer."
            }
        }
    }

    private var eventType: String?
    private var dataLines: [String] = []
    private(set) var lastEventID: String?
    private var retryMilliseconds: Int?
    private var pendingBytes = 0

    private let byteLimit: Int

    init(byteLimit: Int = MCPConstants.maxFrameBytes, lastEventID: String? = nil) {
        self.byteLimit = byteLimit
        self.lastEventID = lastEventID
    }

    /// Feeds one line — as `URLSession.AsyncBytes.lines` yields them, with the terminator
    /// already stripped. Returns a frame when the line dispatched one.
    mutating func consume(line rawLine: String) throws -> Frame? {
        // A stream written with CRLF terminators keeps the CR when split on LF.
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let (field, value) = split(line)
        switch field {
        case "event":
            eventType = value
        case "data":
            pendingBytes += value.utf8.count + 1
            guard pendingBytes <= byteLimit else {
                // Read the count BEFORE resetting: the reset is what makes the parser
                // reusable after the connection is torn down, and it zeroes the counter.
                let overflow = pendingBytes
                reset()
                throw Failure.frameTooLarge(bytes: overflow, limit: byteLimit)
            }
            dataLines.append(value)
        case "id":
            // The specification: an id containing NUL is ignored rather than stored.
            if !value.unicodeScalars.contains(where: { $0.value == 0 }) { lastEventID = value }
        case "retry":
            if let milliseconds = Int(value), milliseconds >= 0 { retryMilliseconds = milliseconds }
        default:
            break   // unknown field — ignored, per the specification
        }
        return nil
    }

    /// Drains a final event a stream ended without a blank line after. Servers do this on
    /// a clean close, and dropping the last frame loses the reply the request was waiting
    /// for.
    mutating func finish() -> Frame? { dispatch() }

    // MARK: - Internals

    private mutating func dispatch() -> Frame? {
        defer { resetEvent() }
        guard !dataLines.isEmpty else { return nil }
        return Frame(
            event: eventType ?? "message",
            data: dataLines.joined(separator: "\n"),
            lastEventID: lastEventID,
            retryMilliseconds: retryMilliseconds)
    }

    /// Clears the event being accumulated. `lastEventID` survives on purpose — the
    /// specification keeps it across events.
    private mutating func resetEvent() {
        eventType = nil
        dataLines = []
        retryMilliseconds = nil
        pendingBytes = 0
    }

    private mutating func reset() {
        resetEvent()
        lastEventID = nil
    }

    /// `field: value`, eating exactly one space after the colon. A line with no colon is a
    /// field name with an empty value.
    private func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart...]))
    }
}
