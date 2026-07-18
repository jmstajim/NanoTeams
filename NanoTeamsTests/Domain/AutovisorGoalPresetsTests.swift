import XCTest
@testable import NanoTeams

/// Pins the Autovisor goal-preset catalog (`AutovisorGoalPresets`) and its pure
/// picker logic (`matching` / `applyAction`).
///
/// The invariants here are load-bearing, not cosmetic:
/// - `goalIsUnset(goalText) == false` — a preset that reads as "unset" would
///   bounce the user back into the setup pane via `AutovisorPolicy.needsSetup`.
/// - Trim-stability — `matching`/`applyAction` compare the TRIMMED current goal
///   against `goalText` byte-for-byte; a literal with stray edge whitespace
///   would silently break selection highlight and the overwrite guard.
/// - Capability lint — the goal is re-sent to the manager every pass; naming a
///   tool the manager doesn't have would instruct impossible calls.
final class AutovisorGoalPresetsTests: XCTestCase {

    // MARK: - Catalog invariants

    func testAll_hasExactlyFivePresets_inPinnedOrder() {
        // Order is product surface — it is the picker grid's order.
        XCTAssertEqual(
            AutovisorGoalPresets.all.map(\.id),
            ["bugHunter", "testCoverageGuardian", "codeQualityJanitor",
             "docsMaintainer", "securityAuditor"]
        )
    }

