import Foundation

/// SplitMix64 — a tiny seedable `RandomNumberGenerator` so a randomized test reproduces from
/// its seed alone (Swift ships no seedable RNG; production uses `SystemRandomNumberGenerator`).
///
/// One home (CLAUDE.md #51): until 2026-09-03 this was a `private` copy in each of
/// `ModelTokenCleanerTailTests`, `WatchtowerFigletBannerTests` and `PromptImprovementDisplayTests`,
/// and the fourth randomized suite (`MessageLoopDetectorTests`) drew from the system generator —
/// so a failing trial there printed its trial number and nothing that could be replayed. Include the seed in
/// every assertion message: `xcodebuild` strips them (CLAUDE.md Testing Conventions #7), but a
/// local run still shows what to paste into a hand vector.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
