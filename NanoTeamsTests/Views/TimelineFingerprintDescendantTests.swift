import XCTest
@testable import NanoTeams

/// Pins the rule that the parent activity feed reactively rebuilds when a
/// delegated child task's run gains/loses items. Without descendant data in
/// `TimelineFingerprint`, `runDataVersion` would only walk the active task's
/// run and the interleaved timeline would freeze on child progress.
@MainActor
final class TimelineFingerprintDescendantTests: XCTestCase {

    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    private func makeStep(id: String, role: Role, messages: [LLMMessage] = []) -> StepExecution {
        StepExecution(id: id, role: role, title: "x", status: .running, llmConversation: messages)
    }

    private func makeMessage(_ content: String, at t: Date) -> LLMMessage {
        LLMMessage(createdAt: t, role: .assistant, content: content)
    }

    private func makeDescendant(
        id: Int, run: Run, teamName: String = "Engineering"
    ) -> ActivityFeedBuilder.DescendantTask {
        let task = NTMSTask(
            id: id, title: "child", supervisorTask: "do",
            parentTaskID: 1, parentRoleID: "p", delegationDepth: 1
        )
        return ActivityFeedBuilder.DescendantTask(
            task: task, run: run, teamRoles: [],
            teamName: teamName, delegationDepth: 1, delegatedFromRoleName: "Coding Agent"
        )
    }

    func testFingerprint_changesWhen_descendantMessageAppended() {
        let viewModel = TeamActivityFeedViewModel()
        let parentSteps: [StepExecution] = []

        let childStep0 = makeStep(id: "swe", role: .softwareEngineer)
        let childRun0 = Run(id: 0, steps: [childStep0])
        let descendant0 = makeDescendant(id: 42, run: childRun0)
        let fp0 = viewModel.computeFingerprint(
            steps: parentSteps, run: nil, activeTaskID: 1, descendants: [descendant0]
        )

        let childStep1 = makeStep(id: "swe", role: .softwareEngineer, messages: [
            makeMessage("hello", at: date(100))
        ])
        let childRun1 = Run(id: 0, steps: [childStep1])
        let descendant1 = makeDescendant(id: 42, run: childRun1)
        let fp1 = viewModel.computeFingerprint(
            steps: parentSteps, run: nil, activeTaskID: 1, descendants: [descendant1]
        )

        XCTAssertNotEqual(fp0, fp1, "Adding a message inside a descendant must bump the fingerprint")
    }

    func testFingerprint_changesWhen_descendantAppears() {
        let viewModel = TeamActivityFeedViewModel()
        let fpEmpty = viewModel.computeFingerprint(
            steps: [], run: nil, activeTaskID: 1, descendants: []
        )

        let childStep = makeStep(id: "swe", role: .softwareEngineer)
        let descendant = makeDescendant(id: 42, run: Run(id: 0, steps: [childStep]))
        let fpWithChild = viewModel.computeFingerprint(
            steps: [], run: nil, activeTaskID: 1, descendants: [descendant]
        )

        XCTAssertNotEqual(fpEmpty, fpWithChild,
                          "Descendant appearing must bump the fingerprint (set hash differs)")
    }

    func testFingerprint_stableWhen_descendantUnchanged() {
        let viewModel = TeamActivityFeedViewModel()
        let childStep = makeStep(id: "swe", role: .softwareEngineer, messages: [
            makeMessage("a", at: date(100))
        ])
        let run = Run(id: 0, steps: [childStep])
        let descendant = makeDescendant(id: 42, run: run)

        let fp1 = viewModel.computeFingerprint(
            steps: [], run: nil, activeTaskID: 1, descendants: [descendant]
        )
        let fp2 = viewModel.computeFingerprint(
            steps: [], run: nil, activeTaskID: 1, descendants: [descendant]
        )
        XCTAssertEqual(fp1, fp2, "Identical inputs must produce equal fingerprints (no spurious rebuilds)")
    }
}
