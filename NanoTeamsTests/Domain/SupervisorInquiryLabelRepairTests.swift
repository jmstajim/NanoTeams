import XCTest

@testable import NanoTeams

/// `SupervisorInquiryLabelRepair` — option labels as the model writes them (`"(recommended)"`
/// beside the RECOMMENDED badge, `"1. "` beside a radio button; MeditationApp task 52 runs
/// 10–11, 2026-09-11), normalized at the tool seam with every rewrite reported.
final class SupervisorInquiryLabelRepairTests: XCTestCase {

    private func choice(_ labels: [String], ids: [String]? = nil) -> SupervisorInquiry {
        let options = labels.enumerated().map { index, label in
            SupervisorInquiryOption(
                id: ids?[index] ?? SupervisorInquiryIdentity.resolve("", fallbackFrom: label),
                label: label)
        }
        return SupervisorInquiry(headline: "H", questions: [
            SupervisorInquiryQuestion(id: "q", prompt: "Which?", kind: .singleChoice, options: options),
        ])
    }

    private func labels(_ outcome: SupervisorInquiryLabelRepair.Outcome) -> [String] {
        outcome.inquiry.questions[0].options.map(\.label)
    }

    private func recommended(_ outcome: SupervisorInquiryLabelRepair.Outcome) -> String? {
        outcome.inquiry.questions[0].recommendedOption?.label
    }

    private func choice(
        _ labels: [String], details: [String?]
    ) -> SupervisorInquiry {
        SupervisorInquiry(headline: "H", questions: [
            SupervisorInquiryQuestion(
                id: "q", prompt: "Which?", kind: .singleChoice,
                options: zip(labels, details).map {
                    SupervisorInquiryOption(
                        id: SupervisorInquiryIdentity.resolve("", fallbackFrom: $0),
                        label: $0, detail: $1)
                }),
        ])
    }

    // MARK: - The marker

