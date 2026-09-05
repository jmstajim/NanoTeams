import Foundation

// DERIVED from a real NanoTeams run — reduced to the shape under test.
//
// Source: MeditationApp/.nanoteams/internal/tasks/28/runs/0/tool_calls.jsonl
// Model:  qwen3.8:27b-mlx (Ollama). 20 `edit_file` calls, 4 failed, all
//         ANCHOR_NOT_FOUND / indentation_mismatch, all on ContentView.swift.
//
// TIME OF DAY IS REBASED. The four calls were captured on 2026-08-15,
// 17:28:40.681Z … 17:30:08.696Z; every clock time in this file — the `timestamp`
// fields AND the times quoted in the comments below — is that wall clock PLUS
// 5 HOURS, for the test target's 20:00–02:00 band (wave `19988137`). Only the
// hour field moved, so the run's intervals and its order are the capture's own.
// The offset differs from task 24's +11 h because the two runs are 7.5 h apart
// and the usable half-band is 4 h wide; +5 h is the value that also keeps this
// run AFTER task 24's rebased span (which ends 21:08:30.362Z), as it was on the day.
//
// The `timestamp`s are LOOKUP KEYS, prefix-matched from
// `EditFileInsertionReindentTests`. A one-sided edit traps the test host rather
// than reddening a test — see `failure(at:)` at the bottom of this file.
//
// The anchors are VERBATIM (they are three and five lines). The file and the
// replacements are reduced: the real ones are 367 and ~28 lines of SwiftUI whose
// only relevant property is their INDENTATION VOCABULARY, so each is cut to the
// smallest text carrying the same depths. Storing the originals verbatim buried
// that property in 20 KB of scenery.
//
// What every case preserves, because it is what the run turned on:
//
//   file window     8, 8, 8, 4, 0
//   anchor          9, 9, 9, 5, 0   → map {9→8, 5→4}, a clean function
//   replacement     the anchor reproduced, then a new block at 4, 8, 12, 18
//                   — depths the anchor could not have shown
//
// The 9-and-5-space anchor IS the fixture: the model re-emitted the file's 8 and 4
// one space wider, every time, including immediately after `read_lines` had handed
// it the correct bytes. Do not tidy it.
enum EditFileTask28Fixtures {
    struct FailedEdit {
        let timestamp: String
        /// What the model did between this call and the previous one, for the test
        /// that asserts the run is a loop rather than progress.
        let note: String
        let oldText: String
        let newText: String
    }

    static let path = "MeditationApp/ContentView.swift"

    /// `ContentView.swift` reduced to the region the four calls addressed. Four-space
    /// convention throughout — the file was never irregular here, which is what makes
    /// this run's failure purely the model's re-emission.
    static let contentAtFailure = """
    struct LibraryEmptyState: View {
        var body: some View {
            VStack(spacing: 12) {
                Text("No sessions yet")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Library empty. No meditation sessions are available yet.")
        }
    }
    
    // MARK: - Profile Tab
    
    """

    /// The appended block, at the depths the model actually used (4, 8, 12, and a
    /// body depth it perturbed on every retry). Parameterised on that last depth
    /// because perturbing it — while the anchor stayed byte-identical — is exactly
    /// what kept `argumentsIdentity` changing and the failure-loop detector silent.
    private static func appendedBlock(bodyDepth: Int) -> String {
        let deep = String(repeating: " ", count: bodyDepth)
        return """
        
        
        /// Shown when an active category filter matches no sessions.
        private struct LibraryCategoryEmptyState: View {
            let category: SessionCategory?
        
            var body: some View {
                VStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
        \(deep).font(.largeTitle)
                }
            }
        }
        """
    }

    /// 22:28:40.681 — the first failure. Five-line anchor.
    private static let fiveLineAnchor = """
             .frame(maxWidth: .infinity)
             .accessibilityElement(children: .combine)
             .accessibilityLabel("Library empty. No meditation sessions are available yet.")
         }
    }
    """

    /// 22:29:12 onward — the model shortened the anchor to three lines and then held
    /// it byte-identical for three consecutive calls.
    private static let threeLineAnchor = """
             .accessibilityLabel("Library empty. No meditation sessions are available yet.")
         }
    }
    """

    static let failures: [FailedEdit] = [
        FailedEdit(
            timestamp: "2026-08-15T22:28:40.681Z",
            note: "first attempt, five-line anchor",
            oldText: fiveLineAnchor,
            newText: fiveLineAnchor + appendedBlock(bodyDepth: 17)
        ),
        FailedEdit(
            timestamp: "2026-08-15T22:29:12.726Z",
            note: "shortened the anchor after two read_lines calls",
            oldText: threeLineAnchor,
            newText: threeLineAnchor + appendedBlock(bodyDepth: 18)
        ),
        FailedEdit(
            timestamp: "2026-08-15T22:29:36.671Z",
            note: "identical anchor, body depth 18 → 19",
            oldText: threeLineAnchor,
            newText: threeLineAnchor + appendedBlock(bodyDepth: 19)
        ),
        FailedEdit(
            timestamp: "2026-08-15T22:30:08.696Z",
            note: "identical anchor, body depth 19 → 20, after bash was denied",
            oldText: threeLineAnchor,
            newText: threeLineAnchor + appendedBlock(bodyDepth: 20)
        ),
    ]

    /// The anchor the model finally succeeded with (22:31:11), after re-reading the
    /// whole file: a single zero-indent line. Nothing about it needs indentation
    /// reproduced, which is the whole reason it worked.
    static let escapeAnchor = "// MARK: - Profile Tab"

    /// Looks up one failure by the timestamp printed in the run log, so a failing
    /// assertion points straight back at the call that produced it.
    static func failure(at timestamp: String) -> FailedEdit {
        guard let match = failures.first(where: { $0.timestamp.hasPrefix(timestamp) }) else {
            preconditionFailure("no recorded failure at \(timestamp)")
        }
        return match
    }
}
