import XCTest

@testable import NanoTeams

/// The M2 milestone of the 2026-08-07 `gemma-4-e4b` run died on a single absent key:
/// `roles[0].name`. `RoleConfig.init(from:)` hard-required it while the team-level `name`
/// had a synthesis fallback and `tools` / `produces_artifacts` / `requires_artifacts` all
/// defaulted to `[]` — and the system prompt never named it as a role field at all.
/// One `keyNotFound`, no retry, and every milestone behind it deadlocked.
final class GeneratedTeamNamelessRoleTests: XCTestCase {

    // MARK: - The real payload

    /// VERBATIM `team_config` from
    /// `MeditationApp/.nanoteams/internal/tasks/2/runs/0/network_log.json` record[1],
    /// trailing comma included. End-to-end pin: these exact bytes must now build a team.
    private static let realM2Payload = #"""
    {"team_config":{"description":"Implementar Mileston M2: Session Library. La app debe mostrar una vista de lista navegable que contenga meditaciones (título, duración y categoría).","name":"Implementación M2: Biblioteca de Sesiones","roles":[{"prompt":"Implementar Milestone M2 siguiendo estrictamente el Contrato de Construcción. El objetivo es añadir la vista de lista de meditaciones, sus modelos subyacentes y vincularla al flujo principal de la aplicación SwiftUI. Utiliza las estructuras existentes y solo introduce los cambios necesarios para cumplir con el alcance especificado. Recuerda que la compilación exitosa es obligatoria.","produces_artifacts":["Milestone M2 Implemented Codebase"]}],"supervisor_mode":"autonomous","acceptance_mode":"finalOnly",}}
    """#

    func testRealM2Payload_nowBuildsATeam() throws {
        let build = try TeamConfigParser.decodeTeamConfig(from: Self.realM2Payload)
        XCTAssertEqual(build.team.name, "Implementación M2: Biblioteca de Sesiones")
        let workers = build.team.roles.filter { !$0.isSupervisor }
        XCTAssertEqual(workers.count, 1)
        XCTAssertFalse(workers[0].name.isEmpty, "the nameless role must get a synthesized name")
    }

    /// The role shipped with zero tools while producing an artifact — it could submit a
    /// deliverable claiming M2 was built while unable to touch a file. That has to be
    /// SAID, not silently accepted.
    func testRealM2Payload_warnsAboutTheToollessProducingRole() throws {
        let build = try TeamConfigParser.decodeTeamConfig(from: Self.realM2Payload)
        XCTAssertTrue(
            build.warnings.contains { $0.contains("no tools") },
            "expected a tool-less producing-role warning, got: \(build.warnings)")
    }

    // MARK: - Name synthesis

    func testMissingRoleName_isSynthesizedFromPrompt() throws {
        let json = #"""
        {"name":"T","roles":[{"prompt":"Build the session list view. Then verify it compiles.",
        "produces_artifacts":["Notes"]}],"supervisor_requires":["Notes"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.roles[0].name, "Build the session list view")
    }

