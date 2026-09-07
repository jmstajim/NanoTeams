import Foundation

/// FNV-1a over `RuntimePromptRegistry` — the `runtimePromptVersion` of every provenance
/// record, beside `BundledContentFingerprint` (`promptVersion`). Together they answer
/// "which prompt bytes produced this request": the bundled half moves with the reconcile
/// content, this half with the composers — nudges, the Harmony preamble, the error-note
/// policy, the one-shot prompts — which until 2026-09-07 had no version at all.
///
/// `RuntimePromptFingerprintPinTests` pins the value the way the bundled pin does, so a
/// wording change is recorded (and its live effect re-measured, REC.10) rather than shipped
/// under an unchanged provenance.
enum RuntimePromptFingerprint {

    /// Computed once per process, on the main actor — the composers are main-actor code.
    static let current: String = compute(RuntimePromptRegistry.entries)

    /// What the logger seam reads. `NetworkLogger.noteProvenanceIfNeeded` runs inside a
    /// client's stream task, off the main actor, so the value crosses over once:
    /// `prime()` on the main actor, at the one place the app hands a logger to a run
    /// (`NetworkLogger.forRun`). A record written before any prime says so, rather than
    /// carrying a value computed off-actor.
    nonisolated(unsafe) private(set) static var primed: String?
    nonisolated static let unprimedMarker = "unprimed"

    static func prime() {
        primed = current
    }

    #if DEBUG
    /// Tests only: forget the prime so a directly constructed logger writes the marker,
    /// whatever ran earlier in the process.
    static func _testResetPrimed() {
        primed = nil
    }
    #endif

    /// Order-independent (sorted by name) so a registry reshuffle cannot move the value.
    static func compute(_ entries: [RuntimePromptRegistry.Entry]) -> String {
        var hash: UInt64 = 0xcbf5_2913_1c93_1e00
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            for byte in Data((entry.name + "\u{1}" + entry.render() + "\u{2}").utf8) {
                hash ^= UInt64(byte)
                hash = hash &* 0x1000_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }
}
