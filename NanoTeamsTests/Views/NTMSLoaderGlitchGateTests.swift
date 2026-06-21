import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the pure decision behind `NTMSLoader.tick()`'s glitch-burst trigger.
/// The glitch (scramble + RGB-split + jitter) is a decorative flourish on top
/// of the rotation; the user can disable it via Settings → Theme → Effects
/// (`UserDefaultsKeys.spinnerGlitchEnabled`). `shouldStartGlitchBurst` is the
/// gate — the disable flag must trump the probability roll, and the boundary
/// must stay strict so it behaves exactly like the inline `roll < probability`
/// it replaced.
@MainActor
final class NTMSLoaderGlitchGateTests: XCTestCase {

    private let probability = 0.02 // Self.glitchTriggerProbability

    // MARK: - Disable gate trumps the roll

    func testDisabled_neverStartsBurst_evenAtRollZero() async {
        XCTAssertFalse(
            NTMSLoader.shouldStartGlitchBurst(glitchEnabled: false, roll: 0.0, probability: probability),
            "glitchEnabled=false must suppress the burst even at the most-favorable roll (0.0)."
        )
    }

    func testDisabled_neverStartsBurst_acrossRollRange() async {
        for roll in [0.0, 0.001, 0.01, 0.019, 0.02, 0.5, 0.999] {
            XCTAssertFalse(
                NTMSLoader.shouldStartGlitchBurst(glitchEnabled: false, roll: roll, probability: probability),
                "glitchEnabled=false must always be false — roll=\(roll)."
            )
        }
    }

    // MARK: - Enabled: roll vs probability

    func testEnabled_startsBurst_whenRollBelowProbability() async {
        for roll in [0.0, 0.001, 0.019] {
            XCTAssertTrue(
                NTMSLoader.shouldStartGlitchBurst(glitchEnabled: true, roll: roll, probability: probability),
                "Enabled + roll<probability must start a burst — roll=\(roll)."
            )
        }
    }

    func testEnabled_doesNotStartBurst_whenRollAtBoundary() async {
        XCTAssertFalse(
            NTMSLoader.shouldStartGlitchBurst(glitchEnabled: true, roll: probability, probability: probability),
            "Strict `<`: roll == probability must NOT fire (matches the inline roll it replaced)."
        )
    }

    func testEnabled_doesNotStartBurst_whenRollAboveProbability() async {
        for roll in [0.021, 0.1, 0.5, 0.999] {
            XCTAssertFalse(
                NTMSLoader.shouldStartGlitchBurst(glitchEnabled: true, roll: roll, probability: probability),
                "Enabled + roll>probability must not fire — roll=\(roll)."
            )
        }
    }

    // MARK: - Degenerate probability

    func testZeroProbability_neverStartsBurst_evenWhenEnabled() async {
        for roll in [0.0, 0.000001, 0.5] {
            XCTAssertFalse(
                NTMSLoader.shouldStartGlitchBurst(glitchEnabled: true, roll: roll, probability: 0.0),
                "probability=0 means no burst can ever start (0 < 0 is false) — roll=\(roll)."
            )
        }
    }
}
