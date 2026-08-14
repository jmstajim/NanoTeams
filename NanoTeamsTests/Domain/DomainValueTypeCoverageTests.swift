import XCTest

@testable import NanoTeams

/// Coverage wave 1 — the pure-value tier.
///
/// Everything here is a decoder default, a derived getter, or a synthesized-conformance body:
/// code with no dependencies, no I/O and no OS, which nothing happened to ask a question of.
/// It is first because it is the cheapest, and because a wrong `??` default is invisible until
/// a legacy file loads — the failure mode with the longest fuse in this codebase.
///
/// Two things here are deliberately NOT closed, and the reasons belong next to the tests that
/// could have closed them:
///
/// - `SupervisorMode.displayName` / `.description` fall back through
///   `Self.metadata[self]?.x ?? default`. The dictionary is exhaustive over the enum, so the `??`
///   arm is unreachable — as it is in `RoleExecutionStatus` (7 lines), `BashPolicy` (5) and
///   `ComputerUsePolicy` (5). `Domain/` is never excludable, so those ~17 lines are permanent
///   residue. The invariant worth pinning is not the fallback but the EXHAUSTIVENESS, because a
///   new case added without a metadata entry silently yields `""` — see
///   `testMetadataDictionariesCoverEveryCase`.
final class DomainValueTypeCoverageTests: XCTestCase {

    // MARK: - Decoder defaults

    /// Every `decodeIfPresent(...) ?? default` in `TeamSettings.init(from:)`, which is 12 of that
    /// file's 14 uncovered lines and all of them sub-line autoclosures — invisible to a
    /// whole-line reading of the coverage report.
    ///
    /// The shape under test is a real one: `teams.json` files written before a field existed
    /// decode through exactly this path on every work-folder open.
    ///
    /// RED: change any `?? default` in `TeamSettings.init(from:)` → the matching assertion fails.
    func testTeamSettings_decodesFromAnEmptyObject_andTakesEveryDefault() throws {
        let settings = try JSONDecoder().decode(TeamSettings.self, from: Data("{}".utf8))

        XCTAssertTrue(settings.hierarchy.reportsTo.isEmpty, "hierarchy defaults to empty")
        XCTAssertNil(settings.meetingCoordinatorRoleID, "nil coordinator is Auto mode, not a missing value")
        XCTAssertTrue(settings.invitableRoles.isEmpty)
        XCTAssertFalse(settings.supervisorCanBeInvited)
        XCTAssertEqual(settings.limits, TeamLimits.default)
        XCTAssertEqual(settings.defaultAcceptanceMode, .afterEachRole,
                       "the fail-VISIBLE default: one extra Accept click beats silently accepting "
                       + "on the Supervisor's behalf")
        XCTAssertTrue(settings.acceptanceCheckpoints.isEmpty)
        XCTAssertEqual(settings.supervisorMode, .manual,
                       "a team with no recorded mode must block on ask_supervisor, never auto-answer")
    }

    /// The other half of the same contract: a present value must win over the default, or the
    /// test above would pass against a decoder that ignored its input entirely.
    func testTeamSettings_presentValuesBeatTheDefaults() throws {
        let json = """
        {"supervisorMode":"autonomous","defaultAcceptanceMode":"finalOnly",
         "supervisorCanBeInvited":true,"invitableRoles":["a"],"acceptanceCheckpoints":["b"]}
        """
        let settings = try JSONDecoder().decode(TeamSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.supervisorMode, .autonomous)
        XCTAssertEqual(settings.defaultAcceptanceMode, .finalOnly)
        XCTAssertTrue(settings.supervisorCanBeInvited)
        XCTAssertEqual(settings.invitableRoles, ["a"])
        XCTAssertEqual(settings.acceptanceCheckpoints, ["b"])
    }

    // MARK: - The exhaustiveness invariant behind the unreachable `??` arms

