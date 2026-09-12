import XCTest

@testable import NanoTeams

/// What `RuntimePromptRegistry` must cover for `runtimePromptVersion` to mean what the
/// provenance line says it means: every text the executor hands the model, and every
/// direction the policy appends after one.
///
/// The gap this pins was found by review on 2026-09-11: the registry rendered
/// `ToolErrorNotePolicy.direction` over `ToolErrorCode.allCases` only, and the executor's
/// own codes (`tool_not_authorized`, `unknown_tool`, `precondition_failed`, `plan_required`,
/// `identical_write_loop`) are not `ToolErrorCode` cases — so the wave that rewrote the
/// `tool_not_authorized` remedy and four unavailability envelopes shipped under an
/// unchanged fingerprint (DEBTS D-B11, closed by these rows).
@MainActor
final class RuntimePromptRegistryTests: XCTestCase {

    private var rowsByName: [String: RuntimePromptRegistry.Entry] = [:]

    override func setUp() async throws {
        try await super.setUp()
        rowsByName = Dictionary(
            RuntimePromptRegistry.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    override func tearDown() async throws {
        rowsByName = [:]
        try await super.tearDown()
    }

    private var repoRoot: URL {
        // NanoTeamsTests/Services/LLM/<this file> → four levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every `case "…":` literal the policy switches on has a row. The row names are
    /// compared lowercased because the `ToolErrorCode` loop names its rows by the
    /// uppercase raw value while the policy lowercases before matching.
    ///
    /// RED: delete the executor-code loop from the registry → `unknown_tool`,
    /// `tool_not_authorized`, `precondition_failed`, `plan_required` and
    /// `identical_write_loop` have no row.
    func testEveryDirectionArm_hasARegistryRow() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("NanoTeams/Services/LLM/ToolErrorNotePolicy.swift"),
            encoding: .utf8)
        let arms = try NSRegularExpression(pattern: #"case "([a-zA-Z_]+)":"#)
        let literals = Set(arms.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]).lowercased() } })
        XCTAssertGreaterThanOrEqual(literals.count, 10, "anti-vacuum: the policy has ten arms; scan found \(literals)")

        let rowStems = Set(rowsByName.keys
            .filter { $0.hasPrefix("ToolErrorNotePolicy.direction/") }
            .map { $0.components(separatedBy: "/")[1].lowercased() })
        let missing = literals.subtracting(rowStems).sorted()
        XCTAssertEqual(missing, [], "direction arms with no registry row — their text is unversioned")
    }

    /// Every `ToolUnavailabilityReason` renders its envelope under its own row, and the
    /// rendered bytes carry the reason's code — so rewording any envelope moves the
    /// fingerprint, and the code the direction is chosen by is versioned with it.
    func testEveryUnavailabilityReason_hasAnEnvelopeRow() {
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases {
            let name = "LLMExecutionService.makeUnavailableToolResult/\(reason)"
            guard let row = rowsByName[name] else { return XCTFail("no row for \(name)") }
            let rendered = row.render()
            XCTAssertTrue(rendered.contains(reason.errorCode), "\(name): \(rendered)")
            XCTAssertFalse(rendered.isEmpty)
        }
    }

    /// The remedy the wave rewrote is the one this exists for: its direction row renders
    /// the current text, not `(none)`.
    func testTheNotInRoleConfigRemedy_isVersioned() {
        guard let row = rowsByName["ToolErrorNotePolicy.direction/tool_not_authorized"] else {
            return XCTFail("no direction row for tool_not_authorized")
        }
        let rendered = row.render()
        XCTAssertTrue(rendered.contains("Do not retry"), rendered)
        XCTAssertFalse(rendered.contains("proceed without this step"),
                       "the permission MeditationApp task 48 run 1 acted on must stay gone: \(rendered)")
    }
}
