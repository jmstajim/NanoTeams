import XCTest

@testable import NanoTeams

/// Pins `NTMSLoaderAnimationScript` — the frame sequence Core Animation plays in place of the
/// loader's old per-tick view-state writes. The sequence must look exactly like the ticker it
/// replaced, and it must loop without a visible seam.
final class NTMSLoaderAnimationScriptTests: XCTestCase {

    private static let pool = ["A", "B", "C"]

    private func parameters(
        glitch: Bool,
        probability: Double = NTMSLoaderAnimationScript.glitchTriggerProbability
    ) -> NTMSLoaderAnimationScript.Parameters {
        NTMSLoaderAnimationScript.Parameters(
            rotationCount: 4,
            glitchEnabled: glitch,
            probability: probability,
            burstRange: NTMSLoaderAnimationScript.glitchFrameRange,
            glitchGlyphs: Self.pool
        )
    }

    private static let resting = NTMSLoaderAnimationScript.Frame(rotationIndex: 0, glitchGlyph: nil, shake: .zero)

    // MARK: - Tuning

    /// RED: retune any of the three → this fails; the doc comments quote "≈ one burst every
    /// ~3 seconds" and an 80 ms cadence, and those numbers are what the user sees.
    func testTuning_isTheDocumentedCadence() {
        XCTAssertEqual(NTMSLoaderAnimationScript.tickSeconds, 0.08)
        XCTAssertEqual(NTMSLoaderAnimationScript.glitchTriggerProbability, 0.02)
        XCTAssertEqual(NTMSLoaderAnimationScript.glitchFrameRange, 3...6)
    }

    // MARK: - Glitch disabled

