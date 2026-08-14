import XCTest
@testable import NanoTeams

/// Verifies `GeneratedTeamBuilder.stripFileShapedArtifactNames` invoked from `build`
/// turns file-shaped artifact names (`index.html`, `script.js`, etc.) into a single
/// generic `"\(roleName) Summary"` deliverable, rewires downstream dependencies,
/// and surfaces a warning.
///
/// Regression: `tasks/8/subtasks/9` — Team Generator emitted
/// `produces_artifacts: ["index.html", "styles.css", "script.js"]` for the Frontend
/// Developer role, the role created those as artifacts via `create_artifact` instead
/// of writing actual files via `write_file`, and no `calculator/` directory was ever
/// produced. Per CORE_PRINCIPLES the program covers this stable model weakness
/// structurally instead of trying harder prompt wording.
final class GeneratedTeamFileShapedArtifactCleanupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func makeRole(
        name: String,
        produces: [String] = [],
        requires: [String] = ["Supervisor Task"],
        tools: [String] = ["read_file", "write_file", "edit_file", "list_files", "search"]
    ) -> GeneratedTeamConfig.RoleConfig {
        GeneratedTeamConfig.RoleConfig(
            name: name, prompt: "Do work.",
            producesArtifacts: produces,
            requiresArtifacts: requires,
            tools: tools
        )
    }

    private func makeConfig(
        roles: [GeneratedTeamConfig.RoleConfig],
        artifacts: [GeneratedTeamConfig.ArtifactConfig],
        supervisorRequires: [String]
    ) -> GeneratedTeamConfig {
        GeneratedTeamConfig(
            name: "Calculator Web", description: "Build a calculator",
            roles: roles, artifacts: artifacts, supervisorRequires: supervisorRequires
        )
    }

    private func artifact(_ name: String) -> GeneratedTeamConfig.ArtifactConfig {
        GeneratedTeamConfig.ArtifactConfig(name: name, description: "", icon: nil)
    }

    // MARK: - Reproduces tasks/8/subtasks/9

    func testFrontendDevWithThreeFileShapedArtifacts_replacedWithSingleSummary() {
        let dev = makeRole(name: "Frontend Developer",
                           produces: ["index.html", "styles.css", "script.js"])
        let qc = makeRole(name: "Quality Controller",
                          produces: ["Review Report"],
                          requires: ["index.html", "styles.css", "script.js"],
                          tools: ["read_file", "list_files", "search"])
        let config = makeConfig(
            roles: [dev, qc],
            artifacts: [
                artifact("index.html"), artifact("styles.css"), artifact("script.js"),
                artifact("Review Report"),
            ],
            supervisorRequires: ["index.html", "styles.css", "script.js", "Review Report"]
        )

        let result = GeneratedTeamBuilder.build(from: config)

        // Frontend Developer's produces_artifacts collapsed to a single Summary.
        let devRole = result.team.roles.first { $0.name == "Frontend Developer" }
        XCTAssertEqual(devRole?.dependencies.producesArtifacts, ["Frontend Developer Summary"])

        // Quality Controller's requires_artifacts rewritten to point at the new Summary
        // (deduped — three stripped names → one fallback → one entry).
        let qcRole = result.team.roles.first { $0.name == "Quality Controller" }
        XCTAssertEqual(qcRole?.dependencies.requiredArtifacts, ["Frontend Developer Summary"])
        // Quality Controller's own produces_artifacts unchanged (Review Report is a valid name).
        XCTAssertEqual(qcRole?.dependencies.producesArtifacts, ["Review Report"])

        // Team-level artifacts: only Supervisor Task + Review Report + Frontend Developer Summary.
        // Original file-shaped artifacts dropped, fallback added.
        let names = Set(result.team.artifacts.map(\.name))
        XCTAssertTrue(names.contains("Frontend Developer Summary"))
        XCTAssertTrue(names.contains("Review Report"))
        XCTAssertFalse(names.contains("index.html"))
        XCTAssertFalse(names.contains("styles.css"))
        XCTAssertFalse(names.contains("script.js"))

        // Supervisor's requires_artifacts: stripped names rewritten + deduped to fallback.
        let supervisor = result.team.roles.first { $0.isSupervisor }
        let supReq = supervisor?.dependencies.requiredArtifacts ?? []
        XCTAssertTrue(supReq.contains("Frontend Developer Summary"))
        XCTAssertTrue(supReq.contains("Review Report"))
        XCTAssertFalse(supReq.contains("index.html"))

        // Warning surfaced — operator sees what was rewritten.
        XCTAssertTrue(
            result.warnings.contains { $0.contains("stripped 3 file-shaped artifact name(s)") },
            "Expected stripping warning, got: \(result.warnings)"
        )
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Frontend Developer Summary") },
            "Warning should name the synthesized fallback, got: \(result.warnings)"
        )
    }

    // MARK: - Mixed valid + invalid: drop invalid, no fallback (role keeps deliverables)

    func testRoleWithMixedArtifacts_invalidDroppedAndNoFallbackInjected() {
        let role = makeRole(name: "Engineer",
                            produces: ["Engineering Notes", "build.log", "Implementation Plan"])
        let config = makeConfig(
            roles: [role],
            artifacts: [
                artifact("Engineering Notes"), artifact("build.log"), artifact("Implementation Plan"),
            ],
            supervisorRequires: ["Engineering Notes", "build.log", "Implementation Plan"]
        )

        let result = GeneratedTeamBuilder.build(from: config)
        let engineer = result.team.roles.first { $0.name == "Engineer" }

        // Only the file-shaped name dropped; valid names kept; NO fallback injected
        // because role still has deliverables.
        XCTAssertEqual(engineer?.dependencies.producesArtifacts, ["Engineering Notes", "Implementation Plan"])
        XCTAssertFalse(result.team.artifacts.contains { $0.name == "Engineer Summary" })
        XCTAssertFalse(result.team.artifacts.contains { $0.name == "build.log" })

        // Supervisor's requires lost build.log, kept the other two.
        let supReq = result.team.roles.first { $0.isSupervisor }?.dependencies.requiredArtifacts ?? []
        XCTAssertTrue(supReq.contains("Engineering Notes"))
        XCTAssertTrue(supReq.contains("Implementation Plan"))
        XCTAssertFalse(supReq.contains("build.log"))
    }

    // MARK: - All-valid config passes through unchanged (no warnings)

    func testAllValidArtifacts_configUnchangedAndNoWarning() {
        let role = makeRole(name: "PM", produces: ["Product Requirements"])
        let config = makeConfig(
            roles: [role],
            artifacts: [artifact("Product Requirements")],
            supervisorRequires: ["Product Requirements"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let pm = result.team.roles.first { $0.name == "PM" }
        XCTAssertEqual(pm?.dependencies.producesArtifacts, ["Product Requirements"])
        XCTAssertFalse(
            result.warnings.contains { $0.contains("file-shaped") },
            "All-valid config should produce no stripping warnings"
        )
    }

    // MARK: - Allowed extensions (.md / .pdf / .rtf / .docx) are NOT stripped

    func testReportMarkdownAndPDF_notStripped() {
        let role = makeRole(name: "Researcher", produces: ["report.md", "summary.pdf"])
        let config = makeConfig(
            roles: [role],
            artifacts: [artifact("report.md"), artifact("summary.pdf")],
            supervisorRequires: ["report.md", "summary.pdf"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let r = result.team.roles.first { $0.name == "Researcher" }
        XCTAssertEqual(r?.dependencies.producesArtifacts, ["report.md", "summary.pdf"])
        XCTAssertFalse(result.warnings.contains { $0.contains("file-shaped") })
    }

    // MARK: - Edge: self-loop guard

    /// A role that both produces AND requires a file-shaped name (LLM emitted the
    /// same name in both lists). After rewrite, the requires reference must NOT
    /// point back at the role's own (kept or fallback) artifact — that creates a
    /// self-edge that makes the role never become `.ready`.
    func testRoleProducesAndRequiresSameFileShape_selfLoopFiltered() {
        // Engineer: kept = ["Engineering Notes"], stripped = ["index.html"].
        // Engineer requires ["index.html"] too — would self-loop after rewrite to "Engineering Notes".
        let engineer = makeRole(
            name: "Engineer",
            produces: ["Engineering Notes", "index.html"],
            requires: ["Supervisor Task", "index.html"]
        )
        let config = makeConfig(
            roles: [engineer],
            artifacts: [artifact("Engineering Notes"), artifact("index.html")],
            supervisorRequires: ["Engineering Notes"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let r = result.team.roles.first { $0.name == "Engineer" }
        // Self-loop must be filtered: requires_artifacts must NOT contain "Engineering Notes"
        // (which would be the rewrite target of "index.html" and is also produced by Engineer).
        XCTAssertEqual(
            r?.dependencies.requiredArtifacts, ["Supervisor Task"],
            "Self-loop on rewritten artifact must be filtered out, got: \(String(describing: r?.dependencies.requiredArtifacts))"
        )
    }

    // MARK: - Edge: downstream role's requires fully drained → warning surfaces

    /// When a downstream role's `requires_artifacts` would be empty after stripping
    /// + self-loop filtering, a warning must surface so the operator notices the
    /// role will run on team start with no upstream gating. Pre-fix this dropped
    /// silently and the role advanced out of order.
    func testDownstreamRequiresAllStripped_surfacesEmptyRequiresWarning() {
        // Worker requires only "index.html" (produced by Frontend Dev — fully stripped, fallback added).
        // Then a Reviewer that requires only "script.js" (also fully stripped) — its requires becomes
        // ["Frontend Developer Summary"] via rewriteList. To force the all-stripped-AND-no-redirect
        // case, give Reviewer a self-loop produces.
        let dev = makeRole(
            name: "Frontend Developer",
            produces: ["index.html"],   // fully stripped → fallback "Frontend Developer Summary"
            requires: ["Supervisor Task"]
        )
        let reviewer = makeRole(
            name: "Reviewer",
            produces: ["Frontend Developer Summary"],     // collides with Dev's fallback
            requires: ["Frontend Developer Summary"]       // self-loop after rewrite
        )
        let config = makeConfig(
            roles: [dev, reviewer],
            artifacts: [artifact("index.html"), artifact("Frontend Developer Summary")],
            supervisorRequires: ["Frontend Developer Summary"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        // Reviewer ends up requiring nothing real (self-loop filtered, no other inputs).
        // Warning must surface so operator sees the role will run unbounded on start.
        XCTAssertTrue(
            result.warnings.contains { $0.contains("Reviewer") && $0.contains("requires_artifacts") },
            "An emptied requires list must surface a warning. Got: \(result.warnings)"
        )
    }

    // MARK: - Edge: supervisor_requires references fully-stripped name with NO fallback

    /// When a producing role kept other artifacts (no fallback synthesized), its
    /// stripped names redirect to the role's first kept artifact (preserving the
    /// dependency edge). Verifies that supervisor_requires gets correctly redirected
    /// in this redirect-case path.
    func testSupervisorRequiresStrippedName_redirectedToProducerKeptArtifact() {
        let dev = makeRole(
            name: "Engineer",
            produces: ["Engineering Notes", "build.log"]   // build.log stripped, kept first
        )
        let config = makeConfig(
            roles: [dev],
            artifacts: [artifact("Engineering Notes"), artifact("build.log")],
            supervisorRequires: ["build.log"]   // ← must redirect, not silently drop
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let supervisor = result.team.roles.first { $0.isSupervisor }
        // Pre-fix would drop "build.log" → supervisor.requires == [] → supervisor never gates on Engineer.
        // Post-fix redirects to Engineer's first kept artifact, preserving the dependency edge.
        XCTAssertEqual(
            supervisor?.dependencies.requiredArtifacts, ["Engineering Notes"],
            "supervisor_requires referencing a stripped name must redirect to the producer's first kept artifact. Got: \(String(describing: supervisor?.dependencies.requiredArtifacts))"
        )
    }

    // MARK: - Edge: two roles produce same file-shape (each gets own Summary)

    /// Two different roles each producing `"index.html"` (and only that) get
    /// distinct synthetic Summary artifacts. The `seenArtifactNames` dedup
    /// must NOT collapse them into one shared Summary that crosses role boundaries.
    func testTwoRolesProduceSameFileShape_eachGetsOwnSummary() {
        let r1 = makeRole(name: "Frontend Developer", produces: ["index.html"])
        let r2 = makeRole(name: "Backend Developer", produces: ["index.html"])
        let config = makeConfig(
            roles: [r1, r2],
            artifacts: [artifact("index.html")],
            supervisorRequires: ["index.html"]
        )
        let result = GeneratedTeamBuilder.build(from: config)
        let r1Out = result.team.roles.first { $0.name == "Frontend Developer" }
        let r2Out = result.team.roles.first { $0.name == "Backend Developer" }
        XCTAssertEqual(r1Out?.dependencies.producesArtifacts, ["Frontend Developer Summary"])
        XCTAssertEqual(r2Out?.dependencies.producesArtifacts, ["Backend Developer Summary"])
        let names = Set(result.team.artifacts.map(\.name))
        XCTAssertTrue(names.contains("Frontend Developer Summary"))
        XCTAssertTrue(names.contains("Backend Developer Summary"))
    }

    // MARK: - Totality: a stripped name never loses its downstream edge

    /// The two tests above are the two EXAMPLES; this is the PROPERTY behind them, and
    /// it is what licences the absence of a drop path.
    ///
    /// `stripFileShapedArtifactNames` picks a redirect target as `fallback ?? kept.first`.
    /// `fallback` is non-nil exactly when `kept` is empty — it is computed from that same
    /// condition, and neither list is mutated in between — so `kept.first` covers the
    /// complement and the pair is TOTAL for any role carrying a stripped name. Wave 12
    /// deleted the third arm and the `droppedNames` set it fed: both were unreachable, and
    /// the set was the costlier half, because it stayed permanently empty while two
    /// consumers still read it and advertised a "reference gets dropped" outcome this
    /// function cannot produce.
    ///
    /// Stated as a property over the whole 2×N space rather than as a third example: the
    /// deletion is safe only if EVERY shape redirects, and two examples cannot say that.
    /// A downstream role losing its edge is silent and expensive — it becomes `.ready`
    /// immediately and runs out of dependency order, which is the regression the redirect
    /// was introduced for in the first place.
    ///
    /// RED: restore the drop path (`else { droppedNames.insert(s) }` plus `rewriteList`'s
    /// `droppedNames.contains(name) → nil` arm) and make it fire by picking the target as
    /// `fallback` alone → the mixed-produces rows lose their requires entry and the
    /// non-empty assertion fails for each of them.
    func testEveryStrippedName_redirectsSomewhere_soNoDownstreamEdgeIsEverDropped() {
        // The full shape space of a producing role that has at least one stripped name:
        // it either kept nothing (→ Summary fallback) or kept something (→ first kept).
        let shapes: [(label: String, produces: [String], expected: String)] = [
            ("all stripped", ["a.html"], "Producer Summary"),
            ("all stripped, several", ["a.html", "b.css", "c.js"], "Producer Summary"),
            ("mixed, kept first", ["Design Spec", "a.html"], "Design Spec"),
            ("mixed, stripped first", ["a.html", "Design Spec"], "Design Spec"),
            ("mixed, several kept", ["Design Spec", "Test Plan", "a.html"], "Design Spec"),
        ]

        for shape in shapes {
            let producer = makeRole(name: "Producer", produces: shape.produces)
            // One consumer per stripped name, so a drop shows up as an empty requires
            // list rather than being masked by a sibling entry that survived.
            let strippedNames = shape.produces.filter { !ArtifactConstants.isValidArtifactName($0) }
            XCTAssertFalse(strippedNames.isEmpty, "fixture must strip something: \(shape.label)")

            let consumers = strippedNames.enumerated().map { index, name in
                makeRole(name: "Consumer\(index)", produces: ["Report \(index)"], requires: [name])
            }
            let config = makeConfig(
                roles: [producer] + consumers,
                artifacts: shape.produces.map { artifact($0) },
                supervisorRequires: [strippedNames[0]]
            )

            let result = GeneratedTeamBuilder.build(from: config)

            for index in consumers.indices {
                let consumer = result.team.roles.first { $0.name == "Consumer\(index)" }
                XCTAssertEqual(
                    consumer?.dependencies.requiredArtifacts, [shape.expected],
                    "\(shape.label): Consumer\(index) must still depend on the producer")
            }
            let supervisor = result.team.roles.first { $0.isSupervisor }
            XCTAssertEqual(
                supervisor?.dependencies.requiredArtifacts, [shape.expected],
                "\(shape.label): supervisor_requires must redirect too")
        }
    }

    /// The redirect target is also what the WARNING names, and the two are now read from
    /// one expression rather than re-derived in a second if/else — so this pins that they
    /// cannot disagree. Without it, the wave-12 edit could have kept the dependency edge
    /// correct while telling the user the name was "dropped".
    ///
    /// RED: change the warning's action back to a separate `if let fb … else … else
    /// "dropped"` chain and invert its first two arms → the mixed-produces assertion
    /// reads "replaced with 'Design Spec'" and fails.
    func testWarningNamesTheSameTargetTheEdgeWasRedirectedTo() {
        let allStripped = GeneratedTeamBuilder.build(from: makeConfig(
            roles: [makeRole(name: "Producer", produces: ["a.html"])],
            artifacts: [artifact("a.html")],
            supervisorRequires: ["a.html"]))
        XCTAssertTrue(
            allStripped.warnings.contains { $0.contains("replaced with 'Producer Summary'") },
            "warnings: \(allStripped.warnings)")

        let mixed = GeneratedTeamBuilder.build(from: makeConfig(
            roles: [makeRole(name: "Producer", produces: ["Design Spec", "a.html"])],
            artifacts: [artifact("Design Spec"), artifact("a.html")],
            supervisorRequires: ["a.html"]))
        XCTAssertTrue(
            mixed.warnings.contains { $0.contains("redirected to 'Design Spec'") },
            "warnings: \(mixed.warnings)")
        XCTAssertFalse(
            mixed.warnings.contains { $0.contains("dropped") },
            "there is no drop outcome any more; warnings: \(mixed.warnings)")
    }
}
