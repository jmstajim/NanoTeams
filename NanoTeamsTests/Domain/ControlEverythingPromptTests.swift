import XCTest
@testable import NanoTeams

/// Pins the "control whole prompt" contract added in the 2026-05 placeholder
/// promotion of `{globalContext}` + `{toolCalling}`:
///
/// 1. Empty template ⇒ empty system_prompt (no auto-appended globalContext,
///    no auto-appended Harmony tool block).
/// 2. Template containing `{globalContext}` ⇒ globalContext value resolves
///    inline at the chip's position; the trailing auto-append is suppressed.
/// 3. Template containing `{toolCalling}` ⇒ Harmony block resolves
///    inline at the chip's position; `NativeLMStudioClient.buildRequest`'s
///    auto-append is suppressed.
/// 4. Template MISSING `{globalContext}` ⇒ backwards-compat auto-append
///    (custom user templates created before the chip existed keep working).
/// 5. Built-in templates ship with both chips at the tail — `## Final reminder`
///    is no longer the literal last line of any built-in step / meeting
///    template body, but the chip placement preserves Liu2024 §0.3 (the
///    runtime can position FR anywhere by editing the template).
final class ControlEverythingPromptTests: XCTestCase {

    // MARK: - Empty template ⇒ empty system_prompt

    func testEmptyTemplate_resolveSystemPrompt_returnsEmpty() {
        let result = TemplateResolver.resolveSystemPrompt(
            "",
            placeholders: ["roleGuidance": "ignored", "globalContext": "## Global guidance\n\nRULE"],
            globalContext: "RULE_X"
        )
        XCTAssertEqual(result, "",
                       "An empty template must NOT trigger globalContext auto-append")
    }

    func testWhitespaceOnlyTemplate_resolveSystemPrompt_returnsEmpty() {
        let result = TemplateResolver.resolveSystemPrompt(
            "   \n\n  \t  \n",
            placeholders: [:],
            globalContext: "RULE_X"
        )
        XCTAssertEqual(result, "",
                       "Whitespace-only template must NOT trigger globalContext auto-append")
    }

    // MARK: - Explicit `{globalContext}` placeholder ⇒ inline resolution

    func testTemplateWithGlobalContextChip_resolvesInlineAndSkipsAutoAppend() {
        // Author wraps the chip with `## Global guidance\n` themselves — chip
        // resolves to the bare value. This is the 2026-05 chip-format contract:
        // headers live in the template, chips are pure values.
        let template = """
            ## Role
            Test role.

            ## Global guidance
            {globalContext}

            ## Final reminder
            Do the thing.
            """
        let placeholders = [
            "globalContext": PromptBuilder.formatGlobalContext("RULE_X"),
        ]
        let result = TemplateResolver.resolveSystemPrompt(
            template, placeholders: placeholders, globalContext: "RULE_X"
        )
        // The chip resolves inline (between author-written ## Global guidance and ## Final reminder).
        XCTAssertTrue(result.contains("## Global guidance\nRULE_X\n\n## Final reminder"),
                      "globalContext chip must resolve inline; got:\n\(result)")
        // The auto-append at the end must NOT fire — only one `## Global guidance`
        // section should exist (the one the author placed in the template).
        let count = result.components(separatedBy: "## Global guidance").count - 1
        XCTAssertEqual(count, 1, "globalContext must appear exactly once (no auto-append duplication)")
    }

    func testTemplateWithGlobalContextChip_emptyValue_stripsOrphanHeader() {
        // When the chip resolves to empty, `stripOrphanHeaders` removes the
        // surrounding `## Global guidance` header too — keeping the prompt
        // clean and the editor template intact (author doesn't need to remove
        // the header to hide the section).
        let template = """
            ## Role
            Test role.

            ## Global guidance
            {globalContext}

            ## Final reminder
            Do the thing.
            """
        let placeholders = [
            "globalContext": PromptBuilder.formatGlobalContext(""),
        ]
        let result = TemplateResolver.resolveSystemPrompt(
            template, placeholders: placeholders, globalContext: ""
        )
        XCTAssertFalse(result.contains("## Global guidance"),
                       "Empty chip must trigger orphan-header strip; got:\n\(result)")
        XCTAssertTrue(result.contains("## Role"))
        XCTAssertTrue(result.contains("## Final reminder"))
    }