    /// RED: advance `tickCount` by two, or start from 1 → the rotation stops being `i % 4`.
    func testGlitchDisabled_isPureRotationFromRest() {
        var generator = SeededGenerator(seed: 7)
        let frames = NTMSLoaderAnimationScript.make(parameters(glitch: false), minimumTicks: 16, using: &generator)
        XCTAssertEqual(frames.first, Self.resting)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.rotationIndex, index % 4, "frame \(index)")
            XCTAssertNil(frame.glitchGlyph, "frame \(index)")
            XCTAssertEqual(frame.shake, .zero, "frame \(index)")
        }
        XCTAssertEqual(frames.count, 16, "a pure rotation comes back to rest on every multiple of four")
    }

    /// Degenerate minimum: one frame still yields a loop that starts at rest.
    func testGlitchDisabled_minimumOfOne_loopsAFullRotation() {
        var generator = SeededGenerator(seed: 1)
        let frames = NTMSLoaderAnimationScript.make(parameters(glitch: false), minimumTicks: 1, using: &generator)
        XCTAssertEqual(frames.map(\.rotationIndex), [0, 1, 2, 3])
    }

    /// The disable flag trumps a burst counter already running: the frame shows rotation, and
    /// the next tick settles the counter instead of drawing another glitch glyph.
    func testTogglingGlitchOffMidBurst_settlesOnTheNextTick() {
        var state = NTMSLoaderAnimationScript.State(
            tickCount: 5, glitchFramesRemaining: 3, currentGlitchChar: "B", shakeOffset: CGSize(width: 1, height: -1))
        let off = parameters(glitch: false)
        XCTAssertEqual(state.frame(off), NTMSLoaderAnimationScript.Frame(rotationIndex: 1, glitchGlyph: nil, shake: .zero))
        var generator = SeededGenerator(seed: 3)
        state.tick(off, using: &generator)
        XCTAssertEqual(state.glitchFramesRemaining, 0)
        XCTAssertEqual(state.tickCount, 6)
        XCTAssertEqual(state.shakeOffset, .zero)
    }

    // MARK: - Bursts

    /// With a certain trigger every idle frame starts a burst, which isolates the burst shape:
    /// a run of 3–6 glitch frames, then ONE rotation frame at the angle the run froze on — still
    /// carrying the last jitter, as the ticker did — then the next run one angle further on.
    ///
    /// RED: advance `tickCount` inside the burst branch → the angle check fails. Decrement before
    /// drawing the first glyph → runs come out one short and the length check fails.
    func testBurst_holdsTheAngle_forThreeToSixFrames_thenResumesIt() {
        let always = parameters(glitch: true, probability: 1)
        for seed in UInt64(1)...20 {
            var generator = SeededGenerator(seed: seed)
            var state = NTMSLoaderAnimationScript.State()
            var frames = [state.frame(always)]
            for _ in 0..<200 {
                state.tick(always, using: &generator)
                frames.append(state.frame(always))
            }

            var index = 1
            var previousAngle: Int?
            while index < frames.count {
                let angle = frames[index].rotationIndex
                var run = 0
                while index + run < frames.count, frames[index + run].glitchGlyph != nil {
                    XCTAssertEqual(frames[index + run].rotationIndex, angle, "seed \(seed): rotation moved mid-burst")
                    run += 1
                }
                guard index + run < frames.count else { break }   // the trailing, unfinished run
                XCTAssertTrue(NTMSLoaderAnimationScript.glitchFrameRange.contains(run), "seed \(seed): run of \(run)")
                let settle = frames[index + run]
                XCTAssertEqual(settle.rotationIndex, angle, "seed \(seed): the settle frame changed angle")
                XCTAssertNotEqual(settle.shake, .zero, "seed \(seed): the settle frame keeps the burst's last jitter")
                if let previousAngle {
                    XCTAssertEqual(angle, (previousAngle + 1) % 4, "seed \(seed): rotation skipped an angle")
                }
                previousAngle = angle
                index += run + 1
            }
            XCTAssertNotNil(previousAngle, "seed \(seed): anti-vacuum — no complete burst was checked")
        }
    }

    /// Every glitch glyph comes from the pool, and jitter is exactly ±1 on both axes.
    func testGlitchFrames_drawFromThePool_andJitterByOnePoint() {
        var generator = SeededGenerator(seed: 42)
        let frames = NTMSLoaderAnimationScript.make(parameters(glitch: true, probability: 0.3), minimumTicks: 256, using: &generator)
        let glitching = frames.filter { $0.glitchGlyph != nil }
        XCTAssertFalse(glitching.isEmpty, "anti-vacuum: seed 42 at p=0.3 must produce bursts")
        for frame in frames {
            if let glyph = frame.glitchGlyph { XCTAssertTrue(Self.pool.contains(glyph), glyph) }
            if frame.shake != .zero {
                XCTAssertEqual(abs(frame.shake.width), 1)
                XCTAssertEqual(abs(frame.shake.height), 1)
            }
        }
    }

    // MARK: - The loop

    /// The loop is seamless: replaying the SAME random stream for exactly `frames.count` ticks
    /// lands back on the resting frame Core Animation shows first.
    ///
    /// RED: return on `frames.count >= minimumTicks` without the rest check → the replayed state
    /// is mid-rotation or mid-burst and this fails for most seeds.
    func testLoop_endsWhereTheNextFrameIsTheFirst() {
        let p = parameters(glitch: true, probability: 0.2)
        for seed in UInt64(1)...30 {
            var first = SeededGenerator(seed: seed)
            let frames = NTMSLoaderAnimationScript.make(p, minimumTicks: 64, using: &first)
            XCTAssertGreaterThanOrEqual(frames.count, 64, "seed \(seed)")
            XCTAssertLessThan(frames.count, 256, "seed \(seed): hit the cap, the seam check below would be vacuous")

            var replay = SeededGenerator(seed: seed)
            var state = NTMSLoaderAnimationScript.State()
            for _ in 0..<frames.count { state.tick(p, using: &replay) }
            XCTAssertEqual(state.frame(p), Self.resting, "seed \(seed)")
            XCTAssertEqual(frames.first, Self.resting, "seed \(seed)")
        }
    }

    /// A parameter set that never returns to rest still terminates, at the cap.
    func testLoop_thatNeverRests_stopsAtFourTimesTheMinimum() {
        var generator = SeededGenerator(seed: 9)
        let frames = NTMSLoaderAnimationScript.make(parameters(glitch: true, probability: 1), minimumTicks: 10, using: &generator)
        XCTAssertEqual(frames.count, 40)
    }

    // MARK: - keyTimes

    /// RED: return `frameCount` key times → Core Animation's discrete mode holds the last value
    /// for zero time and the loop's final frame never shows.
    func testKeyTimes_areOneMoreThanTheFrames_fromZeroToOne() {
        for count in [1, 2, 4, 257] {
            let times = NTMSLoaderAnimationScript.keyTimes(frameCount: count)
            XCTAssertEqual(times.count, count + 1, "\(count)")
            XCTAssertEqual(times.first, 0)
            XCTAssertEqual(times.last, 1)
            XCTAssertEqual(times, times.sorted(), "\(count)")
            XCTAssertEqual(Set(times).count, times.count, "\(count): key times must be strictly increasing")
        }
    }

    func testKeyTimes_forNoFrames_isEmpty() {
        XCTAssertEqual(NTMSLoaderAnimationScript.keyTimes(frameCount: 0), [])
        XCTAssertEqual(NTMSLoaderAnimationScript.keyTimes(frameCount: -3), [])
    }
}
