import XCTest
@testable import NanoTeams

/// The Autovisor's start page: the driver choice, what each driver means, and — for an
/// external agent — whether one can connect yet.
@MainActor
final class AutovisorSetupPresentationTests: XCTestCase {

    private func make(
        driver: AutovisorDriver,
        persistedGoal: String = "",
        externalAgentsEnabled: Bool = true,
        listenerState: HostedMCPListenerState = .listening(port: 47321),
        agentCount: Int = 1
    ) -> AutovisorSetupPresentation {
        AutovisorSetupPresentation.make(
            driver: driver,
            persistedGoal: persistedGoal,
            externalAgentsEnabled: externalAgentsEnabled,
            listenerState: listenerState,
            configuredPort: 47321,
            agentCount: agentCount)
    }

    // MARK: - Driver picker copy

    func testPickerOffersEveryDriver_withDistinctLabelsAndCaptions() {
        let labels = AutovisorDriver.allCases.map(AutovisorDriverPicker.label(for:))
        let captions = AutovisorDriver.allCases.map(AutovisorDriverPicker.caption(for:))
        XCTAssertEqual(Set(labels).count, AutovisorDriver.allCases.count)
        XCTAssertEqual(Set(captions).count, AutovisorDriver.allCases.count)
        XCTAssertEqual(AutovisorDriverPicker.label(for: .builtInModel), "Built-in Model")
        XCTAssertEqual(AutovisorDriverPicker.label(for: .externalAgent), "External Agent (MCP)")
    }

    /// The caption says what the choice changes: who supervises which tasks. An external agent
    /// supervises only the tasks it created (decision A3), and the caption must not promise more.
    func testCaptions_nameWhoSupervisesWhichTasks() {
        let builtIn = AutovisorDriverPicker.caption(for: .builtInModel)
        let external = AutovisorDriverPicker.caption(for: .externalAgent)
        XCTAssertTrue(builtIn.contains("every task"), builtIn)
        XCTAssertTrue(external.contains("tasks it creates"), external)
        XCTAssertTrue(external.contains("MCP"), external)
        for caption in [builtIn, external] {
            XCTAssertLessThanOrEqual(caption.count, 130, "one line on the 560-pt page: \(caption)")
        }
    }

    // MARK: - Presentation by driver

    func testBuiltIn_hasNoExternalAgentsLine_andTheManagerGoalCaption() {
        let p = make(driver: .builtInModel)
        XCTAssertNil(p.externalAgents)
        XCTAssertEqual(p.driverCaption, AutovisorDriverPicker.caption(for: .builtInModel))
        XCTAssertTrue(p.goalCaption.contains("system prompt"), p.goalCaption)
    }

    func testExternal_hasAnExternalAgentsLine_andAGoalCaptionAboutTheAgent() {
        let p = make(driver: .externalAgent)
        XCTAssertNotNil(p.externalAgents)
        XCTAssertEqual(p.driverCaption, AutovisorDriverPicker.caption(for: .externalAgent))
        XCTAssertFalse(p.goalCaption.contains("system prompt"),
                       "an external agent has no system prompt of ours: \(p.goalCaption)")
        XCTAssertTrue(p.goalCaption.contains("agent"), p.goalCaption)
    }

    /// The page gates nothing on the goal under `.externalAgent`
    /// (`AutovisorPolicy.requiresSetupBeforeEnabling`), and the agent arrives with instructions
    /// of its own — so the caption has to say the field is optional, and say what it is FOR when
    /// it isn't: a direction that outlives the agent's session, which nothing else here does.
    /// Under the built-in driver the same field is the manager's system prompt and mandatory, so
    /// the word must not appear there.
    func testGoalCaption_isOptionalOnlyUnderTheExternalDriver_andSaysWhyToSetItAnyway() {
        let external = make(driver: .externalAgent).goalCaption
        XCTAssertTrue(external.lowercased().contains("optional"), external)
        XCTAssertTrue(external.contains("outlives"), external)

        let builtIn = make(driver: .builtInModel).goalCaption
        XCTAssertFalse(builtIn.lowercased().contains("optional"),
                       "the manager runs ON the goal — it is not optional there: \(builtIn)")
    }

    func testGoalCaption_bothDriversSayWhereToEditIt() {
        for driver in AutovisorDriver.allCases {
            let caption = make(driver: driver).goalCaption
            XCTAssertTrue(caption.contains("Settings"), "\(driver): \(caption)")
        }
    }

    // MARK: - External Agents line

    func testExternalAgentsLine_offIsNotReady() {
        let line = AutovisorSetupPresentation.externalAgentsLine(
            enabled: false, listenerState: .stopped, configuredPort: 47321, agentCount: 2)
        XCTAssertFalse(line.isReady, "agents registered while the server is off cannot connect")
        XCTAssertTrue(line.text.contains("off"), line.text)
    }

    func testExternalAgentsLine_listeningWithNoAgent_isNotReady_andSaysWhatIsMissing() {
        let line = AutovisorSetupPresentation.externalAgentsLine(
            enabled: true, listenerState: .listening(port: 47321), configuredPort: 47321, agentCount: 0)
        XCTAssertFalse(line.isReady)
        XCTAssertTrue(line.text.contains("no agent"), line.text)
    }

    func testExternalAgentsLine_listeningWithAgents_isReady_andCountsThem() {
        let one = AutovisorSetupPresentation.externalAgentsLine(
            enabled: true, listenerState: .listening(port: 47321), configuredPort: 47321, agentCount: 1)
        XCTAssertTrue(one.isReady)
        XCTAssertTrue(one.text.contains("1 agent"), one.text)
        XCTAssertFalse(one.text.contains("1 agents"), one.text)

        let three = AutovisorSetupPresentation.externalAgentsLine(
            enabled: true, listenerState: .listening(port: 47321), configuredPort: 47321, agentCount: 3)
        XCTAssertTrue(three.isReady)
        XCTAssertTrue(three.text.contains("3 agents"), three.text)
    }

    func testExternalAgentsLine_serverNotUp_isNeverReady_whateverTheAgentCount() {
        let states: [HostedMCPListenerState] = [
            .starting, .stopped,
            .failed(.portInUse(47321)),
            .failed(.bindFailed("listener_start_failed")),
        ]
        for state in states {
            let line = AutovisorSetupPresentation.externalAgentsLine(
                enabled: true, listenerState: state, configuredPort: 47321, agentCount: 2)
            XCTAssertFalse(line.isReady, "\(state)")
            XCTAssertFalse(line.text.isEmpty, "\(state)")
        }
        let portInUse = AutovisorSetupPresentation.externalAgentsLine(
            enabled: true, listenerState: .failed(.portInUse(47321)), configuredPort: 47321, agentCount: 2)
        XCTAssertTrue(portInUse.text.contains("47321"), portInUse.text)
    }

    // MARK: - Goal draft seed

    func testInitialGoalDraft_blankPersistedGoal_isTheDefaultDirective() {
        XCTAssertEqual(AutovisorSetupPresentation.initialGoalDraft(persisted: ""), AutovisorConstants.defaultGoal)
        XCTAssertEqual(AutovisorSetupPresentation.initialGoalDraft(persisted: "  \n "), AutovisorConstants.defaultGoal)
    }

    func testInitialGoalDraft_realGoal_isKeptVerbatim() {
        XCTAssertEqual(AutovisorSetupPresentation.initialGoalDraft(persisted: "Keep tests green.\n"), "Keep tests green.\n")
    }
}