    /// Whitespace-only is the same as absent — otherwise a role named `" "` ships.
    func testBlankRoleName_isAlsoSynthesized() throws {
        let json = #"""
        {"name":"T","roles":[{"name":"   ","prompt":"Review the diff.","produces_artifacts":["Notes"]}],
        "supervisor_requires":["Notes"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.roles[0].name, "Review the diff")
    }

    func testDeclaredRoleName_wins() throws {
        let json = #"""
        {"name":"T","roles":[{"name":"Engineer","prompt":"Build it.","produces_artifacts":["Notes"]}],
        "supervisor_requires":["Notes"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.roles[0].name, "Engineer")
    }

    /// `prompt` stays hard-required — a role with no prompt has nothing to act on, so
    /// the tolerance is scoped to the field the prompt never documented.
    func testMissingPrompt_stillThrows() {
        let json = #"{"name":"T","roles":[{"name":"R"}],"supervisor_requires":[]}"#
        XCTAssertThrowsError(
            try JSONCoderFactory.makeWireDecoder()
                .decode(GeneratedTeamConfig.self, from: Data(json.utf8)))
    }

    /// Synthesized names can collide; role identity must not depend on them.
    func testTwoRolesWithSimilarPrompts_stillGetDistinctIDs() throws {
        let json = #"""
        {"name":"T","roles":[
          {"prompt":"Implement the feature.","produces_artifacts":["A"]},
          {"prompt":"Implement the feature.","produces_artifacts":["B"]}],
        "supervisor_requires":["A","B"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        let build = try GeneratedTeamBuilder.build(from: config)
        let workers = build.team.roles.filter { !$0.isSupervisor }
        XCTAssertEqual(workers.count, 2)
        XCTAssertEqual(Set(workers.map(\.id)).count, 2, "ids come from UUID, never from the name")
    }

    // MARK: - Tool-less producing role

    func testObserverWithNoTools_isNotWarnedAbout() throws {
        let json = #"""
        {"name":"T","roles":[
          {"name":"Worker","prompt":"Do it.","tools":["read_file"],"produces_artifacts":["A"]},
          {"name":"Watcher","prompt":"Observe.","tools":[]}],
        "supervisor_requires":["A"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        let build = try GeneratedTeamBuilder.build(from: config)
        XCTAssertFalse(
            build.warnings.contains { $0.contains("no tools") },
            "a role that produces nothing legitimately holds no tools")
    }

    // MARK: - The synthesized name must be able to stand as a label

    /// The severe case. `GeneratedTeamBuilder.isSupervisorName` is EXACT equality on the
    /// trimmed, lowercased name, so a prompt opening with the bare word turns the
    /// synthesized name into "Supervisor" — and the builder then filters that role out
    /// entirely, shipping a generated team with no worker roles at all.
    func testPromptOpeningWithSupervisor_doesNotSynthesizeADroppedRole() throws {
        let json = #"""
        {"name":"T","description":"d","roles":[{"prompt":"Supervisor. Coordinate the milestones and report.","produces_artifacts":["Plan"],"requires_artifacts":["Supervisor Task"],"tools":["read_file"]}],"artifacts":[{"name":"Plan","description":"p"}],"supervisor_requires":["Plan"]}
        """#
        let config = try JSONCoderFactory.makeWireDecoder()
            .decode(GeneratedTeamConfig.self, from: Data(json.utf8))
        XCTAssertNotEqual(
            config.roles.first?.name.lowercased(), "supervisor",
            "a synthesized name matching isSupervisorName drops the role")

        let build = try GeneratedTeamBuilder.build(from: config)
        XCTAssertEqual(
            build.team.nonSupervisorRoles.count, 1,
            "the generated team must still have a worker role")
    }

    /// A prompt opening with an enumerated step used to be named "1".
    func testPromptOpeningWithANumberedStep_doesNotSynthesizeADigit() {
        XCTAssertNotEqual(
            GeneratedTeamConfig.synthesizedRoleName(
                fromPrompt: "1. Build the session list view. 2. Verify it compiles."),
            "1")
    }

    /// The floor must not swallow a short prompt that IS one sentence — there is nothing
    /// else to name the role after, so the sentence stands.
    func testShortSinglesentencePrompt_stillUsesTheSentence() {
        XCTAssertEqual(
            GeneratedTeamConfig.synthesizedRoleName(fromPrompt: "Review the code."),
            "Review the code")
    }

    /// A first sentence long enough to be a label is trusted, floor or no floor.
    func testLongFirstSentence_isStillPreferredOverTheHead() {
        XCTAssertEqual(
            GeneratedTeamConfig.synthesizedRoleName(
                fromPrompt: "Write the evaluation engine. Then document it."),
            "Write the evaluation engine")
    }
}