    /// The `Self.metadata[self]?.x ?? default` idiom is the codebase's deliberate OCP alternative
    /// to a `switch`, and its fallback is unreachable while the dictionary is exhaustive. What is
    /// NOT guaranteed is that it stays exhaustive: add an enum case, forget the metadata entry,
    /// and `displayName` silently becomes `rawValue` or `""` — a UI label that reads as a bug
    /// report rather than throwing one.
    ///
    /// So this pins the property the fallback exists to paper over.
    ///
    /// RED: add a case to `SupervisorMode` without a metadata entry → this fails naming it.
    func testMetadataDictionariesCoverEveryCase() {
        for mode in SupervisorMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) has no display name")
            XCTAssertNotEqual(mode.displayName, mode.rawValue,
                              "\(mode) fell through to the rawValue fallback — it has no metadata entry")
            XCTAssertFalse(mode.description.isEmpty,
                           "\(mode) fell through to the empty-string fallback — no metadata entry")
        }

        for status in RoleExecutionStatus.allCases {
            XCTAssertFalse(status.displayName.isEmpty,
                           "\(status) fell through the metadata fallback to an empty display name")
            XCTAssertFalse(status.icon.isEmpty, "\(status) has no icon")
        }
    }

    // MARK: - Synthesized-conformance bodies nothing exercised

    /// `Team.==` is an identity shortcut (`id` + `updatedAt`), not structural equality — CLAUDE.md
    /// #42 — and the whole diff-driven-write path in `mutateWorkFolder` depends on knowing that.
    /// Neither the `hash(into:)` body nor `==` had ever run.
    ///
    /// RED: fold any other property into `Team.==` → `testTeamEquality_ignoresStructuralChanges`
    /// fails, which is the regression #42 exists to prevent.
    func testTeamHashableUsesIdentityNotStructure() {
        var a = TeamTemplateFactory.startup()
        var b = a

        XCTAssertEqual(a, b, "same id and updatedAt is the whole equality contract")
        XCTAssertEqual(Set([a, b]).count, 1, "hash(into:) must agree with == or Set breaks")

        // Structural change with NO updatedAt bump: still equal, deliberately.
        b.roles.removeAll()
        XCTAssertEqual(a, b,
                       "Team.== compares id + updatedAt only (CLAUDE.md #42). Code needing a real "
                       + "structural diff must compare encoded JSON, which is what mutateWorkFolder does.")

        a.updatedAt = a.updatedAt.addingTimeInterval(1)
        XCTAssertNotEqual(a, b, "a bumped updatedAt is what makes two revisions distinct")
        XCTAssertEqual(Set([a, b]).count, 2)
    }

    /// `Role.id` (the `Identifiable` witness) forwards to the same private `storageKey` that
    /// `encode(to:)` writes, and nothing had ever read it.
    ///
    /// Asserted against the ENCODED value rather than by widening `storageKey` to internal: it
    /// keeps the test out of production visibility, and it pins the stronger property — that the
    /// `ForEach` id and the persisted key are the same string. A witness that diverged from
    /// storage is the duplicate/unstable-id class of bug (CLAUDE.md #22).
    ///
    /// RED: change `var id` to return `baseID` → the custom-role case fails, since `baseID` drops
    /// the `custom:` prefix that storage keeps.
    func testRoleIdentifiableWitnessMatchesThePersistedKey() throws {
        let encoder = JSONEncoder()
        func encodedKey(_ role: Role) throws -> String {
            let data = try encoder.encode(role)
            return try JSONDecoder().decode(String.self, from: data)
        }

        for role in Role.builtInCases + [.custom(id: "my_role")] {
            XCTAssertFalse(role.id.isEmpty, "\(role) has an empty Identifiable id")
            XCTAssertEqual(role.id, try encodedKey(role),
                           "\(role): the Identifiable id and the persisted key disagree")
        }

        // The witness must separate two distinct roles, or a ForEach over them collapses.
        XCTAssertEqual(Set(Role.builtInCases.map(\.id)).count, Role.builtInCases.count,
                       "two built-in roles share an Identifiable id — a ForEach over them would "
                       + "hit the duplicate-ID case")
    }

    /// A stored `Role` raw value that is neither a known built-in nor `custom:`-prefixed. Real
    /// files hit this: a role removed from the enum leaves its bare id behind in `teams.json`.
    ///
    /// RED: drop the final `else { self = .custom(id: raw) }` arm → decoding throws instead of
    /// degrading, and every task file naming a retired role becomes unreadable.
    func testRoleDecoding_bareUnknownRawValue_degradesToCustom() throws {
        let decoder = JSONDecoder()

        let bare = try decoder.decode(Role.self, from: Data("\"retired_role\"".utf8))
        XCTAssertEqual(bare, .custom(id: "retired_role"),
                       "an unknown bare id must degrade to .custom, not throw — otherwise a role "
                       + "removed from the enum makes old task files undecodable")

        let prefixed = try decoder.decode(Role.self, from: Data("\"custom:my_role\"".utf8))
        XCTAssertEqual(prefixed, .custom(id: "my_role"), "the custom: prefix is stripped")

        let engineerKey = Role.softwareEngineer.id
        let builtIn = try decoder.decode(Role.self, from: Data("\"\(engineerKey)\"".utf8))
        XCTAssertEqual(builtIn, .softwareEngineer, "a known built-in key must resolve to its case")
    }

    /// Round-trip, because the decode arms above are only half of a compat contract.
    func testRoleCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for role in Role.builtInCases + [.custom(id: "x")] {
            let restored = try decoder.decode(Role.self, from: try encoder.encode(role))
            XCTAssertEqual(restored, role, "\(role) did not survive a round trip")
        }
    }
}