    func testTemplateWithoutGlobalContextChip_autoAppendsForBackwardsCompat() {
        let template = """
            ## Role
            Custom role.

            ## Final reminder
            Do the thing.
            """
        let result = TemplateResolver.resolveSystemPrompt(
            template, placeholders: [:], globalContext: "RULE_X"
        )
        XCTAssertTrue(result.hasSuffix("## Global guidance\n\nRULE_X"),
                      "Template without the chip must fall back to auto-append; got:\n\(result)")
    }

    // MARK: - Empty globalContext value collapses the chip

    // MARK: - formatGlobalContext shape (bare body — no header wrap)

    func testFormatGlobalContext_nonEmpty_returnsBareTrimmedValue() {
        XCTAssertEqual(
            PromptBuilder.formatGlobalContext("Hello"),
            "Hello",
            "Chip body must be bare — the `## Global guidance` header lives in the template"
        )
    }

    func testFormatGlobalContext_trimsSurroundingWhitespace() {
        XCTAssertEqual(
            PromptBuilder.formatGlobalContext("  Hello  \n"),
            "Hello"
        )
    }

    func testFormatGlobalContext_emptyOrWhitespace_returnsEmpty() {
        XCTAssertEqual(PromptBuilder.formatGlobalContext(""), "")
        XCTAssertEqual(PromptBuilder.formatGlobalContext("   \n\t  "), "")
    }

    // MARK: - Built-in templates carry both chips at the tail

    func testEveryBuiltInStepTemplate_containsGlobalContextAndToolCallingChips() {
        let stepTemplates: [(String, String)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("assistantTemplate", SystemTemplates.assistantTemplate),
            ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
        ]
        for (name, template) in stepTemplates {
            XCTAssertTrue(template.contains("{globalContext}"),
                          "[\(name)] must include `{globalContext}` chip")
            XCTAssertTrue(template.contains("{toolCalling}"),
                          "[\(name)] must include `{toolCalling}` chip")
        }
    }

    func testEveryBuiltInConsultationTemplate_containsGlobalContextChip() {
        // Consultations call streamChat with `tools: []` — no Harmony block needed,
        // only globalContext.
        let consultationTemplates: [(String, String)] = [
            ("softwareConsultationTemplate", SystemTemplates.softwareConsultationTemplate),
            ("questPartyConsultationTemplate", SystemTemplates.questPartyConsultationTemplate),
            ("discussionConsultationTemplate", SystemTemplates.discussionConsultationTemplate),
            ("genericConsultationTemplate", SystemTemplates.genericConsultationTemplate),
        ]
        for (name, template) in consultationTemplates {
            XCTAssertTrue(template.contains("{globalContext}"),
                          "[\(name)] must include `{globalContext}` chip")
            XCTAssertFalse(template.contains("{toolCalling}"),
                           "[\(name)] must NOT include `{toolCalling}` (consultations ship `tools: []`)")
        }
    }

    func testEveryBuiltInMeetingTemplate_containsBothChips() {
        let meetingTemplates: [(String, String)] = [
            ("softwareMeetingTemplate", SystemTemplates.softwareMeetingTemplate),
            ("questPartyMeetingTemplate", SystemTemplates.questPartyMeetingTemplate),
            ("discussionMeetingTemplate", SystemTemplates.discussionMeetingTemplate),
            ("genericMeetingTemplate", SystemTemplates.genericMeetingTemplate),
        ]
        for (name, template) in meetingTemplates {
            XCTAssertTrue(template.contains("{globalContext}"),
                          "[\(name)] must include `{globalContext}` chip")
            XCTAssertTrue(template.contains("{toolCalling}"),
                          "[\(name)] must include `{toolCalling}` chip")
        }
    }
}
