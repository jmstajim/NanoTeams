import XCTest
@testable import NanoTeams

/// Pins each shared `SystemTemplates.*Fragment` to the set of role prompts that
/// reference it. Without this, a future role-prompt rewrite can silently
/// re-inline the body — losing the propagation guarantee the fragment was
/// extracted to provide.
///
/// The mapping is intentional, not exhaustive — fragments may be added to new
/// roles without updating this test, but if an existing consumer drops a
/// fragment, the test fires and forces an explicit decision (re-inline ⇒ split
/// the fragment, or keep using the fragment).
final class SharedRoleFragmentsUsageTests: XCTestCase {

    private func assertContainsFragment(
        _ roleID: String,
        _ fragment: String,
        _ fragmentName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let prompt = SystemTemplates.rolePrompts[roleID] else {
            XCTFail("Role prompt '\(roleID)' missing from SystemTemplates.rolePrompts", file: file, line: line)
            return
        }
        XCTAssertTrue(
            prompt.contains(fragment),
            "[\(roleID)] must reference shared fragment `\(fragmentName)` — re-inlining the body breaks propagation",
            file: file, line: line
        )
    }

    // `toolCallRequiredFragment` was removed 2026-05 — the rule lives in
    // chat-mode templates' `## Output format` section. No production caller
    // references the fragment anymore.

    func testCodingAttachmentsFragment_consumers() {
        for roleID in ["codingAssistant", "codingAgent"] {
            assertContainsFragment(roleID, SystemTemplates.codingAttachmentsFragment, "codingAttachmentsFragment")
        }
    }

    func testAssistantAttachmentsFragment_consumers() {
        assertContainsFragment("assistant", SystemTemplates.assistantAttachmentsFragment, "assistantAttachmentsFragment")
    }

    func testGroundingRepoFragment_consumers() {
        for roleID in ["codingAssistant", "codingAgent"] {
            assertContainsFragment(roleID, SystemTemplates.groundingRepoFragment, "groundingRepoFragment")
        }
    }

    func testGroundingFolderFragment_consumers() {
        assertContainsFragment("assistant", SystemTemplates.groundingFolderFragment, "groundingFolderFragment")
    }

    func testNumberedChoiceFragment_consumers() {
        for roleID in ["assistant", "codingAssistant", "codingAgent"] {
            assertContainsFragment(roleID, SystemTemplates.numberedChoiceFragment, "numberedChoiceFragment")
        }
    }

    func testCodingResponseStyleFragment_consumers() {
        for roleID in ["codingAssistant", "codingAgent"] {
            assertContainsFragment(roleID, SystemTemplates.codingResponseStyleFragment, "codingResponseStyleFragment")
        }
    }

    func testEngineeringStandardsFragment_consumers() {
        assertContainsFragment("codingAssistant", SystemTemplates.engineeringStandardsFragment, "engineeringStandardsFragment")
    }

    /// Defence-in-depth: a fragment that's not referenced by ANY role is dead
    /// code — surfaces as a silent maintenance hazard. Adding a fragment to
    /// CommonFragments without wiring it to at least one role fails this test.
    func testEveryFragment_referencedByAtLeastOneRole() {
        let fragments: [(name: String, body: String)] = [
            ("codingAttachmentsFragment", SystemTemplates.codingAttachmentsFragment),
            ("assistantAttachmentsFragment", SystemTemplates.assistantAttachmentsFragment),
            ("groundingRepoFragment", SystemTemplates.groundingRepoFragment),
            ("groundingFolderFragment", SystemTemplates.groundingFolderFragment),
            ("numberedChoiceFragment", SystemTemplates.numberedChoiceFragment),
            ("codingResponseStyleFragment", SystemTemplates.codingResponseStyleFragment),
            ("engineeringStandardsFragment", SystemTemplates.engineeringStandardsFragment),
        ]
        for (name, body) in fragments {
            let referenced = SystemTemplates.rolePrompts.values.contains { $0.contains(body) }
            XCTAssertTrue(referenced, "Fragment `\(name)` is not referenced by any role prompt — dead code")
        }
    }
}
