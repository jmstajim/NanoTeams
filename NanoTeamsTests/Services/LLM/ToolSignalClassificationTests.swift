import XCTest

@testable import NanoTeams

/// The three predicates that decide where a `ToolSignal` is handled.
///
/// Each is a hand-maintained list, and each has already failed once by omission — the doc on
/// `isCollaborationDeferredSignal` records it: `wait_for_events` was added to `ToolSignal`
/// without being added to the list, so it routed to the regular path, `parkForEventsRequested`
/// was never set, and the Autovisor looped forever instead of going idle. Nothing errored; the
/// manager just never stopped.
///
/// Example-based tests cannot catch that class, because the failure is a case that ISN'T there.
/// So the centrepiece here is a source scan over `ToolSignal`'s declaration: every case must be
/// classified deliberately, either by appearing in a predicate or by being named in the
/// `deliberatelyRegular` roster below with a reason.
final class ToolSignalClassificationTests: XCTestCase {

    /// Cases that correctly take the plain `processRegularToolResult` path. Adding a case here is
    /// the deliberate act the scan demands — it should be accompanied by a reason.
    private static let deliberatelyRegular: Set<String> = [
        "supervisorQuestion",   // handled by the step-stop machinery, not a result finalizer
        "artifact",             // persisted by processCreateArtifactResult on the regular path
        "teamCreation",         // team installation is owned by runTeamGeneration
        "exploratorySearch",    // rewritten by its own finalizer (see shouldRecordInTrackerPreFinalize)
        "visionAnalysis",       // ditto
        "computerUse",          // ditto
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLM
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // NanoTeamsTests
            .deletingLastPathComponent()   // repo root
    }

    /// The file the scan reads. Doubling as the path-resolution marker makes the scan
    /// non-vacuous by construction: if `repoRoot` is wrong, this throws rather than silently
    /// classifying an empty set. It is also a build source, so it exists in every checkout
    /// (CLAUDE.md 2026-07-27 — a marker outside the build is absent from the public mirror).
    private var toolRegistrySource: String {
        get throws {
            try String(contentsOf: repoRoot.appendingPathComponent(
                "NanoTeams/Services/Tools/ToolRegistry.swift"), encoding: .utf8)
        }
    }

