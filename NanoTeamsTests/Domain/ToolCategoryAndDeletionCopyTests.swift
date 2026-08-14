import XCTest

@testable import NanoTeams

/// Three small Domain surfaces that were at 0% and are pure enough to pin
/// exactly rather than approximately.
///
/// The centrepiece is `definitionDisplayCategories`. Its doc comment states an
/// invariant — "every tool in `ToolHandlerRegistry.allTypes` should map to
/// exactly one section here" — that nothing enforced. It is the tool-DEFINITIONS
/// editor's complete categorisation, so a tool missing from it is invisible in
/// that editor, and a tool listed twice renders twice. Both are silent, and both
/// happen by simply forgetting a line when adding a tool. The house already has
/// a count pin (`DefaultToolSchemasTests`) that a new tool trips; this makes the
/// same addition trip on categorisation too.
final class ToolCategoryAndDeletionCopyTests: XCTestCase {

    // MARK: - definitionDisplayCategories

    func testDefinitionCategories_coverEveryRegisteredTool() {
        let registered = Set(ToolHandlerRegistry.allSchemas.map(\.name))
        let categorised = Set(ToolConstants.definitionDisplayCategories.flatMap(\.tools))

        let uncategorised = registered.subtracting(categorised)
        XCTAssertTrue(
            uncategorised.isEmpty,
            """
            These registered tools appear in no section of \
            `ToolConstants.definitionDisplayCategories`, so the tool-definitions \
            editor will not list them at all:
            \(uncategorised.sorted().joined(separator: ", "))
            """)
    }

    func testDefinitionCategories_listNoToolThatIsNotRegistered() {
        let registered = Set(ToolHandlerRegistry.allSchemas.map(\.name))
        let categorised = Set(ToolConstants.definitionDisplayCategories.flatMap(\.tools))

        let phantom = categorised.subtracting(registered)
        XCTAssertTrue(
            phantom.isEmpty,
            """
            These names are categorised but have no handler — a renamed or deleted \
            tool left behind in the category table:
            \(phantom.sorted().joined(separator: ", "))
            """)
    }

    func testDefinitionCategories_listEachToolExactlyOnce() {
        var seen: [String: [String]] = [:]
        for category in ToolConstants.definitionDisplayCategories {
            for tool in category.tools {
                seen[tool, default: []].append(category.id)
            }
        }
        let duplicated = seen.filter { $0.value.count > 1 }
        XCTAssertTrue(
            duplicated.isEmpty,
            "a tool in two sections renders twice in the editor: "
                + duplicated.map { "\($0.key) in \($0.value.joined(separator: "+"))" }
                    .sorted().joined(separator: ", "))
    }

