import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **Settings → Work Folder**: the user edits
/// the project description, sets a custom description prompt (for LLM-
/// assisted description generation), and selects an Xcode scheme.
///
/// Pinned behaviors:
/// 1. `updateWorkFolderDescription` persists → settings.json updated.
/// 2. `updateSelectedScheme` persists → settings.json updated.
/// 3. Description update leaves workfolder.json + teams.json alone
///    (three-file split invariant).
/// 4. Scheme update leaves description untouched.
/// 5. Empty description is allowed (user cleared the field).
/// 6. Nil scheme clears the selection (scheme picker → "None").
/// 7. Multi-line descriptions round-trip without mangling.
/// 8. Settings survive across restart.
/// 9. descriptionPrompt edits round-trip identically (custom templates).
@MainActor
final class EndToEndWorkFolderSettingsTests: NTMSOrchestratorTestBase {

    // MARK: - Scenario 1: Description update persists

    func testUpdateDescription_persistsToSettingsJSON() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateWorkFolderDescription("A really cool project")

        XCTAssertEqual(sut.workFolder?.settings.description,
                       "A really cool project",
                       "In-memory projection reflects the update")

        // Reopen and confirm disk persistence
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.workFolder?.settings.description,
                       "A really cool project")
    }

    // MARK: - Scenario 2: Scheme update persists

    func testUpdateSelectedScheme_persistsToSettingsJSON() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateSelectedScheme("MyApp")
        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "MyApp")

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "MyApp")
    }

    // MARK: - Scenario 3: Nil scheme clears selection

    func testUpdateSelectedScheme_nil_clearsSelection() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateSelectedScheme("OldScheme")
        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "OldScheme")

        await sut.updateSelectedScheme(nil)
        XCTAssertNil(sut.workFolder?.settings.selectedScheme,
                     "Passing nil must clear the selection")
    }

    // MARK: - Scenario 4: Empty description is valid

    func testUpdateDescription_emptyString_storedAsEmpty() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderDescription("initial")
        await sut.updateWorkFolderDescription("")

        XCTAssertEqual(sut.workFolder?.settings.description, "",
                       "Empty string is a valid user choice — must be stored, not reverted")
    }

    // MARK: - Scenario 5: Multi-line description round-trips

    func testUpdateDescription_multiLine_roundTripsCorrectly() async {
        let multiLine = """
            # My Project

            - First line
            - Second line with `code`
            - Unicode: café, 🚀, 日本語
            """

        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderDescription(multiLine)

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.workFolder?.settings.description, multiLine,
                       "Multi-line + Unicode description must round-trip identically")
    }

    // MARK: - Scenario 6: Three-file-split isolation

    /// The three-file-split invariant: editing the description must NOT
    /// rewrite `workfolder.json` or `teams.json`. We assert via content
    /// hash (mtime is CI-flaky).
    func testUpdateDescription_onlyTouchesSettingsJSON() async {
        await sut.openWorkFolder(tempDir)
        let paths = NTMSPaths(workFolderRoot: tempDir)

        let wfBefore = try? Data(contentsOf: paths.workFolderJSON)
        let teamsBefore = try? Data(contentsOf: paths.teamsJSON)
        let settingsBefore = try? Data(contentsOf: paths.settingsJSON)

        await sut.updateWorkFolderDescription("new description \(UUID().uuidString)")

        let wfAfter = try? Data(contentsOf: paths.workFolderJSON)
        let teamsAfter = try? Data(contentsOf: paths.teamsJSON)
        let settingsAfter = try? Data(contentsOf: paths.settingsJSON)

        XCTAssertEqual(wfBefore, wfAfter,
                       "workfolder.json must not change when only description edits")
        XCTAssertEqual(teamsBefore, teamsAfter,
                       "teams.json must not change when only description edits")
        XCTAssertNotEqual(settingsBefore, settingsAfter,
                          "settings.json must change")
    }

    func testUpdateSelectedScheme_onlyTouchesSettingsJSON() async {
        await sut.openWorkFolder(tempDir)
        let paths = NTMSPaths(workFolderRoot: tempDir)

        let wfBefore = try? Data(contentsOf: paths.workFolderJSON)
        let teamsBefore = try? Data(contentsOf: paths.teamsJSON)

        await sut.updateSelectedScheme("SomeScheme")

        let wfAfter = try? Data(contentsOf: paths.workFolderJSON)
        let teamsAfter = try? Data(contentsOf: paths.teamsJSON)

        XCTAssertEqual(wfBefore, wfAfter, "Scheme edit must not touch workfolder.json")
        XCTAssertEqual(teamsBefore, teamsAfter, "Scheme edit must not touch teams.json")
    }

    // MARK: - Scenario 7: descriptionPrompt (template) survives edit via mutateWorkFolder

    func testDescriptionPrompt_customTemplate_persistsAndRoundTrips() async {
        await sut.openWorkFolder(tempDir)

        let customPrompt = "Summarize the folder focusing on tests:\n\n{workFolderListing}"
        await sut.mutateWorkFolder { proj in
            proj.settings.descriptionPrompt = customPrompt
        }

        XCTAssertEqual(sut.workFolder?.settings.descriptionPrompt, customPrompt)

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.workFolder?.settings.descriptionPrompt, customPrompt,
                       "Custom descriptionPrompt must round-trip across restart")
    }

    // MARK: - Scenario 8: Independent edits compose cleanly

    func testUpdateDescriptionThenScheme_bothPersistIndependently() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateWorkFolderDescription("desc")
        await sut.updateSelectedScheme("sch")

        XCTAssertEqual(sut.workFolder?.settings.description, "desc")
        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "sch")
    }

    // MARK: - Scenario 9: Update preserves createdAt, bumps updatedAt

    /// Edits touch `WorkFolderState.updatedAt` via the standard mutation
    /// path — but `createdAt` is set once at bootstrap and never changes.
    func testWorkFolderCreatedAt_isStableAcrossEdits() async {
        await sut.openWorkFolder(tempDir)
        let createdAtBefore = sut.workFolder?.state.createdAt

        // Any edit that touches workfolder.json
        guard let teams = sut.workFolder?.teams, teams.count >= 2 else {
            return XCTFail("Need ≥ 2 teams")
        }
        await sut.mutateWorkFolder { proj in proj.setActiveTeam(teams[1].id) }

        let createdAtAfter = sut.workFolder?.state.createdAt
        XCTAssertEqual(createdAtBefore, createdAtAfter,
                       "createdAt must never be bumped — it's the folder's birth time")
    }
}