    /// Case names declared on `ToolSignal`, read from source. Comment lines are stripped first:
    /// the enum's doc comments discuss cases in prose (`/// Companion to \`delegate_to_team\``)
    /// and a naive scan would pick those up as declarations.
    private func declaredCases() throws -> [String] {
        let source = try toolRegistrySource
        guard let start = source.range(of: "enum ToolSignal: Hashable {") else {
            throw XCTSkip("ToolSignal's declaration moved — update this scan")
        }
        let body = source[start.upperBound...]
        var names: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "}" { break }
            guard !line.hasPrefix("//"), line.hasPrefix("case ") else { continue }
            let afterCase = line.dropFirst("case ".count)
            let name = afterCase.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.append(String(name)) }
        }
        return names
    }

    // MARK: - The exhaustiveness pin

    func testEveryToolSignalCase_isClassifiedDeliberately() throws {
        let cases = try declaredCases()
        XCTAssertGreaterThanOrEqual(cases.count, 20,
                                    "expected ~24 ToolSignal cases; far fewer means the scan broke")

        let source = try toolRegistrySource
        _ = source   // keep the read above meaningful even if the assertion set changes

        let collaboration = try classifiedCaseNames(inPredicate: "isCollaborationDeferredSignal")
        let autovisor = try classifiedCaseNames(inPredicate: "isAutovisorSignal")

        let unclassified = cases.filter {
            !collaboration.contains($0) && !autovisor.contains($0)
                && !Self.deliberatelyRegular.contains($0)
        }

        XCTAssertTrue(
            unclassified.isEmpty,
            """
            These ToolSignal cases are classified by nothing:
            \(unclassified.sorted().joined(separator: ", "))

            A collaboration / delegation / manager signal that isn't in \
            `isCollaborationDeferredSignal` silently takes the regular path and its deferred \
            handler never runs. If the case genuinely belongs on the regular path, add it to \
            `deliberatelyRegular` above with a reason.
            """)
    }

    /// Reads the case names out of one predicate's `switch`, so the pin measures the production
    /// list rather than a copy of it that could drift.
    private func classifiedCaseNames(inPredicate name: String) throws -> Set<String> {
        let path = repoRoot.appendingPathComponent(
            "NanoTeams/Services/LLM/LLMExecutionService+ToolResultProcessing.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        guard let start = source.range(of: "static func \(name)"),
              let caseStart = source.range(of: "case .", range: start.upperBound..<source.endIndex),
              let returnTrue = source.range(of: "return true", range: caseStart.upperBound..<source.endIndex)
        else {
            throw XCTSkip("\(name)'s shape changed — update this scan")
        }
        let block = source[caseStart.lowerBound..<returnTrue.lowerBound]
        var names = Set<String>()
        for token in block.split(whereSeparator: { $0 == "." }) {
            let name = token.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        names.remove("case")
        return names
    }

    // MARK: - The predicates themselves

    /// Placeholder-emitting signals must NOT be recorded before their finalizer runs — the
    /// tracker feeds the loop detector's next-iteration snapshot, so recording the interim
    /// `{"status":"pending"}` teaches it that two genuinely different actions were identical.
    func testAsyncFinalizedSignals_areNotRecordedPreFinalize() {
        let deferred: [ToolSignal] = [
            .visionAnalysis(imagePath: "/tmp/a.png", prompt: "p"),
            .computerUse(.capture(target: "screen", windowTitle: nil)),
        ]

        for signal in deferred {
            XCTAssertFalse(
                LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: signal),
                "\(signal) rewrites its envelope asynchronously")
        }
    }

    func testPlainResultAndSynchronousSignals_areRecordedPreFinalize() {
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: nil))
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(
            signal: .artifact(name: "Spec", content: "x", format: nil)))
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(
            signal: .supervisorQuestion("why?")))
    }

    func testCollaborationSignals_routeToTheDeferredPath() {
        let deferred: [ToolSignal] = [
            .teammateConsultation(id: "r", question: "q", context: nil),
            .teamMeeting(topic: "t", participants: [], context: nil),
            .changeRequest(targetRole: "r", changes: "c", reasoning: "why"),
            .delegateToTeam(teamID: "t", taskBrief: "b"),
            .cancelDelegation(childTaskID: 2, reason: nil),
            .resumeDelegation(childTaskID: 2),
            .forwardToTeam(childTaskID: 2, message: "m"),
            .waitForEvents,
        ]

        for signal in deferred {
            XCTAssertTrue(LLMExecutionService.isCollaborationDeferredSignal(signal), "\(signal)")
        }
    }

    func testRegularSignalsAndNil_doNotRouteToTheDeferredPath() {
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(nil))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(.supervisorQuestion("q")))
        XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(
            .artifact(name: "a", content: "c", format: nil)))
    }

    /// Every Autovisor signal is also a collaboration-deferred one — the manager tools have no
    /// UI surface of their own, so they reach the deferred path first and are then singled out
    /// for card reflection. A signal in `isAutovisorSignal` but not the other list would have its
    /// card reflected by code that never runs.
    func testEveryAutovisorSignal_isAlsoCollaborationDeferred() throws {
        let autovisor = try classifiedCaseNames(inPredicate: "isAutovisorSignal")
        let collaboration = try classifiedCaseNames(inPredicate: "isCollaborationDeferredSignal")

        XCTAssertFalse(autovisor.isEmpty, "the scan found no manager signals — it is vacuous")
        XCTAssertTrue(autovisor.isSubset(of: collaboration),
                      "not deferred: \(autovisor.subtracting(collaboration).sorted())")
    }

    func testManagerSignals_areRecognisedAsAutovisor() {
        let manager: [ToolSignal] = [
            .listTasks,
            .taskStatus(taskID: 1),
            .createManagedTask(title: "t", brief: "b", teamID: nil),
            .answerTaskQuestion(taskID: 1, answer: "a"),
            .messageTask(taskID: 1, text: "t", roleID: nil),
            .scheduleTask(taskID: 1, intervalMinutes: 60),
            .setWorkFolderContext(content: "c"),
            .waitForEvents,
        ]

        for signal in manager {
            XCTAssertTrue(LLMExecutionService.isAutovisorSignal(signal), "\(signal)")
        }
    }

    /// Delegation is NOT management: it has its own graph + feed surfaces, so reflecting its
    /// envelope onto the card would duplicate what those already show.
    func testDelegationAndCollaborationSignals_areNotAutovisorSignals() {
        XCTAssertFalse(LLMExecutionService.isAutovisorSignal(nil))
        XCTAssertFalse(LLMExecutionService.isAutovisorSignal(
            .delegateToTeam(teamID: "t", taskBrief: "b")))
        XCTAssertFalse(LLMExecutionService.isAutovisorSignal(
            .teamMeeting(topic: "t", participants: [], context: nil)))
    }
}
