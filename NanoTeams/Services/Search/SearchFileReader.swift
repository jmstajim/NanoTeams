import Foundation

// Reading a candidate file's bytes off disk, and deciding whether those bytes are
// searchable at all. Split from the executor because it shares no state with the walk:
// it takes a URL and returns a classified outcome.
nonisolated extension SearchExecutor {


    /// Outcome of `readUTF8Streaming`. Distinguishing these four lets the
    /// caller route each to its proper reporting channel — collapsing them
    /// into one `String?` would (and did) silently inflate the binary-skip
    /// count on cancellation and hide I/O errors.
    nonisolated enum StreamReadOutcome {
        /// Raw file bytes. NOT a decoded `String`: `String(data:encoding:.utf8)` copied and
        /// validated the whole file to produce something the scanner never reads as a whole —
        /// line text is decoded lazily, per reported line, from byte spans. UTF-8 validation
        /// now rides `LineScanner.buildIndex`, which already touches every byte.
        case text(Data)
        /// File is not valid UTF-8 — caller increments `skippedBinaryCount`.
        case binary
        /// Mid-read I/O failure (permission, disk error, broken pipe on a
        /// FIFO/socket). Carries a human-readable reason for `skipped_files`.
        case ioError(reason: String)
        /// `Task.isCancelled` observed between chunks. Caller short-circuits
        /// without touching counters.
        case cancelled
        /// Over `maxSearchableFileBytes`. Deliberately NOT `.binary`: an oversize file may be
        /// perfectly good text, and reporting it as an unreadable blob would be a lie. Surfaces
        /// in `skipped_files` with a reason, so the omission is visible rather than silent.
        case tooLarge(bytes: Int)
    }

    /// Files larger than this are reported rather than read.
    ///
    /// Deliberately NOT `SearchIndexService.maxRawTextIndexableBytes` (1 MB): the streaming tests
    /// write 1.5 MiB fixtures and assert the match is still found, so a 1 MB cap would break the
    /// documented contract. 16 MB is far above any hand-written source file while still bounding
    /// the in-memory `Data` — the old code had no cap at all, so a 4 GB video in the work folder
    /// was fully resident before its UTF-8 decode failed.
    static let maxSearchableFileBytes = 16 * 1024 * 1024

    /// Bytes sniffed for a NUL before committing to a full read.
    ///
    /// Same heuristic git and ripgrep use. An extension ALLOWLIST was rejected: it would silently
    /// stop searching text files with unfamiliar extensions (`.gd`, `.zig`, `Makefile`), which is
    /// a correctness regression, whereas a NUL sniff keys on content.
    static let binarySniffBytes = 8192

    /// Streamed UTF-8 read in 1-MiB chunks with `Task.isCancelled` checkpoints.
    /// Accumulates raw bytes then decodes once at the end so multi-byte UTF-8
    /// characters straddling chunk boundaries can't be corrupted.
    ///
    /// Why chunked + accumulate (rather than truly streaming per-line): the
    /// rest of `SearchExecutor` indexes lines by integer (`idx`) and needs
    /// random access for context-before/context-after windowing. A streaming
    /// line iterator would force a structural rewrite. Chunked accumulate
    /// keeps the algorithm identical and adds the cancellation checkpoint.
    // `internal`, not `private`: Swift's `private` is file-scoped, and this moved out of
    // `SearchExecutor.swift` alongside the outcome type it returns.
    static func readUTF8Streaming(url: URL) -> StreamReadOutcome {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .ioError(reason: "could not open: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        // Size gate BEFORE any read. A 0-byte file is legitimate empty text (one empty line),
        // not a binary — classifying it otherwise would inflate `skipped_binary_count` on every
        // placeholder file in the tree.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            if size == 0 { return .text(Data()) }
            if size > maxSearchableFileBytes { return .tooLarge(bytes: size) }
        }

        var buffer = Data()
        let chunkSize = 1 << 20
        var sniffed = false
        while true {
            if Task.isCancelled { return .cancelled }
            let chunk: Data
            do {
                // Per Apple's docs, `nil` from `read(upToCount:)` signals EOF
                // (NOT a non-regular-handle hiccup — those surface via `throws`).
                // I/O errors come through the `catch` arm and route to `.ioError`.
                guard let read = try handle.read(upToCount: chunkSize) else { break }
                chunk = read
            } catch {
                return .ioError(reason: "read failed: \(error.localizedDescription)")
            }
            if chunk.isEmpty { break }

            // Binary sniff on the first chunk only. Without it every `.png` / `.mp4` /
            // `.profraw` in the tree was read IN FULL and UTF-8-validated purely to become
            // `skippedBinaryCount += 1`. It also keeps binaries out of the scanner, which
            // matters more than the I/O: invalid UTF-8 marks every line non-ASCII, so each one
            // would fall through to the ICU slow path.
            //
            // A file that is valid UTF-8 yet contains a literal NUL in its first 8 KB now
            // classifies as binary. That is the documented git/ripgrep heuristic and is pinned
            // by `testBinaryGate_utf8FileWithEmbeddedNUL_classifiedAsBinary`.
            if !sniffed {
                sniffed = true
                if chunk.prefix(binarySniffBytes).contains(0) { return .binary }
            }
            buffer.append(chunk)
        }
        return .text(buffer)
    }
}
