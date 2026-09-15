import CoreGraphics
import Foundation

// MARK: - NTMSLoaderAnimationScript

/// `NTMSLoader`'s frame sequence, decided up front instead of one view-state write per tick.
///
/// Until 2026-09-15 every loader ran an 80 ms loop inside `.task` writing three view-state
/// properties per tick, and every such write is a SwiftUI transaction on the WHOLE window.
/// Measured on a run with four live loaders (sidebar row, graph node, bubble caption, pending
/// tool call): the main thread went from 370–470 to 760–975 ms/s busy, 72% of it in SwiftUI's
/// render pass, re-updating an activity feed around spinners that had each changed one glyph.
/// The sequence is now generated once here and handed to Core Animation
/// (`NTMSLoaderLayerView`), which plays it with no main-thread work at all.
///
/// `State.tick` is the old per-tick step verbatim — the same strict `<` gate, burst length,
/// rotation frozen during a burst and resumed from the angle it left, and the one frame of
/// jitter on the first rotation glyph after a burst — so the look is unchanged.
///
/// Pure and `nonisolated`: every decision is testable from a seed (`SeededGenerator`).
nonisolated enum NTMSLoaderAnimationScript {

    /// Frame cadence — the reference's 80 ms.
    static let tickSeconds: Double = 0.08
    /// Probability that an idle frame starts a glitch burst. Tuned so a burst
    /// happens roughly every ~3 seconds (~50 idle frames × 80 ms + burst).
    static let glitchTriggerProbability: Double = 0.02
    /// Length of a glitch burst, in frames.
    static let glitchFrameRange: ClosedRange<Int> = 3...6
    /// Shortest loop Core Animation replays: 256 × 80 ms ≈ 20 s, long enough that the
    /// repeat of a random glitch pattern is not noticed.
    static let minimumCycleTicks = 256

    /// What one 80 ms frame shows.
    struct Frame: Equatable, Sendable {
        /// Index into the rotation glyphs.
        let rotationIndex: Int
        /// The scrambled glyph drawn (with its RGB split) during a burst; nil otherwise.
        let glitchGlyph: String?
        /// 1 pt diagonal jitter; `.zero` when still.
        let shake: CGSize
    }

    /// Everything a sequence depends on besides the random source.
    struct Parameters: Sendable {
        let rotationCount: Int
        let glitchEnabled: Bool
        let probability: Double
        let burstRange: ClosedRange<Int>
        let glitchGlyphs: [String]
    }

    /// The loader's state between two frames — the four properties the view used to own.
    struct State: Equatable {
        var tickCount = 0
        var glitchFramesRemaining = 0
        var currentGlitchChar = "0"
        var shakeOffset: CGSize = .zero

        /// What this state draws. `glitchEnabled == false` shows plain rotation even with a
        /// burst counter left over — that is how toggling the effect off mid-burst settles.
        func frame(_ parameters: Parameters) -> Frame {
            let glitching = parameters.glitchEnabled && glitchFramesRemaining > 0
            return Frame(
                rotationIndex: tickCount % parameters.rotationCount,
                glitchGlyph: glitching ? currentGlitchChar : nil,
                shake: parameters.glitchEnabled ? shakeOffset : .zero
            )
        }

        /// One step. Matches the JS reference:
        /// - During a burst: swap to a fresh random glitch glyph, jitter 1px diag,
        ///   decrement the burst counter. `tickCount` is intentionally untouched
        ///   so rotation resumes from the exact angle when the burst ends.
        /// - Otherwise: advance rotation by one frame, clear jitter, then roll the
        ///   2% chance to start a new burst.
        mutating func tick<G: RandomNumberGenerator>(_ parameters: Parameters, using generator: inout G) {
            if glitchFramesRemaining > 0 && parameters.glitchEnabled {
                currentGlitchChar = parameters.glitchGlyphs.randomElement(using: &generator) ?? "0"
                shakeOffset = CGSize(
                    width: Bool.random(using: &generator) ? 1 : -1,
                    height: Bool.random(using: &generator) ? 1 : -1
                )
                glitchFramesRemaining -= 1
            } else {
                // Idle, or a burst cancelled mid-flight by toggling the effect off —
                // clear any leftover burst counter so it settles on this tick.
                glitchFramesRemaining = 0
                tickCount &+= 1
                shakeOffset = .zero
                let roll = Double.random(in: 0..<1, using: &generator)
                if NTMSLoaderAnimationScript.shouldStartGlitchBurst(
                    glitchEnabled: parameters.glitchEnabled,
                    roll: roll,
                    probability: parameters.probability
                ) {
                    glitchFramesRemaining = Int.random(in: parameters.burstRange, using: &generator)
                    currentGlitchChar = parameters.glitchGlyphs.randomElement(using: &generator) ?? "0"
                }
            }
        }
    }

    /// Pure decision: should an idle frame start a glitch burst? The glitch is the
    /// scramble + RGB-split + jitter overlay; `glitchEnabled == false` suppresses
    /// it entirely (rotation continues). Strict `<` so `roll == probability` never
    /// fires — matches the inline roll this replaced.
    static func shouldStartGlitchBurst(glitchEnabled: Bool, roll: Double, probability: Double) -> Bool {
        glitchEnabled && roll < probability
    }

    /// A loop of at least `minimumTicks` frames that starts at rest and ends where the NEXT
    /// frame would be at rest again (rotation 0, no burst, no jitter), so Core Animation's
    /// repeat is seamless. Capped at four times the minimum: a parameter set that never comes
    /// back to rest (a probability of 1) gets a loop with one visible seam instead of a hang.
    static func make<G: RandomNumberGenerator>(
        _ parameters: Parameters,
        minimumTicks: Int,
        using generator: inout G
    ) -> [Frame] {
        precondition(parameters.rotationCount > 0, "a loader needs at least one rotation glyph")
        precondition(minimumTicks > 0, "a loop needs at least one frame")
        let resting = State().frame(parameters)
        let cap = minimumTicks * 4
        var state = State()
        var frames = [resting]
        while frames.count < cap {
            state.tick(parameters, using: &generator)
            let frame = state.frame(parameters)
            if frames.count >= minimumTicks, frame == resting { return frames }
            frames.append(frame)
        }
        return frames
    }

    /// `keyTimes` for a discrete keyframe animation over `frameCount` equal frames. Core
    /// Animation's discrete mode wants ONE MORE key time than values, from 0 to 1: value `i`
    /// holds from `keyTimes[i]` until `keyTimes[i + 1]`.
    static func keyTimes(frameCount: Int) -> [Double] {
        guard frameCount > 0 else { return [] }
        return (0...frameCount).map { Double($0) / Double(frameCount) }
    }
}
