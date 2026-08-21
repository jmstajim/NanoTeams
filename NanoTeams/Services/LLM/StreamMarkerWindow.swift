import Foundation

/// Bounded pre-marker detection for the streaming loop.
///
/// The pre-latch branch of `performStreamingCall` must decide, on EVERY content
/// delta, whether the accumulated `uiBuffer` now carries a Harmony needle — a
/// verbatim marker (`<|call|>` / `<|start|>` / `<|channel|>`) or a mangled
/// sentinel `HarmonySentinelNormalizer` can repair. Scanning the whole buffer for
/// that decision was CLAUDE.md #106 verbatim: a gate deciding whether to do
/// expensive work that itself cost O(buffer) per delta — ≥4 full-buffer substring
/// searches on every delta of a plain-prose reply, Θ(N²/|delta|) across the
/// stream, invisible at runtime because the answer stayed correct.
///
/// The window restores O(delta): every needle is at most `harmonyNeedleSpan`
/// characters, so scanning the newly appended delta plus `needleSpan - 1`
/// characters before it sees every needle the delta could have completed.
/// Adjacent windows overlap by `needleSpan - 1`, so a needle wholly inside the
/// buffer lies wholly inside at least one window — detection over windows is
/// character-equivalent to detection over the whole buffer (pinned by
/// `StreamMarkerWindowTests` against the old whole-buffer decision, verbatim).
/// The needles are ASCII, so no needle character can merge into a neighbouring
/// grapheme cluster and shift the `suffix(_:)` count.
///
/// Once a needle IS detected the caller runs the full-buffer normalize +
/// `range(of:)` — once per stream, behind the `sawHarmonyMarker` latch.
nonisolated enum StreamMarkerWindow {

    /// The longest needle the pre-marker detection must be able to see whole:
    /// the longest verbatim marker, or the alien sentinel's worst case
    /// (`<|tool_call` + a debris run + `{`).
    static let harmonyNeedleSpan = max(
        HarmonyToolCallParser.maxMarkerLength,
        HarmonySentinelNormalizer.maxNeedleSpan)

    /// The suffix of `buffer` that earlier windows have not fully seen: the newly
    /// appended delta plus `needleSpan - 1` characters of overlap before it.
    static func tail(of buffer: String, newDeltaCount: Int, needleSpan: Int) -> Substring {
        buffer.suffix(newDeltaCount + max(needleSpan - 1, 0))
    }

    /// The per-delta decision the streaming loop consumes: did the delta just
    /// appended to `buffer` complete a verbatim marker or a normalizable mangled
    /// sentinel? O(delta + needleSpan), never O(buffer).
    static func harmonyNeedleArrived(buffer: String, newDeltaCount: Int) -> Bool {
        let window = tail(of: buffer, newDeltaCount: newDeltaCount,
                          needleSpan: harmonyNeedleSpan)
        if HarmonyToolCallParser.harmonyMarkers.contains(where: { window.contains($0) }) {
            return true
        }
        return HarmonySentinelNormalizer.hasNormalizableOccurrence(in: window)
    }
}
