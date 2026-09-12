import XCTest

@testable import NanoTeams

/// The shape rule `AskSupervisorTool` refuses on when the form is available — pinned on both
/// sides of every boundary, because a false positive here costs a chat role a turn on its
/// REPLY (every chat turn is an `ask_supervisor` call) and a false negative lets the
/// hand-rolled questionnaire through, which is the shape the rule exists to stop.
final class SupervisorQuestionShapeTests: XCTestCase {

    private func shaped(_ text: String) -> Bool { SupervisorQuestionShape.isQuestionnaire(text) }

    // MARK: - One question or a reply passes

    func testOneQuestion_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Should the badge hide instantly?"))
    }

    func testReply_withNoQuestion_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Done. The badge now hides when the count is zero; see `Badge.swift:40`."))
    }

    func testEmptyAndWhitespace_areNotQuestionnaires() {
        XCTAssertFalse(shaped(""))
        XCTAssertFalse(shaped("  \n\t"))
    }

    /// The plan-then-question reply: the enumeration PRECEDES the only question.
    func testNumberedPlan_thenOneQuestion_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Plan:\n1. Read the badge view.\n2. Add the toggle.\n3. Wire the setting.\nShall I proceed?"))
    }

    /// A spaced hyphen is a dash, not a bullet: bullets count at a line start only.
    func testOneQuestion_withSpacedHyphensAfterIt_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Which one? Either A - the default - or B - the fallback - works."))
    }

    // MARK: - Question marks that close nothing

    func testSwiftOptionals_inAFencedBlock_areNotQuestions() {
        XCTAssertFalse(shaped("Here is the shape:\n```swift\nvar title: String?\nvar count: Int?\n```\nIt compiles."))
    }

    func testUnterminatedFence_isStrippedToTheEnd() {
        XCTAssertFalse(shaped("Snippet:\n```\nlet a: Int?\nlet b: Int?\n"))
    }

    func testInlineCodeSpans_areNotQuestions() {
        XCTAssertFalse(shaped("Use `String?` for the title and `Int?` for the count."))
    }

    func testQueryStringInAURL_isNotAQuestion() {
        XCTAssertFalse(shaped("See https://example.com/docs?page=2&lang=en and https://example.com/a?b=c for details."))
    }

    /// `??` and `?!` are one sentence end each, not two.
    func testARunOfMarks_countsOnce() {
        XCTAssertFalse(shaped("Really??"))
        XCTAssertFalse(shaped("What?!"))
        XCTAssertTrue(shaped("Really?? And then?!"))
    }

    // MARK: - Two questions

    func testTwoQuestions_onOneLine_isAQuestionnaire() {
        XCTAssertTrue(shaped("Which view hides the badge? Should the choice persist?"))
    }

    func testTwoQuestions_onSeparateLines_isAQuestionnaire() {
        XCTAssertTrue(shaped("Two things before I plan:\n1. Which view hides the badge?\n2. Should the choice persist across launches?"))
    }

    func testTwoQuestions_inCyrillic_isAQuestionnaire() {
        XCTAssertTrue(shaped("Где прятать бейдж? Запоминать выбор между запусками?"))
    }

    func testTwoQuotedQuestions_closeOnTheQuote() {
        XCTAssertTrue(shaped("You asked \"where?\" and \"when?\" — both matter."))
    }

    func testFullWidthQuestionMark_counts() {
        XCTAssertTrue(shaped("哪个视图？ 是否持久化？"))
    }

    // MARK: - One question with its options

    func testOneQuestion_thenNumberedOptions_isAQuestionnaire() {
        XCTAssertTrue(shaped("How should the hiding be driven?\n1. A manual toggle in Settings (recommended)\n2. Automatically, when nothing is pending"))
    }

    func testOneQuestion_thenParenthesisedOptionsInline_isAQuestionnaire() {
        XCTAssertTrue(shaped("How should the hiding be driven? (1) a manual toggle (2) automatically when nothing is pending"))
    }

    func testOneQuestion_thenBulletOptions_isAQuestionnaire() {
        XCTAssertTrue(shaped("Which transition?\n- instant (recommended)\n- fade over 200 ms"))
    }

    func testOneQuestion_thenLetteredOptions_isAQuestionnaire() {
        XCTAssertTrue(shaped("Which transition?\na) instant\nb) fade"))
    }

    /// Markdown emphasis closes the question the way a quote does.
    func testBoldQuestion_thenOptions_isAQuestionnaire() {
        XCTAssertTrue(shaped("**Which one?** 1. Instant 2. Fade"))
    }

    func testOneQuestion_thenASingleOption_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Which transition?\n1. instant is the only sane choice, so I will take it."))
    }

    // MARK: - Markdown emphasis

    /// The live text of MeditationApp task 60 (2026-09-11, the A2 after-run 2), abridged: an
    /// analysis in bold bullets, the directions as BOLD numbered headings with the mark on the
    /// first, one open question. Read raw, the `**` hid both the enumeration and the mark, the
    /// rule saw a plan, the nudge named the plain ask, and the form came from the model alone.
    func testBoldNumberedHeadings_withARecommendedMark_isAQuestionnaire() {
        XCTAssertTrue(shaped("""
        Проанализировал текущий дизайн. Сейчас приложение в светлом минималистичном стиле:
        
        - **Палитра**: accentColor для активных элементов + gray.opacity(0.2) для фонов
        - **Карточки**: простые VStack без фонов/скруглений
        
        Вот несколько направлений, в какую сторону можно поменять дизайн.
        
        **1. Тёмная тема с глубиной (recommended)**
        Добавить акцентные градиенты вместо плоского accentColor.
        
        **2. Более крупная, «воздушная» типографика и пространство**
        Увеличить отступы, сделать таймер ещё крупнее.
        
        Мой совет — **2 + 1**: сначала токены, потом тёмная версия.
        
        Что именно вас интересует?
        """))
    }

    /// The same headings without the mark, before a question that asks for no choice, are a
    /// plan — the boundary does not move with the emphasis.
    func testBoldNumberedHeadings_withoutAMarkOrAChoiceWord_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("**1. Тёмная тема с глубиной**\nДобавить градиенты.\n\n**2. Крупная типографика**\nУвеличить отступы.\n\nЧто именно вас интересует?"))
    }

    func testUnderscoreEmphasis_isReadThroughTheSameWay() {
        XCTAssertTrue(shaped("__1. Instant (recommended)__\n__2. Fade over 200 ms__\nOK to go ahead?"))
    }

    /// Only the two-character markers go: a single `*` opening a line is a bullet.
    func testStarBullets_areNotEmphasis() {
        XCTAssertTrue(shaped("Which transition?\n* instant\n* fade over 200 ms"))
    }

    func testAnEmphasizedMark_isStillTheMark() {
        XCTAssertTrue(shaped("1. Instant **(recommended)**\n2. Fade\nOK to go ahead?"))
    }

    /// The strip is classification only — the text the gate refuses or the nudge quotes is
    /// the model's own, markers included.
    func testStrippingMarkup_leavesEverythingElse() {
        XCTAssertEqual(SupervisorQuestionShape.strippingMarkup("**bold** and `code` and _one_ * star"),
                       "bold and   and _one_ * star")
    }

    // MARK: - Options BEFORE the question

    /// The shape the first after-gate run sent past the tail-only rule (2026-09-11, task 4):
    /// three numbered alternatives, then "Which would you like?".
    func testOptionsBeforeTheQuestion_askingWhich_isAQuestionnaire() {
        XCTAssertTrue(shaped("Given that, here's what I'd suggest — pick one:\n\n1. Point me at the real codebase and I'll dig in.\n2. Describe the badge yourself and I'll plan from that.\n3. Paste the badge-rendering snippet here.\n\nWhich would you like?"))
    }

    /// The `(recommended)` mark is the prose fallback the prompt prescribed until 1.9.20 — an item
    /// wearing it is an option, whatever the question says.
    func testOptionsBeforeTheQuestion_withARecommendedMark_isAQuestionnaire() {
        XCTAssertTrue(shaped("1. Instant (recommended)\n2. Fade over 200 ms\nOK to go ahead?"))
    }

    func testOptionsBeforeTheQuestion_inRussian_isAQuestionnaire() {
        XCTAssertTrue(shaped("Варианты:\n1. Мгновенно\n2. Плавно за 200 мс\nКакой предпочитаете?"))
    }

    /// Findings before an information question are not a menu: no choice word, no mark.
    func testNumberedFindings_thenAnInfoQuestion_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Found two candidates:\n1. BadgeView.swift\n2. StatusBar.swift\nShould I read both before planning?"))
    }

    /// The sentence the choice words are read from: it must include the question itself, not
    /// the empty span between the `?` and its own terminator (the first cut read "" for every
    /// question and so never found a choice word).
    func testQuestionSentence_isTheQuestion_notTheEmptySpanAfterIt() {
        let text = "Plan is set.\nWhich one would you like?"
        let end = SupervisorQuestionShape.questionSentenceEnds(in: text).first!
        let sentence = SupervisorQuestionShape.questionSentence(endingAt: end, in: text)
        XCTAssertEqual(sentence, "Which one would you like?")
        XCTAssertTrue(SupervisorQuestionShape.asksForAChoice(sentence))
    }

    /// The measured rule's one false positive (2026-09-11, task 7, call 4): a confirmation
    /// summary in bullets, then ONE information question with "which" six words in.
    func testSummaryList_thenAnInfoQuestionContainingWhich_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Here's where we landed:\n- What: the Watchtower badge.\n- Behavior: hide via a manual toggle.\n- Persistence: a persistent setting.\n\nThe only missing piece is the badge's exact component. Can you point me to which component/file renders it?"))
    }

    func testOptionsBeforeTheQuestion_openingWithPrefer_isAQuestionnaire() {
        XCTAssertTrue(shaped("1. Instant\n2. Fade over 200 ms\nDo you prefer instant or fade?"))
    }

    /// The seven texts the gate refused across the two N=2 after-runs (2026-09-11, tasks 6
    /// and 7), in their structural shapes: six are questionnaires, the seventh (the summary +
    /// "which" question above) is not — the shipped rule agrees with the hand reading.
    func testTheMeasuredRefusals_replayAsSixTruePositivesAndOneFalse() {
        let truePositives = [
            "Here's what I need to know before planning:\n\n1. What determines when it's hidden — a manual toggle, or app state?\n2. Should the choice persist across launches?",
            "Got it. Here's what I've confirmed:\n- Trigger: a toggle.\n- Storage: the existing store.\n\nIs the Watchtower badge the one you mentioned before? Do you want me to look at the code first, or do you already have the files in mind?",
            "All requirements are gathered:\n- What: hide the badge.\n- Trigger: a toggle.\n\nWhat would you like next?\n1. Now let me locate the badge and produce the plan.\n2. Something else — tell me what you want.",
            "Here are the open clarifying questions:\n\n1. When should the badge be hidden vs. shown?\n2. Persistent toggle or one-off hide?\n3. Where does the control live?\n4. Scope of hiding: everywhere, or one location?",
            "Here's where we stand:\n- I can reach only this work folder.\n\nWhich would you like — and can you give me the answer to whichever applies?\n\n1. Point me at the repo path, or\n2. Drop the relevant files into this folder.",
            "These three questions are yours to answer.\n\n1. What platform/framework is the app on?\n2. Confirm the 'sometimes' rule: manual on/off toggle?\n3. Confirm persistence: a persistent setting?",
        ]
        for text in truePositives {
            XCTAssertTrue(shaped(text), "expected a questionnaire: \(text.prefix(60))")
        }
        XCTAssertFalse(shaped("Everything I need has been answered except one thing.\n\nHere's where we landed:\n- What: the badge.\n- Behavior: a manual toggle.\n\nThe only missing piece is the badge's exact component. Can you point me to which component/file renders it?"))
    }

    /// A single either/or with no list stays a plain ask — the digit-in-the-composer branch.
    func testOneEitherOr_withoutAList_isNotAQuestionnaire() {
        XCTAssertFalse(shaped("Do you prefer the badge to hide instantly or to fade out?"))
    }
    // MARK: - One verdict, two readers

    /// The gate (`AskSupervisorTool`) and the no-tool nudges read the SAME predicate: they
    /// disagreed once, and it cost a turn per occurrence — the nudge told the model to put a
    /// menu through `ask_supervisor`, which the gate then refused (MeditationApp task 52
    /// run 10, 2026-09-11). `requiresForm` is the conjunction both call.
    ///
    /// RED: let either reader call `isQuestionnaire` with its own availability check → the
    /// two can drift again.
    func testRequiresForm_isTheGateAndTheNudgeReadingOneVerdict() {
        let menu = """
        Предлагаю варианты:
        
        1. Мини-редизайн (recommended)
        2. Тёмная тема
        
        Какой вариант выбираем?
        """
        XCTAssertTrue(SupervisorQuestionShape.isQuestionnaire(menu))
        XCTAssertTrue(SupervisorQuestionShape.requiresForm(menu, formAvailable: true))
        XCTAssertFalse(SupervisorQuestionShape.requiresForm(menu, formAvailable: false),
                       "no addressee, no refusal — the numbered list parks")

        let single = "Done. Shall I commit this?"
        XCTAssertFalse(SupervisorQuestionShape.isQuestionnaire(single))
        XCTAssertFalse(SupervisorQuestionShape.requiresForm(single, formAvailable: true))
    }
}