    func testTrailingRecommendedMarker_isStripped_andRead() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Mini redesign (recommended)", "Dark theme"]))
        XCTAssertEqual(labels(outcome), ["Mini redesign", "Dark theme"])
        XCTAssertEqual(recommended(outcome), "Mini redesign")
        XCTAssertEqual(outcome.notes, [
            SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 1),
        ])
    }

    func testRussianMarker_isStripped() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Мини-редизайн (рекомендуется)", "Тёмная тема"]))
        XCTAssertEqual(labels(outcome), ["Мини-редизайн", "Тёмная тема"])
        XCTAssertEqual(recommended(outcome), "Мини-редизайн")
    }

    /// The marker RESOLVES the recommendation and the order is left alone. Until 2026-09-12
    /// this moved the option to index 0, because position WAS the recommendation — and the
    /// order the model chose (the archived design form lists by scope) was destroyed to encode
    /// one bit. There is somewhere else to put that bit now.
    ///
    /// RED: move the marked option to index 0 again → the human reads the model's options in
    /// an order it never wrote, and the scope ordering the archived design form carried is
    /// gone.
    func testASingleMarkedOption_notFirst_isReadWithoutReordering() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Dark", "Light", "Glass [recommended]"]))
        XCTAssertEqual(labels(outcome), ["Dark", "Light", "Glass"])
        XCTAssertEqual(recommended(outcome), "Glass")
    }

    func testAMarkedFirstOption_isStrippedAndRead() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Glass (Recommended)", "Dark"]))
        XCTAssertEqual(labels(outcome), ["Glass", "Dark"])
        XCTAssertEqual(recommended(outcome), "Glass")
    }

    /// The ordinary case, and the one the whole change is about: the model recommended
    /// nothing, so nothing is recommended.
    ///
    /// RED: resolve `recommendedOption` to `options.first` when no id is set → every choice
    /// question carries a recommendation the model never made, which is what the card showed
    /// until 2026-09-12.
    func testNoMarkerAnywhere_leavesNoRecommendation() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Dark", "Light", "Glass"]))
        XCTAssertNil(recommended(outcome))
        XCTAssertTrue(outcome.notes.isEmpty)
    }

    // MARK: - The recommendation written in a detail

    /// What the field archive actually contains: three recommendations, all of them the FIRST
    /// word of an option's `detail`, none of them a marker in a label.
    func testLeadingRecommendWordInADetail_isRead_andTheDetailIsKeptWhole() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(
            ["Тёмная", "Адаптив"],
            details: [nil, "Рекомендую — пользователи выбирают в системе"]))
        XCTAssertEqual(recommended(outcome), "Адаптив")
        XCTAssertEqual(
            outcome.inquiry.questions[0].options[1].detail,
            "Рекомендую — пользователи выбирают в системе",
            "the detail is the model's REASON, not a marker to strip — the badge summarises it")
        XCTAssertTrue(outcome.notes.isEmpty, "reading is not a rewrite — nothing to report")
    }

    func testEnglishLeadingRecommendWord_isRead() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(
            ["Debug", "Release"], details: ["Recommended. What CI uses", nil]))
        XCTAssertEqual(recommended(outcome), "Debug")
    }

    /// The anchor IS the false-positive defence, and it is free: in both languages the
    /// negation particle precedes the verb.
    ///
    /// RED: drop the `^` anchor from `leadingRecommendation` → «Apple не рекомендует этот
    /// подход» marks the option it argues against, and badging a human's choices from prose is
    /// exactly what KNOWN_ISSUES A32 refuses to risk.
    func testARecommendationMentionedButNotMade_isNotRead() {
        for detail in [
            "Не рекомендую — ломает совместимость",
            "Apple не рекомендует этот подход",
            "Рекомендация Apple HIG — держать один акцент",
            "Not recommended — deprecated in macOS 26",
            "Как рекомендовано в отчёте Tech Lead",
        ] {
            let outcome = SupervisorInquiryLabelRepair.apply(
                to: choice(["A", "B"], details: [detail, nil]))
            XCTAssertNil(recommended(outcome), detail)
        }
    }

    /// Two recommendations name none: the model did not resolve this for itself, and picking
    /// one of them would be the app deciding. Not a refusal — a questionnaire is not worth
    /// bouncing over a badge.
    func testTwoDetailsRecommending_leaveNoRecommendation() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(
            ["A", "B"], details: ["Рекомендую — быстрее", "Рекомендую — дешевле"]))
        XCTAssertNil(recommended(outcome))
    }

    /// A label marker is the more deliberate spelling and wins when the model wrote both.
    func testALabelMarkerWinsOverADetailSentence() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(
            ["Dark (recommended)", "Light"], details: [nil, "Рекомендую — ярче"]))
        XCTAssertEqual(recommended(outcome), "Dark")
    }

    /// Two markers name no single recommendation: the words go, the order is kept, and
    /// nothing is marked.
    func testSeveralMarkedOptions_areStrippedAndRecommendNothing() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["Dark (recommended)", "Light", "Glass (recommended)"]))
        XCTAssertEqual(labels(outcome), ["Dark", "Light", "Glass"])
        XCTAssertNil(recommended(outcome))
        XCTAssertEqual(outcome.notes, [SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 2)])
    }

    // MARK: - Enumeration

    func testLeadingEnumeration_isStripped() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["1. Чистый light", "2) Тёмная", "(3) Glass", "a) Категории"]))
        XCTAssertEqual(labels(outcome), ["Чистый light", "Тёмная", "Glass", "Категории"])
        XCTAssertEqual(outcome.notes, [SupervisorInquiryLabelRepair.enumerationNote(count: 4)])
    }

    /// A label that IS an enumeration ("1.") has nothing after the prefix; it stays, and is
    /// counted for nothing.
    func testALabelThatIsOnlyAnEnumeration_isKept() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["1.", "2. Dark"]))
        XCTAssertEqual(labels(outcome), ["1.", "Dark"])
        XCTAssertEqual(outcome.notes, [SupervisorInquiryLabelRepair.enumerationNote(count: 1)])
    }

    func testBothRulesOnOneLabel_areAppliedAndBothReported() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["1. Мини-редизайн (recommended)", "2. Тёмная"]))
        XCTAssertEqual(labels(outcome), ["Мини-редизайн", "Тёмная"])
        XCTAssertEqual(recommended(outcome), "Мини-редизайн")
        XCTAssertEqual(outcome.notes, [
            SupervisorInquiryLabelRepair.enumerationNote(count: 2),
            SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 1),
        ])
    }

    // MARK: - Ids

    /// A derived id follows the label it was derived from; an authored id is the model's own.
    func testSynthesizedIdsFollowTheStrippedLabel_authoredIdsDoNot() {
        let derived = SupervisorInquiryLabelRepair.apply(to: choice(["1. Dark theme", "Light"]))
        XCTAssertEqual(derived.inquiry.questions[0].options.map(\.id), ["dark_theme", "light"])
        let authored = SupervisorInquiryLabelRepair.apply(to: choice(["1. Dark theme", "Light"], ids: ["opt_dark", "opt_light"]))
        XCTAssertEqual(authored.inquiry.questions[0].options.map(\.id), ["opt_dark", "opt_light"])
        XCTAssertEqual(labels(authored), ["Dark theme", "Light"])
    }

    /// `"1. Debug"` and `"Debug (recommended)"` both slug to `debug`; merging them would
    /// record one option's answer against the other. Every raw id of that question is kept.
    func testCollidingIdsAfterStripping_areNotSilentlyMerged() {
        let outcome = SupervisorInquiryLabelRepair.apply(to: choice(["1. Debug", "Debug (recommended)", "Release"]))
        let ids = outcome.inquiry.questions[0].options.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "\(ids)")
        XCTAssertTrue(ids.contains("1_debug") && ids.contains("debug_recommended"), "\(ids)")
        XCTAssertEqual(labels(outcome), ["Debug", "Debug", "Release"])
    }

    // MARK: - Nothing to do, idempotence, free text

    func testCleanLabels_comeBackUntouched_withNoNotes() {
        let inquiry = choice(["Dark theme", "Light theme"])
        let outcome = SupervisorInquiryLabelRepair.apply(to: inquiry)
        XCTAssertEqual(outcome.inquiry, inquiry)
        XCTAssertEqual(outcome.notes, [])
    }

    /// RED: resolve the recommendation without carrying a resolved one forward → the second
    /// pass finds no marker (the first stripped it) and clears `recommendedOptionID`, so a
    /// questionnaire that went through the seam twice loses the badge it had earned.
    func testNormalization_isIdempotent() {
        let once = SupervisorInquiryLabelRepair.apply(to: choice(["2. Dark (recommended)", "1. Light"]))
        XCTAssertEqual(recommended(once), "Dark")
        let twice = SupervisorInquiryLabelRepair.apply(to: once.inquiry)
        XCTAssertEqual(twice.inquiry, once.inquiry)
        XCTAssertEqual(twice.notes, [])
    }

    func testAFreeTextQuestion_isPassedThrough() {
        let inquiry = SupervisorInquiry(headline: "H", questions: [
            SupervisorInquiryQuestion(id: "q", prompt: "1. Anything (recommended)?", kind: .freeText),
        ])
        let outcome = SupervisorInquiryLabelRepair.apply(to: inquiry)
        XCTAssertEqual(outcome.inquiry, inquiry)
        XCTAssertEqual(outcome.notes, [])
    }

    /// The identity guard: the pass lives at the TOOL seam, so a persisted questionnaire —
    /// decoded through `SupervisorInquiry.init(from:)` — comes back byte-for-byte, marker,
    /// number and identity included. RED: move the pass into `init(from:)` → the stored form's
    /// identity changes on reload and every parked draft answer is orphaned.
    func testAStoredInquiry_decodesUnchanged() throws {
        let stored = choice(["1. Dark (recommended)", "2. Light"])
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(SupervisorInquiry.self, from: data)
        XCTAssertEqual(decoded, stored)
        XCTAssertEqual(decoded.identity, stored.identity)
    }
}
