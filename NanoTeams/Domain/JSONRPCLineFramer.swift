import Foundation

/// Incremental newline-delimited JSON-RPC framer shared by the `--mcp-stdio` relay
/// (`HostedMCPStdioRelay`) and future stdio transport components (`D-M1`).
///
/// Uses cursor-offset scanning (`scanOffset` / `lineStartOffset`) with amortized buffer
/// compaction so framing a multi-line chunk runs in $O(N)$ time without quadratic slice shifts.
nonisolated struct JSONRPCLineFramer: Sendable {

    enum Event: Equatable, Sendable {
        case line(Data)
        case lineTooLong
    }

    let maxLineBytes: Int

    private var buffer = Data()
    private var scanOffset: Int = 0
    private var lineStartOffset: Int = 0
    private var discardingOversizedLine = false

    init(maxLineBytes: Int = HostedMCPConstants.maxBodyBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    mutating func append(_ chunk: Data) -> [Event] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var events: [Event] = []

        while scanOffset < buffer.count {
            let byte = buffer[scanOffset]
            if byte == 0x0A {
                if discardingOversizedLine {
                    discardingOversizedLine = false
                } else if let trimmed = Self.trimmedNonEmptySlice(
                    in: buffer,
                    range: lineStartOffset..<scanOffset
                ) {
                    events.append(.line(trimmed))
                }
                scanOffset += 1
                lineStartOffset = scanOffset
                continue
            }

            let currentLength = (scanOffset - lineStartOffset) + 1
            if !discardingOversizedLine, currentLength > maxLineBytes {
                discardingOversizedLine = true
                events.append(.lineTooLong)
            }
            scanOffset += 1
        }

        compactIfNeeded()
        return events
    }

    /// Flushes any trailing non-empty bytes when the input stream reaches EOF without a final `\n`.
    mutating func finish() -> [Event] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            scanOffset = 0
            lineStartOffset = 0
            discardingOversizedLine = false
        }
        guard !discardingOversizedLine, lineStartOffset < buffer.count,
              let trimmed = Self.trimmedNonEmptySlice(in: buffer, range: lineStartOffset..<buffer.count)
        else {
            return []
        }
        return [.line(trimmed)]
    }

    /// Formats a JSON-RPC payload as a single newline-terminated UTF-8 line.
    static func formatLine(_ payload: Data) -> Data {
        var normalized = Data()
        normalized.reserveCapacity(payload.count + 1)
        for byte in payload where byte != 0x0A && byte != 0x0D {
            normalized.append(byte)
        }
        normalized.append(0x0A)
        return normalized
    }

    // MARK: - Private Helpers

    private mutating func compactIfNeeded() {
        if lineStartOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            scanOffset = 0
            lineStartOffset = 0
        } else if lineStartOffset >= 4096, lineStartOffset * 2 >= buffer.count {
            buffer.removeSubrange(0..<lineStartOffset)
            scanOffset -= lineStartOffset
            lineStartOffset = 0
        }
    }

    private static func trimmedNonEmptySlice(in data: Data, range: Range<Int>) -> Data? {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, isASCIIWhitespace(data[start]) {
            start += 1
        }
        while end > start, isASCIIWhitespace(data[end - 1]) {
            end -= 1
        }
        guard start < end else { return nil }
        return data.subdata(in: start..<end)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}
