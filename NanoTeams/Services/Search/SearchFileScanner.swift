import Foundation

/// Scanning ONE candidate file: read its bytes (or extract its text), decide whether they are
/// searchable, then run the byte/ICU matcher over every line.
///
/// Split out of `SearchExecutor.run` because it is a distinct reason to change — the matching
/// rules move with `LineScanner`, not with the directory walk. The two parameters are the shape
/// that made the split possible: `SearchScanPlan` is everything read-only the scan needs, and
/// `SearchScanResults` is everything it accumulates. They used to be ~10 separate locals
/// captured implicitly by a nested function.
nonisolated extension SearchExecutor {

    /// Appends every match in `url` to `results`, honouring the per-query cap and the page
    /// budget. Failures (unreadable document, binary, I/O, oversize, cancellation) are routed to
    /// the matching channel on `results` rather than collapsed into one "no matches".
    static func scanFile(
        at url: URL,
        relativePath: String,
        plan: SearchScanPlan,
        into results: inout SearchScanResults
    ) {
        guard !results.budgetExhausted(plan) else { return }
        // Cancel checkpoint at file boundary. The detached tool batch in
        // `LLMExecutionService.executeToolCalls` cancels this task on pause;
        // a 100-MB project with hundreds of files would otherwise keep
        // grepping for seconds after pause-and-decide.
        if Task.isCancelled { return }

        var content: Data
        let ext = url.pathExtension.lowercased()
        if DocumentTextExtractor.isSupported(extension: ext) {
            guard let extracted = DocumentTextExtractor.extractText(from: url) else {
                results.skipped.append(SkippedFile(
                    path: relativePath,
                    reason: "document extractor could not open file as .\(ext)"
                ))
                return
            }
            if DocumentTextExtractor.isFailureMessage(extracted) {
                results.skipped.append(SkippedFile(path: relativePath, reason: extracted))
                return
            }
            // The document path already produced text; hand its bytes to the same scanner.
            content = Data(extracted.utf8)
        } else {
            // Chunked 1-MiB streaming read with `Task.isCancelled` checks
            // between chunks — a paused step stops mid-file. The typed
            // outcome separates the three failure modes (binary / I/O
            // error / cancellation) so each routes to the right reporting
            // channel — collapsing them into one `nil` would silently
            // inflate `results.skippedBinaryCount` after a pause.
            switch readUTF8Streaming(url: url) {
            case .text(let utf8):
                content = utf8
            case .binary:
                results.skippedBinaryCount += 1
                return
            case .ioError(let reason):
                results.skipped.append(SkippedFile(path: relativePath, reason: reason))
                return
            case .cancelled:
                // Don't touch the per-file counters — the count would
                // otherwise grow with every file the cancel walked past.
                return
            case .tooLarge(let bytes):
                results.skipped.append(SkippedFile(
                    path: relativePath,
                    reason: "file is \(bytes) bytes, over the \(maxSearchableFileBytes)-byte search limit"
                ))
                return
            }
        }

        // One byte pass over the file: line spans, per-line non-ASCII flags, and matching —
        // with `String` materialised only for reported lines and for the ICU fallback.
        var isBinaryByEncoding = false
        content.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let buf = raw.bindMemory(to: UInt8.self)
        guard let base = buf.baseAddress, !buf.isEmpty else { return }
        let lineIndex = LineScanner.buildIndex(base, count: buf.count)
        guard lineIndex.isValidUTF8 else { isBinaryByEncoding = true; return }
        results.stats.filesRead += 1
        results.stats.bytesScanned += buf.count
        results.stats.linesScanned += lineIndex.count

        /// Decodes one line's byte span. Every span is independently valid UTF-8 because no
        /// separator can land mid-scalar (see `buildIndex`).
        @inline(__always)
        func text(_ i: Int) -> String {
            let start = Int(lineIndex.starts[i])
            let end = Int(lineIndex.ends[i])
            return String(
                decoding: UnsafeBufferPointer(start: base + start, count: end - start),
                as: UTF8.self
            )
        }

        // Whole-file prefilter. A line is a contiguous subrange of the buffer, so an ASCII
        // needle absent from the WHOLE buffer cannot occur on any ASCII line — and the byte
        // scan is authoritative for exactly those. One scan per (file, query) replaces one
        // per (line, query), which is the zero-hit case this rewrite exists for.
        //
        // Note what this does NOT claim: lines carrying a scalar that could fold or
        // decompose into ASCII are untouched by it and still go to ICU, because ICU can match
        // where the bytes do not (`straße` vs `strasse`). Gating the prefilter on the whole
        // file being pure ASCII would be simpler and nearly useless — 86% of files in this
        // repo carry at least one non-ASCII line, so it would almost never fire.
        var prefilterRuledOut = [Bool](repeating: false, count: plan.needles.count)
        for (qIdx, needle) in plan.needles.enumerated() where plan.regexes[qIdx] == nil {
            guard needle.isASCII, !needle.isEmpty, plan.asciiFoldMatchesLocale else { continue }
            let present = needle.foldedBytes.withUnsafeBufferPointer { nb in
                LineScanner.asciiContains(
                    haystack: base, count: buf.count,
                    needle: nb.baseAddress!, needleCount: nb.count)
            }
            if !present { prefilterRuledOut[qIdx] = true }
        }
        // Every query ruled out AND no line needs ICU ⇒ this file cannot match at all.
        if lineIndex.fileIsByteAuthoritative, prefilterRuledOut.allSatisfy({ $0 }) {
            results.stats.filesPrefiltered += 1
            results.stats.linesScanned -= lineIndex.count
            return
        }

        for idx in 0..<lineIndex.count {
            if results.budgetExhausted(plan) { return }
            // Materialised at most once per line, shared by the regex path, the ICU fallback
            // and the reported match.
            var lineString: String?
            let lineByteAuthoritative = lineIndex.byteAuthoritative[idx]
            let lineStart = base + Int(lineIndex.starts[idx])
            let lineLength = Int(lineIndex.ends[idx] - lineIndex.starts[idx])

            for (qIdx, needle) in plan.needles.enumerated() {
                guard results.perQueryMatches[qIdx].count < plan.perQueryCap else {
                    // This bucket is full, so matches for this query are being DROPPED.
                    // Record it: `total_matches` must not claim an exact corpus total once
                    // any bucket has been cut. With one query `plan.perQueryCap == collectBudget`,
                    // so saturating it also saturates the page and the flag is redundant —
                    // but with N queries a single prolific term can hit `ceil(budget/N)`
                    // while the combined page is nowhere near full.
                    results.perQueryBucketSaturated = true
                    continue
                }
                // Ruled out by the whole-file prefilter — but only for ASCII lines, which is
                // the scope the prefilter can speak for.
                if lineByteAuthoritative, prefilterRuledOut[qIdx] { continue }
                let found: Bool
                if let regex = plan.regexes[qIdx] {
                    let line = lineString ?? text(idx)
                    lineString = line
                    let range = NSRange(line.startIndex..., in: line)
                    found = regex.firstMatch(in: line, options: [], range: range) != nil
                } else if needle.isEmpty {
                    // ICU reports no match for an empty needle; a byte scan would say
                    // "found at offset 0". Keep the ICU answer.
                    found = false
                } else if needle.isASCII, lineByteAuthoritative, plan.asciiFoldMatchesLocale {
                    found = needle.foldedBytes.withUnsafeBufferPointer { nb in
                        LineScanner.asciiContains(
                            haystack: lineStart, count: lineLength,
                            needle: nb.baseAddress!, needleCount: nb.count)
                    }
                } else {
                    // Non-ASCII on either side ⇒ ICU decides, whatever the bytes say.
                    let line = lineString ?? text(idx)
                    lineString = line
                    results.stats.icuComparisons += 1
                    found = line.localizedCaseInsensitiveContains(needle.original)
                }
                guard found else { continue }

                var contextBeforeLines: [LineRef]?
                var contextAfterLines: [LineRef]?
                if plan.contextBefore > 0 {
                    let startIdx = max(0, idx - plan.contextBefore)
                    contextBeforeLines = (startIdx..<idx).map { i in
                        LineRef(line: i + 1, text: text(i))
                    }
                }
                if plan.contextAfter > 0 {
                    let endIdx = min(lineIndex.count, idx + plan.contextAfter + 1)
                    contextAfterLines = ((idx + 1)..<endIdx).map { i in
                        LineRef(line: i + 1, text: text(i))
                    }
                }

                results.perQueryMatches[qIdx].append(SearchMatch(
                    path: relativePath,
                    line: idx + 1,
                    text: lineString ?? text(idx),
                    context_before: contextBeforeLines,
                    context_after: contextAfterLines
                ))
                results.totalMatchCount += 1
                // Line is consumed — don't double-count against other queries.
                break
            }
        }
        }
        if isBinaryByEncoding { results.skippedBinaryCount += 1 }
    }
}