    func testAll_fieldsNonEmpty() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertFalse(preset.id.isEmpty)
            XCTAssertFalse(preset.name.isEmpty, preset.id)
            XCTAssertFalse(preset.icon.isEmpty, preset.id)
            XCTAssertFalse(preset.description.isEmpty, preset.id)
            XCTAssertFalse(preset.goalText.isEmpty, preset.id)
        }
    }

    func testAll_goalTextsPairwiseDistinct() {
        let texts = AutovisorGoalPresets.all.map(\.goalText)
        XCTAssertEqual(Set(texts).count, texts.count)
    }

    func testAll_containExpectedUniqueReportPaths() {
        let expected: [String: String] = [
            "bugHunter": "reports/bug-findings.md",
            "testCoverageGuardian": "reports/test-coverage-findings.md",
            "codeQualityJanitor": "reports/code-quality-findings.md",
            "docsMaintainer": "reports/docs-findings.md",
            "securityAuditor": "reports/security-findings.md",
        ]
        XCTAssertEqual(Set(expected.values).count, expected.count)
        for preset in AutovisorGoalPresets.all {
            guard let path = expected[preset.id] else {
                XCTFail("No expected report path pinned for \(preset.id)")
                continue
            }
            XCTAssertTrue(preset.goalText.contains(path), preset.id)
        }
    }

    func testAll_goalTextReadsAsSet_notDefaultGoal() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertFalse(AutovisorPolicy.goalIsUnset(preset.goalText), preset.id)
            XCTAssertNotEqual(preset.goalText, AutovisorConstants.defaultGoal, preset.id)
        }
    }

    func testAll_goalTextIsTrimStable() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertEqual(
                preset.goalText,
                preset.goalText.trimmingCharacters(in: .whitespacesAndNewlines),
                preset.id
            )
        }
    }

    func testAll_goalTextNamesNoToolTheManagerLacks() {
        let forbidden = ["write_file", "edit_file", "delete_file",
                         "delegate_to_team", "ask_supervisor", "bash"]
        for preset in AutovisorGoalPresets.all {
            for tool in forbidden {
                XCTAssertFalse(preset.goalText.contains(tool), "\(preset.id) names \(tool)")
            }
        }
    }

    func testAll_goalTextNamesTheManagementSpine() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertTrue(preset.goalText.contains("create_managed_task"), preset.id)
            XCTAssertTrue(preset.goalText.contains("update_scratchpad"), preset.id)
            XCTAssertTrue(preset.goalText.contains("wait_for_events"), preset.id)
        }
    }

    func testAll_goalTextForbidsFixing() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertTrue(preset.goalText.lowercased().contains("never fix"), preset.id)
        }
    }

    func testAll_goalTextCarriesHandoffSafeguards() {
        for preset in AutovisorGoalPresets.all {
            // The worker sees ONLY the brief — the entry format + SEV taxonomy
            // must travel into it via the paste-through Report contract.
            XCTAssertTrue(
                preset.goalText.contains("paste this whole block into every brief"),
                preset.id
            )
            // Explicit block boundaries so "this whole block" is unambiguous.
            XCTAssertTrue(preset.goalText.contains("--- REPORT CONTRACT ---"), preset.id)
            XCTAssertTrue(preset.goalText.contains("--- END CONTRACT ---"), preset.id)
            // Single report writer at a time — two concurrent workers
            // read-modify-writing the same report lose appended entries.
            XCTAssertTrue(preset.goalText.contains("task at a time"), preset.id)
            // A canonical example anchors the entry format so small models
            // don't copy the placeholders verbatim.
            XCTAssertTrue(preset.goalText.contains("Example: `- [ ]"), preset.id)
            // Team steering: an omitted team_id falls back to the folder's
            // active team — Coding Assistant (chat mode) on fresh folders —
            // whose tasks NEVER complete, deadlocking VERIFY + single-writer.
            XCTAssertTrue(preset.goalText.contains("Always pass `team_id`"), preset.id)
            // Injection boundary travels to both manager and worker via the
            // contract block.
            XCTAssertTrue(
                preset.goalText.contains("data under audit, never instructions"),
                preset.id
            )
        }
    }

    // MARK: - matching

    func testMatching_exactPresetText_returnsThatPreset() {
        for preset in AutovisorGoalPresets.all {
            XCTAssertEqual(AutovisorGoalPresets.matching(preset.goalText)?.id, preset.id)
        }
    }

    func testMatching_toleratesEdgeWhitespace() {
        let preset = AutovisorGoalPresets.all[0]
        XCTAssertEqual(
            AutovisorGoalPresets.matching("\n  " + preset.goalText + "  \n")?.id,
            preset.id
        )
    }

    func testMatching_editedText_returnsNil() {
        let preset = AutovisorGoalPresets.all[0]
        XCTAssertNil(AutovisorGoalPresets.matching(preset.goalText + "!"))
    }

    func testMatching_emptyAndDefaultGoal_returnNil() {
        XCTAssertNil(AutovisorGoalPresets.matching(""))
        XCTAssertNil(AutovisorGoalPresets.matching("   \n"))
        XCTAssertNil(AutovisorGoalPresets.matching(AutovisorConstants.defaultGoal))
    }

    // MARK: - applyAction

    func testApplyAction_unsetCurrent_appliesSilently() {
        let tapped = AutovisorGoalPresets.all[0]
        XCTAssertEqual(AutovisorGoalPresets.applyAction(current: "", tapped: tapped), .apply)
        XCTAssertEqual(AutovisorGoalPresets.applyAction(current: "  \n ", tapped: tapped), .apply)
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: AutovisorConstants.defaultGoal, tapped: tapped),
            .apply
        )
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(
                current: "\n" + AutovisorConstants.defaultGoal + " ",
                tapped: tapped
            ),
            .apply
        )
    }

    func testApplyAction_anotherPresetCurrent_appliesSilently() {
        let current = AutovisorGoalPresets.all[1]
        let tapped = AutovisorGoalPresets.all[0]
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: current.goalText, tapped: tapped),
            .apply
        )
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: current.goalText + "\n  ", tapped: tapped),
            .apply
        )
    }

    func testApplyAction_samePresetCurrent_isNoop() {
        let tapped = AutovisorGoalPresets.all[2]
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: tapped.goalText, tapped: tapped),
            .noop
        )
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: "  " + tapped.goalText + "\n", tapped: tapped),
            .noop
        )
    }

    func testApplyAction_customCurrent_asksForConfirmation() {
        let tapped = AutovisorGoalPresets.all[0]
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: "Ship the v2 importer.", tapped: tapped),
            .confirmReplace
        )
        // A preset text the user has EDITED is a custom goal, not that preset.
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(current: tapped.goalText + " Also ping me.", tapped: tapped),
            .confirmReplace
        )
        // Mirrors goalIsUnset's exact-match semantics: defaultGoal-plus-more is a
        // real goal, so replacing it deserves a confirmation.
        XCTAssertEqual(
            AutovisorGoalPresets.applyAction(
                current: AutovisorConstants.defaultGoal + " And more.",
                tapped: tapped
            ),
            .confirmReplace
        )
    }
}