    func testDefinitionCategories_haveUniqueIdentifiersAndNoEmptySection() {
        let ids = ToolConstants.definitionDisplayCategories.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "duplicate section ids break SwiftUI ForEach identity")
        for category in ToolConstants.definitionDisplayCategories {
            XCTAssertFalse(category.tools.isEmpty, "empty section: \(category.id)")
            XCTAssertFalse(category.name.isEmpty, "unnamed section: \(category.id)")
            XCTAssertFalse(category.icon.isEmpty, "iconless section: \(category.id)")
        }
    }

    /// The definitions table is a SUPERSET of the role-editor picker: the picker
    /// deliberately omits auto-injected tools, the definitions editor must not.
    func testDefinitionCategories_supersetOfTheRoleEditorPicker() {
        let picker = Set(ToolConstants.displayCategories.flatMap(\.tools))
        let definitions = Set(ToolConstants.definitionDisplayCategories.flatMap(\.tools))
        XCTAssertTrue(picker.isSubset(of: definitions),
                      "missing from the definitions editor: "
                          + picker.subtracting(definitions).sorted().joined(separator: ", "))
        XCTAssertTrue(definitions.contains(ToolNames.concludeMeeting),
                      "conclude_meeting is auto-injected, so it is absent from the picker "
                          + "and must be present here")
    }

    // MARK: - DownloadedModelDeletion

    func testDeletion_availabilityMatchesTheCase() {
        XCTAssertTrue(DownloadedModelDeletion.permanent.isAvailable)
        XCTAssertTrue(DownloadedModelDeletion.movesToTrash.isAvailable)
        XCTAssertFalse(DownloadedModelDeletion.unavailable(reason: "remote host").isAvailable)
    }

    /// The copy is the only thing telling the user whether 20 GB actually comes
    /// back. Trash-vs-permanent must never read the same.
    func testDeletion_confirmationCopyDistinguishesTrashFromPermanent() throws {
        let permanent = try XCTUnwrap(DownloadedModelDeletion.permanent.confirmationDetail)
        let trash = try XCTUnwrap(DownloadedModelDeletion.movesToTrash.confirmationDetail)

        XCTAssertNotEqual(permanent, trash)
        XCTAssertTrue(permanent.lowercased().contains("permanent"))
        XCTAssertTrue(trash.lowercased().contains("trash"))
        XCTAssertTrue(
            trash.lowercased().contains("empty the trash"),
            "the space is not reclaimed until the Trash is emptied — the copy must say so")
    }

    func testDeletion_unavailable_hasNoConfirmationCopy() {
        // There is no dialog to append to when the button is disabled.
        XCTAssertNil(DownloadedModelDeletion.unavailable(reason: "no delete API").confirmationDetail)
    }

    func testDeletion_equatable_discriminatesOnTheReason() {
        XCTAssertEqual(DownloadedModelDeletion.permanent, .permanent)
        XCTAssertNotEqual(DownloadedModelDeletion.permanent, .movesToTrash)
        XCTAssertEqual(
            DownloadedModelDeletion.unavailable(reason: "a"), .unavailable(reason: "a"))
        XCTAssertNotEqual(
            DownloadedModelDeletion.unavailable(reason: "a"), .unavailable(reason: "b"))
    }

    // MARK: - TeamDecision identity

    /// `==` is id-only by design (the decision's text is edited in place), so a
    /// structural comparison would break `ForEach` identity and re-animate rows.
    func testTeamDecision_equalityIsIdentityOnly() {
        let id = UUID()
        let a = TeamDecision(id: id, summary: "Ship it", proposedBy: .softwareEngineer)
        var b = TeamDecision(id: id, summary: "COMPLETELY DIFFERENT", proposedBy: .productManager)
        b.nextSteps = ["something else"]

        XCTAssertEqual(a, b, "same id must compare equal even when every other field differs")
        XCTAssertEqual(a.hashValue, b.hashValue)

        let other = TeamDecision(id: UUID(), summary: "Ship it", proposedBy: .softwareEngineer)
        XCTAssertNotEqual(a, other, "different ids must differ even when every other field matches")
    }

    /// Legacy `run.meetings` payloads predate four of the fields; every one of
    /// them must decode to a usable default rather than throwing.
    ///
    /// The payload is built by ENCODING a real decision and stripping keys, not
    /// by hand-writing JSON — `Role` has a custom `encode(to:)` (it carries a
    /// `.custom(id:)` case), so a hand-written `proposedBy` would be pinning my
    /// guess at its wire form rather than the real one.
    func testTeamDecision_decodesLegacyPayloadMissingOptionalFields() throws {
        let full = TeamDecision(
            summary: "Adopt the plan",
            rationale: "because",
            proposedBy: .softwareEngineer,
            agreedBy: [.productManager],
            nextSteps: ["ship"])
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(full)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for legacyAbsent in ["createdAt", "rationale", "agreedBy", "nextSteps"] {
            XCTAssertNotNil(object[legacyAbsent], "\(legacyAbsent) must exist before we strip it")
            object[legacyAbsent] = nil
        }

        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(TeamDecision.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.id, full.id)
        XCTAssertEqual(decoded.summary, "Adopt the plan")
        XCTAssertEqual(decoded.proposedBy, full.proposedBy)
        XCTAssertNil(decoded.rationale)
        XCTAssertEqual(decoded.agreedBy, [])
        XCTAssertEqual(decoded.nextSteps, [])
        XCTAssertGreaterThan(
            decoded.createdAt.timeIntervalSince1970, 0,
            "a missing timestamp falls back to the monotonic clock, not to 1970")
    }
}
