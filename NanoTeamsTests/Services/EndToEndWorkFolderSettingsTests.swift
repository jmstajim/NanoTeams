import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **Settings → Work Folder**: the user edits
/// the work-folder context, sets a custom context prompt (for LLM-assisted
/// context generation), and selects an Xcode scheme.
///
/// Pinned behaviors:
/// 1. `updateWorkFolderContext` persists → settings.json updated.
/// 2. `updateSelectedScheme` persists → settings.json updated.
/// 3. Context update leaves workfolder.json + teams.json alone
///    (three-file split invariant).
/// 4. Scheme update leaves context untouched.
/// 5. Empty context is allowed (user cleared the field).
/// 6. Nil scheme clears the selection (scheme picker → "None").
/// 7. Multi-line context round-trips without mangling.
/// 8. Settings survive across restart.
/// 9. contextPrompt edits round-trip identically (custom templates).
@MainActor
final class EndToEndWorkFolderSettingsTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Scenario 1: Description update persists

    func testUpdateDescription_persistsToSettingsJSON() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateWorkFolderContext("A really cool project")

        XCTAssertEqual(sut.workFolder?.settings.context,
                       "A really cool project",
                       "In-memory projection reflects the update")

        // Reopen and confirm disk persistence
        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.workFolder?.settings.context,
                       "A really cool project")
    }

    // MARK: - Scenario 2: Scheme update persists

    func testUpdateSelectedScheme_persistsToSettingsJSON() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateSelectedScheme("MyApp")
        XCTAssertEqual(sut.workFolder?.settings.selectedScheme, "MyApp")

        sut = TestOrchestrator.make()
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

    // MARK: - Scenario 4: Empty context is valid

    func testUpdateDescription_emptyString_storedAsEmpty() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderContext("initial")
        await sut.updateWorkFolderContext("")

        XCTAssertEqual(sut.workFolder?.settings.context, "",
                       "Empty string is a valid user choice — must be stored, not reverted")
    }

    // MARK: - Scenario 5: Multi-line context round-trips

    func testUpdateDescription_multiLine_roundTripsCorrectly() async {
        let multiLine = """
        # My Project
        
        - First line
        - Second line with `code`
        - Unicode: café, 🚀, 日本語
        """

        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderContext(multiLine)

        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.workFolder?.settings.context, multiLine,
                       "Multi-line + Unicode context must round-trip identically")
    }

    // MARK: - Scenario 6: Three-file-split isolation

    /// The three-file-split invariant: editing the context must NOT
    /// rewrite `workfolder.json` or `teams.json`. We assert via content
    /// hash (mtime is CI-flaky).
    func testUpdateContext_onlyTouchesSettingsJSON() async {
        await sut.openWorkFolder(tempDir)
        let paths = NTMSPaths(workFolderRoot: tempDir)

        let wfBefore = try? Data(contentsOf: paths.workFolderJSON)
        let teamsBefore = try? Data(contentsOf: paths.teamsJSON)
        let settingsBefore = try? Data(contentsOf: paths.settingsJSON)

        await sut.updateWorkFolderContext("new context \(UUID().uuidString)")

        let wfAfter = try? Data(contentsOf: paths.workFolderJSON)
        let teamsAfter = try? Data(contentsOf: paths.teamsJSON)
        let settingsAfter = try? Data(contentsOf: paths.settingsJSON)

        XCTAssertEqual(wfBefore, wfAfter,
                       "workfolder.json must not change when only context edits")
        XCTAssertEqual(teamsBefore, teamsAfter,
                       "teams.json must not change when only context edits")
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

    // MARK: - Scenario 7: contextPrompt (template) survives edit via mutateWorkFolder

    func testContextPrompt_customTemplate_persistsAndRoundTrips() async {
        await sut.openWorkFolder(tempDir)

        let customPrompt = "Summarize the folder focusing on tests:\n\n{workFolderListing}"
        await sut.mutateWorkFolder { proj in
            proj.settings.contextPrompt = customPrompt
        }

        XCTAssertEqual(sut.workFolder?.settings.contextPrompt, customPrompt)

        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.workFolder?.settings.contextPrompt, customPrompt,
                       "Custom contextPrompt must round-trip across restart")
    }

    // MARK: - Scenario 8: Independent edits compose cleanly

    func testUpdateContextThenScheme_bothPersistIndependently() async {
        await sut.openWorkFolder(tempDir)

        await sut.updateWorkFolderContext("ctx")
        await sut.updateSelectedScheme("sch")

        XCTAssertEqual(sut.workFolder?.settings.context, "ctx")
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
