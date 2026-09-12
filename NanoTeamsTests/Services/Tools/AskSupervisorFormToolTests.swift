import XCTest

@testable import NanoTeams

/// `ask_supervisor_form` — the handler, its two accepted argument shapes, and the line it
/// draws between "park the step" and "tell the model it got the payload wrong".
/// Not `@MainActor`: the handler and its context are both `nonisolated` value types, so the
/// class needs no isolation — and a `@MainActor` class here would have to carry `async`
/// lifecycle overrides (`Ratchet/TestLifecycleIsolationPinTests`) for no reason.
final class AskSupervisorFormToolTests: XCTestCase {

    private let sut = AskSupervisorFormTool()

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(
            workFolderRoot: URL(fileURLWithPath: "/tmp"),
            taskID: 1, runID: 0, roleID: "planner")
    }

    private func run(_ args: [String: Any]) async -> ToolExecutionResult {
        await sut.handle(context: context(), args: args)
    }

    private static let validForm = """
    {"questions":[
      {"prompt":"Which scheme?","kind":"single_choice",
       "options":[{"label":"Debug"},{"label":"Release"}]},
      {"prompt":"Anything else?","kind":"free_text"}
    ]}
    """

    /// Verbatim from the live run of 2026-09-10 (trimmed to two questions; the defect is
    /// byte-for-byte what the model emitted). The second question opens with `"prompt"`
    /// directly after `}],}` — the `{` that starts it was dropped, 483 characters into 2291
    /// of hand-escaped JSON. One slip in one of two runs is the standing cost of a `String`
    /// parameter carrying a nested payload (`JSONSchema` cannot express one — CLAUDE.md #46).
    private static let brokenFormFromTheLiveRun = """
    {"questions":[{"prompt":"ContentView.Tab is fileprivate, so TabRouter.swift cannot reference it. May I drop the fileprivate modifier (to internal) so TabRouter can name ContentView.Tab, without restructuring the TabView?","kind":"single_choice","options":[{"label":"Yes, drop fileprivate, keep structure","detail":"Smallest change; enum and TabView layout untouched."},{"label":"No, lift Tab enum into its own top-level type","detail":"More churn but cleaner separation."}]},"prompt":"The two intents must conform to ProvidesDialog.","kind":"free_text"}]}
    """

    /// Verbatim from the live run of 2026-09-11 (MeditationApp task 52, run 9, the eighth call
    /// of ten): the model opened a string with `«`, the Russian quotation mark, where JSON
    /// wants `"` — byte 1276, character 854 (zero-based). Three of that run's five forms did, and
    /// the model guessed "escaping" and then "curly quotes" before it found the character,
    /// because the envelope said only "not valid JSON": the excerpt window was cut at a BYTE
    /// offset, which in Cyrillic lands inside a letter, and `String(utf8[…])` — failable —
    /// answered nil, silently.
    private static let guillemetFormFromTheLiveRun = """
    {"questions": [{"prompt": "Что сделать в первую очередь при рестайлинге", "kind": "single_choice", "options": [{"label": "Сначала главный экран (Today) + метрики", "detail": "Hero-секция и StatCard - первое, что видит пользователь."}, {"label": "Сначала карточки метрик (StatCard)", "detail": "Общая плитка-метрика, потом остальное."}, {"label": "Одновременно Today + библиотека + профиль", "detail": "Сразу по всем экранам, дольше."}, {"label": "Показывать/согласовывать каждый экран отдельно", "detail": "Пошагово с подтверждением."}]}, {"prompt": "Добавлять ли тени и глубину карточкам в стиле минимализма", "kind": "single_choice", "options": [{"label": "Тонкие мягкие тени + светлый фон", "detail": "Лёгкий объём, современный flat с глубиной."}, {"label": "Только контуры (stroke), без тени", "detail": "Максимально плоский минимализм."}, {"label": «Без правок по теням", "detail": "Оставить как есть, менять только фон/радиусы."}]}, {"prompt": "Ещё что-то учитывать в дизайне?", "kind": "free_text"}]}
    """

    /// Verbatim from MeditationApp task 67 run 1, the FIRST of three calls (2026-09-11,
    /// `qwen3.8:27b-nvfp4`): 1931 characters of hand-escaped Russian JSON in which every
    /// container the model opened is closed — except the `{` that opens the document itself.
    /// Nothing is missing from the CONTENT; only the frame around it.
    ///
    /// What it cost before the tail rung existed: the refusal led with Foundation's constant
    /// "The given data was not valid JSON." and an excerpt of Cyrillic, and the model read
    /// the excerpt as the diagnosis — "my JSON string contains a Russian character … I will
    /// use ASCII-safe text" — and re-sent the whole questionnaire TRANSLATED INTO ENGLISH,
    /// still one `}` short. Three calls and ~50 s for one bracket, and the Russian-speaking
    /// Supervisor was handed an English form.
    private static let unclosedFormFromTheLiveRun = #"""
    {"questions": [{"prompt": "Какое направление дизайна тебе ближе?", "kind": "single_choice", "options": [{"label": "Минимализм + дыхание", "detail": "Почти пустой экран, дышащий круг, 2–3 цвета, скруглённые плитки-пузыри"}, {"label": "Пейзаж / природа", "detail": "Градиенты рассвет/закат/ночь, растущее растение для стрика, material-карточки"}, {"label": "Скандинавский", "detail": "Светлый off-white, один насыщенный акцент, линейные иконки, плоская статистика"}, {"label": "Тёмный + золотой акцент (premium)", "detail": "Чёрный фон, тёплое золото/медь, тонкие обводки, компактный виджет"}, {"label": "Геймификация", "detail": "Огонь-стрик, уровни-сессии, конфетти после сессии, кольцо прогресса"}]}, {"prompt": "Какой режим темы?", "kind": "single_choice", "options": [{"label": "Тёмная + светлая (адаптив)", "detail": "Рекомендую — пользователи выбирают в системе"}, {"label": "Только тёмная", "detail": "Проще в реализации, атмосфера фокуса"}, {"label": "Только светлая", "detail": "Проще в реализации, дневной свет"}]}, {"prompt": "Какой объём экранов перерабатываем?", "kind": "single_choice", "options": [{"label": "Library + Player + Onboarding + Profile (всё)", "detail": "Полный редизайн, единый стиль"}, {"label": "Library + Player (основной путь)", "detail": "Рекомендую начать с этого — пользователь видит это чаще всего"}, {"label": "Только SessionPlayer", "detail": "Минимум, фокус на экран во время сессии"}]}, {"prompt": "Уровень анимаций?", "kind": "single_choice", "options": [{"label": "Средний (spring, fade, slide)", "detail": "Рекомендую — ощущается «живо», но не отвлекает от медитации"}, {"label": "Минимальный (fade 0.2s)", "detail": "Максимум тишины, почти без движения"}, {"label": "Богатый (PhaseAnimator, KeyframeAnimator, particle)", "detail": "Впечатляет, но требует больше внимания и может отвлекать"}]}, {"prompt": "Есть пожелания по цветам, шрифтам или конкретным деталям?", "kind": "free_text"}]
    """#

    /// Verbatim from MeditationApp task 65 run 0, the FIRST of three calls (2026-09-11,
    /// `ornith-1.5:35b`). The first question's options array closes and the second question
    /// opens immediately after it — `…}], {"prompt"` — so the question object that contained
    /// the array was never closed: one `}`, 557 characters in. Nothing else is wrong with
    /// the 1444 characters, and the single `«ночь»` pair sits inside a proper `"` string,
    /// where it is content.
    private static let droppedCloserFormFromTheLiveRun = #"""
    {"questions": [{"prompt": "Какую цветовую палитру задать при переработке дизайна?","kind":"single_choice","options": [{"label":"Тёплый рассвет (лаватa/персик/пудра)","detail":"Мягкие пастельные тона, меняют синие акценты на успокаивающие — лучший выбор для meditation-приложения."}, {"label":"Холодный минимализм (серо-лавандовый)","detail":"Спокойные холодные тона, сохраняет сдержанность, но добавляет характер."}, {"label":"Тёмная «ночь» тема","detail":"Тёмный фон с приглушёнными акцентами, снижает нагрузку на глаза, особенно для вечерних медитаций."}], {"prompt":"Какой масштаб изменений хотите?","kind":"single_choice","options": [{"label":"Палитра + типографика/кругления (в. 1 + 5)","detail":"Самый безопасный вариант: тёплая палитра, градиент к кругу дыхания, единые скругления. Без правки логики."}, {"label":"Палитра + атмосферный фон (в. 1 + 2)","detail":"Добавить мягкие размытые градиенты-облака на фон Today и Breathe."}, {"label":"Полный редизайн (в. 1 + 3 + 4)","detail":"Палитра, дыхательная визуальная система с анимацией, круговой прогресс в плеере, переделать статистику."}]}, {"prompt":"Применить изменения сразу или сначала показать превью?","kind":"single_choice","options": [{"label":"Сразу применить и собрать","detail":"Сделаю правки и запущу xcodebuild, чтобы убедиться, что билд зелёный."}, {"label":"Сначала показать, что изменится","detail":"Опишу план правок по файлам без изменения кода, потом согласуем."}]}]}
    """#

    /// The SECOND call of the same step, trimmed to its last question (the defect is
    /// byte-for-byte what the model emitted). Two faults at once: strings delimited with
    /// « », which the repair reads, and an options array whose only object was abandoned
    /// mid-emission — trailing comma, no `}`, and the second option never written. Putting
    /// the missing `}` back makes it PARSE, as a choice offering one answer; that is the
    /// form the completeness validator exists to refuse.
    private static let truncatedFormFromTheLiveRun = #"""
    {
      "questions": [
        {
          "prompt": «Применить изменения сразу или сначала показать, что изменится?»,
          "kind": "single_choice",
          "options": [
            {"label": «Сразу применить и собрать»,
          ]
        }
      ]
    }
    """#

    // MARK: - Both argument shapes

    /// The declared type is `string`, and a provider that honours it sends JSON text.
    func testAcceptsTheFormAsAJSONString() async {
        let result = await run(["headline": "Two questions", "form": Self.validForm])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(headline, "Two questions")
        XCTAssertEqual(inquiry.questions.count, 2)
    }

    /// The DECLARED shape since 2026-09-12. `argumentTypeViolations` refuses neither it nor
    /// the string (it judges only `boolean`/`integer`/`array`), so the string stays accepted
    /// as tolerance and the whole repair ladder stays reachable. `create_team` is the twin.
    func testAcceptsTheFormAsAParsedObject() async {
        let object: [String: Any] = [
            "questions": [
                ["prompt": "Which scheme?", "kind": "single_choice",
                 "options": [["label": "Debug"], ["label": "Release"]]]
            ]
        ]
        let result = await run(["headline": "One question", "form": object])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(inquiry.questions.first?.options.map(\.label), ["Debug", "Release"])
    }

    /// A value JSON cannot represent raises an ObjC exception inside
    /// `data(withJSONObject:)` — it does not throw, so no Swift catch can see it and the
    /// process dies. The guard in front of it is the only defence.
    ///
    /// RED: delete the `isValidJSONObject` guard → this test crashes the test runner rather
    /// than failing.
    func testUnrepresentableObjectIsRefusedRatherThanCrashing() async {
        let result = await run([
            "headline": "H",
            "form": ["questions": [["prompt": "P", "kind": "free_text", "x": Double.nan]]],
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("JSON cannot represent"), result.outputJSON)
    }

    /// The SAME guard on the `questions`-at-the-top route. Two routes reach
    /// `data(withJSONObject:)` — the `form` dict and the whole argument dictionary — and each
    /// needs its own guard, because the one that is missing is the one that kills the process.
    /// The lift arrived 2026-09-12 without this twin.
    ///
    /// RED: delete the `isValidJSONObject` guard on the `questions` route → this test crashes
    /// the test runner rather than failing.
    func testUnrepresentableValueUnderTopLevelQuestions_isRefusedRatherThanCrashing() async {
        let result = await run([
            "headline": "H",
            "questions": [["prompt": "P", "kind": "free_text", "x": Double.nan]],
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("JSON cannot represent"), result.outputJSON)
    }

    // MARK: - The headline is an argument, not a form field

    /// It arrives outside the blob so a truncated body still delivers the one line every
    /// existing surface renders — and so the streaming card has something to show.
    func testHeadlineComesFromTheArgumentNotTheForm() async {
        let result = await run([
            "headline": "The real headline",
            "form": #"{"headline":"ignored","questions":[{"prompt":"P","kind":"free_text"}]}"#,
        ])
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(inquiry.headline, "The real headline")
    }

    /// Refused until 2026-09-12, when the second trainer run measured what the requirement
    /// actually costs: 4 of 20 runs (`ornith-1.5:35b`, MeditationApp task 76) emitted
    /// `{"form": {…}}` and stopped — the model writes the questionnaire first and treats the
    /// call as finished when it closes. Each one cost a refusal and a whole second emission,
    /// and each recovered on the retry, so the requirement was not teaching the model
    /// anything it did not already know. The questionnaire carries what it meant: the
    /// derivation is `SupervisorInquiryHeadlineFallback`, at this seam, and the dispatcher
    /// still never sees an empty one.
    func testAMissingHeadlineIsDerivedFromTheQuestionnaire() async throws {
        let result = await run(["form": Self.validForm])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, let inquiry) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Which scheme?")
        XCTAssertEqual(inquiry.headline, "Which scheme?")
        XCTAssertEqual(
            try warnings(in: result), [SupervisorInquiryHeadlineFallback.note],
            "an adopted rewrite is reported — REC.5")
    }

    /// Blank is absent: the domain refuses an empty headline (every surface renders that one
    /// `String`), so covering the omission has to cover the whitespace spelling of it too.
    func testABlankHeadlineIsDerivedRatherThanRefused() async throws {
        let result = await run(["headline": "   ", "form": Self.validForm])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Which scheme?")
    }

    /// The fallback is a floor, not a preference: a headline the model DID write wins, and
    /// nothing is reported as rewritten.
    func testAnAuthoredHeadlineIsNotReplacedByTheDerivedOne() async throws {
        let result = await run(["headline": "Two questions", "form": Self.validForm])
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Two questions")
        XCTAssertEqual(try warnings(in: result), [])
    }

    /// The model writes the headline where the schema does not put it — inside the document —
    /// and in 1 of the 2 field calls that did so it was the ONLY copy (MeditationApp task 75
    /// run 9, 2026-09-12). Deriving one from the questions there would discard a headline the
    /// model had written, so the nested spelling is read and reported, never refused.
    func testAHeadlineNestedInsideTheFormIsReadRatherThanDerived() async throws {
        let form = #"{"headline":"Уточнения по рестайлингу","questions":[{"prompt":"P","kind":"free_text"}]}"#
        let result = await run(["form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Уточнения по рестайлингу")
        XCTAssertEqual(try warnings(in: result), [SupervisorInquiryHeadlineFallback.nestedNote])
    }

    /// Preference order, pinned in one test so a reordering of the three arms is visible:
    /// the sibling ARGUMENT beats a nested one, and a nested one beats the derivation.
    func testTheSiblingArgumentWinsOverANestedHeadline() async throws {
        let form = #"{"headline":"nested","questions":[{"prompt":"P","kind":"free_text"}]}"#
        let result = await run(["headline": "sibling", "form": form])
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "sibling")
        XCTAssertEqual(try warnings(in: result), [], "nothing was adopted — the schema's own slot was used")
    }

    /// A nested headline the domain would refuse — blank — is not a headline: the ladder goes
    /// on to the derivation rather than failing on a value it chose itself.
    func testABlankNestedHeadlineFallsThroughToTheDerivation() async throws {
        let form = #"{"headline":"   ","questions":[{"prompt":"Что дальше?","kind":"free_text"}]}"#
        let result = await run(["form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Что дальше?")
        XCTAssertEqual(try warnings(in: result), [SupervisorInquiryHeadlineFallback.note])
    }

    /// A nested value of the WRONG type is not a headline either, and must not fail the decode:
    /// the document is otherwise valid and the questions are what the human needs to see.
    func testANonStringNestedHeadlineIsIgnoredRatherThanFatal() async throws {
        let form = #"{"headline":42,"questions":[{"prompt":"Что дальше?","kind":"free_text"}]}"#
        let result = await run(["form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(headline, "Что дальше?")
    }

    /// Verbatim from MeditationApp task 76 run 3 (2026-09-12, `ornith-1.5:35b`): the whole
    /// emission, headline and all — there is no headline. The prompt is a statement rather
    /// than a question, which is exactly why it reads as the headline: it is the line the
    /// model wrote for the Supervisor to see first.
    func testTheLiveHeadlinelessEmissionParksWithADerivedHeadline() async throws {
        let form = """
        {"questions":[{"detail":"Кратко приветствие и подтверждение готовности.",\
        "kind":"free_text","prompt":"Привет! Всё работает, инструменты на месте. Готов \
        продолжать работу над MeditationApp (M19 — следующий milestone)."}]}
        """
        let result = await run(["form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, _) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(
            headline,
            "Привет! Всё работает, инструменты на месте. Готов продолжать работу над "
                + "MeditationApp (M19 — следующий milestone).")
    }

    func testMissingFormIsRefused() async {
        let result = await run(["headline": "H"])
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal)
    }

    // MARK: - A bad form is an ERROR, never a park

    /// A step parked on a form nobody can render waits for an answer to a question that was
    /// never asked. An error is a thing the model can read and fix in one more call.
    func testMalformedFormReturnsAnErrorAndRaisesNoSignal() async {
        let result = await run(["headline": "H", "form": #"{"questions":[]}"#])
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal, "a refused form must not park the step")
        XCTAssertTrue(result.outputJSON.contains("at least one question"), result.outputJSON)
    }

    /// `{}` and `{"questions":[]}` are one refusal reached by two routes: the absent key
    /// through `decodeIfPresent`'s fallback, the empty list through the decoded array. A model
    /// that emitted an empty object has to be told what a questionnaire needs, not which key
    /// its JSON is missing — the second sends it back to the schema, the first to the answer.
    ///
    /// RED: `try c.decode([Failable<SupervisorInquiryQuestion>].self, forKey: .questions)` →
    /// `{}` fails as `keyNotFound` and the message stops naming the requirement.
    func testAFormWithNoQuestionsKeyIsTheSameRefusalAsAnEmptyList() async {
        let result = await run(["headline": "H", "form": "{}"])
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal, "a refused form must not park the step")
        XCTAssertTrue(result.outputJSON.contains("at least one question"), result.outputJSON)
    }

    func testUnparseableJSONReturnsAnError() async {
        let result = await run(["headline": "H", "form": "{not json"])
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.signal)
    }

    /// A form is an array of arrays: without the coding path the model is told a label is too
    /// long and has to re-emit the whole questionnaire to find which one.
    ///
    /// RED: return `ctx.debugDescription` alone from `SupervisorFormDecoding.message` → the
    /// `questions` anchor disappears and the model is told only that something, somewhere,
    /// is wrong.
    func testDecodeErrorNamesWhereItHappened() async {
        let result = await run(["headline": "H", "form": #"{"questions":[]}"#])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("questions"), result.outputJSON)
    }

    /// One malformed question is DROPPED, not fatal — nine good questions are worth nine.
    /// But a dropped question is one the model believes it asked and will never get an answer
    /// to, so the pending envelope says so instead of quietly asking fewer.
    ///
    /// RED: drop the `droppedQuestions` warning → the form still parks with two questions and
    /// nothing anywhere reports that a third was discarded.
    func testMalformedQuestionIsDroppedAndReported() async {
        let form = """
        {"questions":[{"prompt":"Fine","kind":"free_text"},
                      {"prompt":"Bad","kind":"single_choice","options":[]},
                      {"prompt":"Also fine","kind":"free_text"}]}
        """
        let result = await run(["headline": "H", "form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(inquiry.questions.map(\.prompt), ["Fine", "Also fine"])
        XCTAssertTrue(result.outputJSON.contains("1 question(s) were malformed"), result.outputJSON)
    }

    func testNoWarningWhenEveryQuestionSurvives() async {
        let result = await run(["headline": "H", "form": Self.validForm])
        XCTAssertTrue(result.outputJSON.contains(#""warnings":[]"#), result.outputJSON)
    }

    /// A nested failure names the FULL path, array index included — which question, which
    /// option. `[0]` and `.label` are two different spellings inside one loop, and the loop is
    /// what turns a coding path into something a model can act on.
    ///
    /// Driven against the renderer rather than through the tool: the decoder drops a malformed
    /// QUESTION per element (`Failable`) instead of failing the payload, so the indexed path is
    /// reachable only from a container decode — which is where Foundation builds it.
    ///
    /// RED: spell every key as `key.stringValue` → the index renders as `Index 0` and the
    /// separator logic puts a dot before it.
    func testDecodeErrorRendersAnIndexedPath() {
        struct PathKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init(_ s: String) { stringValue = s; intValue = nil }
            init(_ i: Int) { intValue = i; stringValue = String(i) }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { self.init(intValue) }
        }
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [PathKey("questions"), PathKey(0), PathKey("options"), PathKey(2),
                             PathKey("label")],
                debugDescription: "Label is too long."))

        let message = SupervisorFormDecoding.message(error, in: "{}")

        XCTAssertEqual(message, "Label is too long. (at `questions[0].options[2].label`)")
    }

    /// A non-decoding failure has no coding path to report, so it falls through to the shared
    /// classifier rather than pretending to name a place in the JSON.
    ///
    /// RED: force the `as? DecodingError` cast (`as! DecodingError`) → the call traps instead
    /// of answering.
    func testNonDecodingErrorFallsBackToTheSharedClassifier() {
        struct Boom: Error {}
        let message = SupervisorFormDecoding.message(Boom(), in: "{}")

        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("at `"), "there is no coding path to name")
    }

    // MARK: - Pending envelope

    /// The envelope reports the headline and a COUNT, not the form: the model just wrote it,
    /// and echoing it back doubles the largest payload of the turn on a wire that is resent
    /// whole every request.
    func testPendingEnvelopeReportsTheCountNotTheWholeForm() async {
        let result = await run(["headline": "Two questions", "form": Self.validForm])
        XCTAssertTrue(result.outputJSON.contains("\"status\":\"pending\""), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("\"questions\":2"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("Which scheme?"), "the form must not be echoed")
    }

    // MARK: - Registration

    func testIsRegisteredAsASupervisorToolExcludedFromMeetings() {
        XCTAssertEqual(AskSupervisorFormTool.category, .supervisor)
        XCTAssertTrue(AskSupervisorFormTool.excludedInMeetings)
        XCTAssertTrue(ToolHandlerRegistry.allSchemas.contains { $0.name == ToolNames.askSupervisorForm })
    }

    /// Without a row here the tool exists, resolves and runs — and cannot be granted through
    /// the Role editor at all, because the Tools tab renders THIS array.
    func testAppearsInTheSupervisorDisplayCategory() {
        let supervisor = ToolConstants.displayCategories.first { $0.id == "supervisor" }
        XCTAssertEqual(supervisor?.tools, [ToolNames.askSupervisor, ToolNames.askSupervisorForm])
    }

    // MARK: - Saying WHERE the JSON broke

    /// Foundation answers every syntax defect with the same sentence — "The given data was
    /// not valid JSON." — which tells the model that something, somewhere, is wrong. Given
    /// only that, it re-emits all 2 KB and gets another chance to slip. The offset is in the
    /// underlying error, and quoting the bytes around it turns a re-write into an edit.
    ///
    /// RED: drop the `in:` argument at the call site → the message is the bare sentence again.
    func testASyntaxErrorQuotesTheTextWhereTheParserStopped() async {
        let result = await run([
            "headline": "M20 clarifications", "form": Self.brokenFormFromTheLiveRun,
        ])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("The parser stopped at character"),
                      result.outputJSON)
        // The excerpt has to straddle the slip: the closed question before it and the
        // orphaned key after it, or it points at the right offset and shows the wrong thing.
        XCTAssertTrue(result.outputJSON.contains("prompt"), result.outputJSON)
    }

    /// A VALIDATION failure already names its own coding path, and it parsed — so quoting
    /// bytes at offset zero would point at a place that was fine.
    func testAValidationErrorStillNamesItsPathAndNotAByteOffset() async {
        let form = #"{"questions":[{"prompt":"Pick","kind":"single_choice","options":[]}]}"#
        let result = await run(["headline": "One question", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("at `questions"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("The parser stopped"), result.outputJSON)
    }

    /// The live shape of run 9 is READ now, not refused: the `«` that opened a string is a
    /// standard spelling of a valid intent (playbook R1.8.4), the parser accepts the form the
    /// model emits (R3.8.7), and the rewrite is reported in the result (REC.5) so the model
    /// learns what was read without paying a round trip for it.
    ///
    /// RED: decode the raw text only → `isError`, and the excerpt names character 854.
    func testTheLiveGuillemetForm_isReadAsJSON_andTheRepairIsReported() async throws {
        let result = await run([
            "headline": "Уточнения по редизайну", "form": Self.guillemetFormFromTheLiveRun,
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(inquiry.questions.count, 3)
        XCTAssertEqual(inquiry.questions[1].options[2].label, "Без правок по теням")
        XCTAssertEqual(try warnings(in: result), [SupervisorFormTextRepair.requotedNote(count: 1)])
    }

    /// A syntax failure the repair cannot close still quotes the stop in CHARACTERS — the
    /// window used to be cut at a BYTE offset, which in Cyrillic lands inside a letter and
    /// silently produced no excerpt at all (run 9: the model guessed "escaping", then "curly
    /// quotes"). The fixture opens a string with `«` and never closes it: the repair keeps
    /// what precedes it and the parser stops ON it.
    ///
    /// RED: cut the window on the UTF-8 view again → this excerpt is nil and only the bare
    /// sentence ships, while the ASCII fixture above keeps passing.
    func testAGuillemetTheRepairCannotClose_stillQuotesWhereTheParserStopped_inCharacters() async {
        let form = #"{"questions": [{"prompt": "Что сделать в первую очередь?", "kind": "free_text"}, {"prompt": «Добавлять ли тени"#
        let stop = form.distance(from: form.startIndex, to: form.range(of: "«")!.lowerBound)
        let result = await run(["headline": "Уточнения по редизайну", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("The parser stopped at character \(stop),"),
                      "counted in characters, not Foundation's bytes (\(form.utf8.count - form.suffix(from: form.range(of: "«")!.lowerBound).utf8.count)): \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("on '«'"),
                      "the character it stopped on, named — Foundation prints its first byte as 'Â': \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("▶«Добавлять ли тени"),
                      "the excerpt straddles the slip and marks it: \(result.outputJSON)")
    }

    /// Typographic quotes INSIDE a `"`-string are content, and content is never rewritten —
    /// a valid form comes through byte-for-byte with no repair warning.
    func testAValidForm_isNeverRewritten_andCarriesNoRepairWarning() async throws {
        let form = #"{"questions":[{"prompt":"Тема «медитация» или «сон»?","kind":"free_text"}]}"#
        let result = await run(["headline": "H", "form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else { return XCTFail() }
        XCTAssertEqual(inquiry.questions[0].prompt, "Тема «медитация» или «сон»?")
        XCTAssertEqual(try warnings(in: result), [])
    }

    /// Run 11 ended every attempt with one `}` too many; the top-level object had closed.
    func testExtraClosingBraceAfterTheForm_isIgnoredAndReported() async throws {
        let result = await run(["headline": "H", "form": Self.validForm + "}"])
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try warnings(in: result), [SupervisorFormTextRepair.droppedClosersNote(count: 1)])
    }


    // MARK: - Option labels

    /// `"(recommended)"` in a label beside the RECOMMENDED badge, and `"1. "` beside a radio
    /// button (runs 10 and 11): read as the intent and reported, on both argument shapes —
    /// the pass runs after decoding, so the parsed-object branch gets it too.
    func testRecommendedMarkerInALabel_isNormalizedAndReported() async throws {
        let form = #"{"questions":[{"prompt":"Which?","kind":"single_choice","options":[{"label":"1. Debug (recommended)"},{"label":"2. Release"}]}]}"#
        let result = await run(["headline": "H", "form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else { return XCTFail() }
        XCTAssertEqual(inquiry.questions[0].options.map(\.label), ["Debug", "Release"])
        XCTAssertEqual(inquiry.questions[0].recommendedOption?.label, "Debug")
        XCTAssertEqual(try warnings(in: result), [
            SupervisorInquiryLabelRepair.enumerationNote(count: 2),
            SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 1),
        ])
    }

    func testRecommendedMarkerInAParsedObject_isNormalizedToo() async throws {
        let form: [String: Any] = ["questions": [
            ["prompt": "Which?", "kind": "single_choice",
             "options": [["label": "Debug"], ["label": "Release (recommended)"]]],
        ]]
        let result = await run(["headline": "H", "form": form])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else { return XCTFail() }
        XCTAssertEqual(inquiry.questions[0].options.map(\.label), ["Debug", "Release"],
                       "the model's order is the model's, and a badge does not reorder it")
        XCTAssertEqual(inquiry.questions[0].recommendedOption?.label, "Release")
        XCTAssertEqual(try warnings(in: result), [
            SupervisorInquiryLabelRepair.recommendedMarkerNote(count: 1),
        ])
    }

    // MARK: - The recommendation, as a design questionnaire actually carries it

    /// Verbatim from MeditationApp task 86 run 1 (2026-09-12, `ornith-1.5:35b`) — what the
    /// Supervisor was shown for «хочу сделать редизайн, предложи варианты, используй
    /// ask_supervisor_form, проект не смотри». Three choice questions, nine options, a
    /// `detail` on every single one of them — and not one of the nine a recommendation. Sent
    /// as a nested OBJECT, carrying a `detail_secondary` key the schema never named.
    ///
    /// It is pinned because it is the ORDINARY case and the one the card is quietest about:
    /// told not to open the project, the model has nothing to base a recommendation on, and
    /// asked which visual direction the human prefers it has no basis at all. Until
    /// 2026-09-12 this very payload badged three options — the first of each question — and
    /// the Supervisor read three recommendations nobody had made.
    ///
    /// The nine details are also the whole false-positive surface: every one of them opens
    /// with a word describing the option, and the anchor has to let all nine through.
    private static let designFormFromTheLiveRun = #"""
    {"questions":[
      {"id":"goal","kind":"single_choice","options":[{"detail":"Сменить цвета, типографику, закругления, тёмную тему — сделать более актуально","detail_secondary":"","label":"Обновить визуал и современный стиль"},{"detail":"Переделать расположение вкладок, сократить число тапов, упростить путь к медитации","detail_secondary":"","label":"Улучшить UX и навигацию"},{"detail":"Конкретно SessionPlayer, Library, Breathing — заново продумать компоновку и элементы","detail_secondary":"","label":"Переработать ключевые экраны"},{"detail":"Системное изменение структуры views и состояния, не только косметика","detail_secondary":"","label":"Обработать всю архитектуру экранов"}],"prompt":"Какая цель редизайна в первую очередь?"},
      {"id":"scope","kind":"single_choice","options":[{"detail":"Только цвета/шрифты/отступы, структура экранов та же","detail_secondary":"","label":"Минимальные правки"},{"detail":"Переделать отдельные экраны, сохранить общую логику и навигацию","detail_secondary":"","label":"Средние"},{"detail":"Свободное переосмысление экранов — можно менять структуру и взаимодействие","detail_secondary":"","label":"Максимальные"}],"prompt":"Насколько радикальными могут быть изменения?"},
      {"id":"output","kind":"single_choice","options":[{"detail":"По каждой — краткое описание визуала, что меняется и почему","detail_secondary":"","label":"Да, дай 2–3 концепции"},{"detail":"Предложи один вариант и приступай к правкам","detail_secondary":"","label":"Сразу к реализации"}],"prompt":"Нужно ли сначала предложить несколько концепций на выбор?"}
    ]}
    """#

    /// The field payload, as the object the model sent — optionally with the recommend-word
    /// put in front of ONE detail, which is the only difference between a form that badges
    /// nothing and a form that badges one option.
    private func designForm(recommending detail: String? = nil) throws -> [String: Any] {
        var text = Self.designFormFromTheLiveRun
        if let detail {
            let recommended = "Рекомендую — " + detail
            XCTAssertTrue(text.contains(detail), "the detail to mark is not in the payload")
            text = text.replacingOccurrences(of: detail, with: recommended)
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// RED: restore `recommendedOption` to `options.first` → three badges appear on a
    /// questionnaire whose model recommended nothing.
    func testTheLiveDesignForm_recommendsNothing() async throws {
        let result = await run(["headline": "Редизайн", "form": try designForm()])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else { return XCTFail() }
        XCTAssertEqual(inquiry.questions.count, 3)
        XCTAssertEqual(inquiry.questions.compactMap(\.recommendedOptionID), [],
                       "nine descriptive details and no recommendation among them")
        XCTAssertEqual(inquiry.questions[0].options.map(\.label), [
            "Обновить визуал и современный стиль",
            "Улучшить UX и навигацию",
            "Переработать ключевые экраны",
            "Обработать всю архитектуру экранов",
        ], "the model's order, untouched — nothing was marked, so nothing moved")
        XCTAssertEqual(try warnings(in: result), [])
    }

    /// The same nine options with one word added in front of one detail — the word the same
    /// model wrote unprompted on the one question of this shape that has an engineering
    /// answer rather than a taste (task 88 run 1, «Recommended. Переделать представления…»).
    ///
    /// RED: anchor the recommend-word anywhere in the detail instead of at its start → the
    /// other two questions start resolving off details that merely mention one.
    func testTheSameFormWithOneStatedRecommendation_badgesThatOptionAlone() async throws {
        let stated = "Только цвета/шрифты/отступы, структура экранов та же"
        let result = await run([
            "headline": "Редизайн", "form": try designForm(recommending: stated),
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else { return XCTFail() }
        XCTAssertEqual(inquiry.questions[1].recommendedOption?.label, "Минимальные правки")
        XCTAssertNil(inquiry.questions[0].recommendedOptionID, "one question said it, not three")
        XCTAssertNil(inquiry.questions[2].recommendedOptionID)
        XCTAssertEqual(inquiry.questions[1].options.map(\.label),
                       ["Минимальные правки", "Средние", "Максимальные"],
                       "the badge resolves in place and reorders nothing")
        XCTAssertEqual(inquiry.questions[1].options[0].detail, "Рекомендую — " + stated,
                       "the model's reason is left whole; the badge summarises it")
        XCTAssertEqual(try warnings(in: result), [],
                       "reading a recommendation rewrites nothing, so it reports nothing")
    }

    // MARK: - A dropped closer, and where the repair stops

    /// One `}` short, 557 characters in: the form carries three whole questions and the
    /// model has to re-emit none of them. The repair is the house one — bounded to a single
    /// closer, adopted only because the decode then succeeds (playbook REC.5).
    ///
    /// RED: drop the closer arm from the handler's ladder → `isError`, and the message
    /// quotes character 560.
    func testTheLiveDroppedCloserForm_isReadAsThreeQuestions_andTheRepairIsReported() async throws {
        let result = await run([
            "headline": "Редакция дизайна", "form": Self.droppedCloserFormFromTheLiveRun,
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(inquiry.questions.count, 3)
        XCTAssertEqual(inquiry.questions[1].options.count, 3)
        XCTAssertEqual(try warnings(in: result), [SupervisorFormTextRepair.insertedCloserNote])
    }

    /// The same step's next call: the closer repair makes it PARSE, and what it parses into
    /// is a choice offering one answer — the second option was never written. Syntax is not
    /// completeness, so the validator refuses it rather than parking a choiceless choice on
    /// the human.
    ///
    /// RED: delete the completeness check → this parks, `isError` is false, and the human is
    /// asked to choose between one thing.
    func testTheLiveTruncatedForm_isRefused_ratherThanParkedAsAChoiceWithOneAnswer() async throws {
        let result = await run([
            "headline": "Редакция дизайна", "form": Self.truncatedFormFromTheLiveRun,
        ])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try diagnosis(in: result), "too_few_options")
        let message = try message(in: result)
        XCTAssertTrue(message.contains("Question 1"), message)
        XCTAssertTrue(message.contains("free_text"), message)
    }

    // MARK: - What the message leads with

    /// A repair that WORKED is not a diagnosis. Read as the first sentence of a refusal it
    /// is a false one, and the model acts on it: on 2026-09-11 it answered a refusal whose
    /// real fault was an unclosed object with "The curly quotes « » and “ ” are breaking the
    /// parser" and rewrote every string in ASCII (playbook R1.8.1, R1.8.5).
    ///
    /// RED: compose the message as `notes + fault` again → the repair sentence is first and
    /// the fault no longer opens the message.
    func testARefusalAfterARepair_leadsWithTheFault_andMarksTheRepairAsNotTheCause() async throws {
        let form = #"{"questions": [{"prompt": «Какой?», "kind": "free_text"} {"prompt": "Второй", "kind": "free_text"}]}"#
        let result = await run(["headline": "H", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        let message = try message(in: result)
        let fault = try XCTUnwrap(message.range(of: "The parser stopped at character"))
        let repair = try XCTUnwrap(message.range(of: "1 string(s) were quoted with"))
        XCTAssertTrue(fault.lowerBound < repair.lowerBound,
                      "the fault opens the message, the repair follows it: \(message)")
        XCTAssertTrue(message.contains("not the cause"), message)
        XCTAssertTrue(message.contains(#"▶{"prompt": "Второй"#),
                      "cut from the repaired text: \(message)")
    }

    /// One code, five states, each with its own recovery — so each names itself in
    /// `error.details.diagnosis` (playbook R1.8.5, R3.5.3; the `edit_file` precedent).
    ///
    /// RED: send one `diagnosis` value for every arm → the first four rows fail together.
    func testEachRefusalNamesItsOwnState() async throws {
        let cases: [(String, Any)] = [
            ("not_json", #"{"questions": [{"prompt": "A", "kind": "free_text"} {"prompt": "B"}]}"#),
            ("not_json_after_repair",
             #"{"questions": [{"prompt": «Какой?», "kind": "free_text"} {"prompt": "Второй", "kind": "free_text"}]}"#),
            ("question_rejected",
             #"{"questions":[{"prompt":"Pick","kind":"single_choice","options":[]}]}"#),
            ("too_few_options",
             #"{"questions":[{"prompt":"Pick","kind":"single_choice","options":[{"label":"Only"}]}]}"#),
            ("unrepresentable_value", ["questions": [["prompt": Double.nan]]] as [String: Any]),
        ]
        for (expected, form) in cases {
            let result = await run(["headline": "H", "form": form])
            XCTAssertTrue(result.isError, "\(expected): \(result.outputJSON)")
            XCTAssertEqual(try diagnosis(in: result), expected, result.outputJSON)
        }
    }

    /// A repair that worked does not make the next failure a syntax one: text whose « » were
    /// read can still be REFUSED by the decoder, and that state is `question_rejected` with a
    /// coding path — sending the model to hunt a character in it would be the same false
    /// diagnosis one rung further on.
    ///
    /// RED: derive the state from `spelling.changed` → this reports `not_json_after_repair`
    /// for an error that names `questions[0].options`.
    func testARepairedFormRefusedByTheDecoder_namesTheValidationState() async throws {
        let form = #"{"questions":[{"prompt": «Какой?», "kind":"single_choice","options":[]}]}"#
        let result = await run(["headline": "H", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try diagnosis(in: result), "question_rejected")
        let message = try message(in: result)
        XCTAssertTrue(message.contains("at `questions"), message)
        XCTAssertFalse(message.contains("The parser stopped"), message)
        XCTAssertTrue(message.contains("not the cause"), "the repair still rides, after the fault: \(message)")
    }

    /// The completeness rule reaches the parsed-object branch too — a provider that loosens
    /// the declared `string` type must not buy a laxer validator with it.
    func testAChoiceWithOneOption_isRefusedOnTheParsedObjectBranchAsWell() async throws {
        let form: [String: Any] = ["questions": [
            ["prompt": "Which?", "kind": "multi_choice", "options": [["label": "Only"]]],
        ]]
        let result = await run(["headline": "H", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try diagnosis(in: result), "too_few_options")
    }

    // MARK: - The shapes a model reaches for when the schema is read loosely

    /// The form's CONTENT written straight into the arguments — the shape the description's
    /// old example taught, and the ONE emission of the 2026-09-12 field runs that was
    /// syntactically flawless on its first try. It was refused for a missing `form`; five
    /// well-formed questions were discarded and hand-rewritten twice (MeditationApp task 71
    /// run 4, `ornith-1.5:35b`).
    ///
    /// RED: drop the `questions`-at-top-level arm → `INVALID_ARGS`, and the questionnaire the
    /// model actually wrote is thrown away over an envelope key.
    func testAcceptsTheQuestionnaireWrittenStraightIntoTheArguments() async {
        let result = await run([
            "headline": "Что делаем дальше",
            "questions": [
                ["prompt": "Какой камень берём?", "kind": "single_choice",
                 "options": [["label": "M19", "detail": "по плану"], ["label": "Виджеты"]]],
                ["prompt": "Что ещё стоит учесть?", "kind": "free_text"],
            ],
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(headline, "Что делаем дальше")
        XCTAssertEqual(inquiry.questions.count, 2)
        XCTAssertEqual(inquiry.questions.first?.options.first?.label, "M19",
                       "the recommendation is a position, and the lift must not reorder it")
    }

    /// A `form` that arrived but is neither shape. "Missing" about an argument the model just
    /// sent it hunting for a phantom omission instead of fixing the type — which is exactly
    /// what `ToolArgumentError.invalidValue` exists to prevent.
    ///
    /// RED: fall through to `.missingRequired` → the message names an absence that is not one.
    func testAFormOfTheWrongTypeIsReportedAsTheWrongType() async throws {
        // A String of any content — the empty one included — is the STRING arm's, not this
        // one's; it is a decode failure about the form, and has its own test below.
        for (value, expected) in [
            (42 as Any, "a number"),
            ([["prompt": "A", "kind": "free_text"]] as Any, "an array"),
            (true as Any, "a boolean"),
            (NSNull() as Any, "null"),
        ] {
            let result = await run(["headline": "H", "form": value])
            XCTAssertTrue(result.isError, "\(expected): \(result.outputJSON)")
            let text = try message(in: result)
            XCTAssertTrue(text.contains("received \(expected)"),
                          "should name the type that arrived — got: \(text)")
            XCTAssertFalse(text.contains("Missing required argument"),
                           "should not report an absence for an argument that arrived: \(text)")
        }
    }

    /// The empty string is the one "wrong type" that is still a String: it reaches the string
    /// arm, fails to decode, and must stay a form diagnosis rather than an argument one.
    func testAnEmptyFormStringIsADecodeFailure_notAMissingArgument() async throws {
        let result = await run(["headline": "H", "form": ""])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try diagnosis(in: result), "not_json", result.outputJSON)
    }

    /// Absent for real — the one case that IS a missing argument.
    func testANoFormCallStillReportsAMissingArgument() async throws {
        let result = await run(["headline": "H"])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(try message(in: result).contains("Missing required argument: form"),
                      result.outputJSON)
    }

    /// Both keys is ambiguous: `form` is the declared one and wins, and the stray `questions`
    /// must not be folded in beside it.
    func testAnExplicitFormWinsOverAStrayQuestionsKey() async {
        let result = await run([
            "headline": "H",
            "form": ["questions": [["prompt": "From form", "kind": "free_text"]]],
            "questions": [["prompt": "From the stray key", "kind": "free_text"]],
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal")
        }
        XCTAssertEqual(inquiry.questions.map(\.prompt), ["From form"])
    }

    /// A top-level `questions` that is not an array is not the lift's shape — it falls through
    /// to the missing-argument arm rather than being handed to the decoder as a document.
    func testATopLevelQuestionsThatIsNotAnArrayIsNotLifted() async throws {
        let result = await run(["headline": "H", "questions": "three of them"])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(try message(in: result).contains("Missing required argument: form"),
                      result.outputJSON)
    }

    private func diagnosis(in result: ToolExecutionResult) throws -> String? {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        return (error["details"] as? [String: String])?["diagnosis"]
    }

    private func message(in result: ToolExecutionResult) throws -> String {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        return try XCTUnwrap(error["message"] as? String)
    }

    private func warnings(in result: ToolExecutionResult) throws -> [String] {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        return try XCTUnwrap((envelope["meta"] as? [String: Any])?["warnings"] as? [String])
    }

    // MARK: - The form's own closing bracket

    /// The live shape of MeditationApp task 67 run 1: 1931 characters in which the model
    /// closed everything it opened except the document itself. The form is READ, in the
    /// language it was written in, on the first call.
    ///
    /// RED: drop the tail rung from the ladder → the three-call round trip comes back, and
    /// with it the questionnaire the model translated into English to appease an error that
    /// was never about its characters.
    func testTheLiveUnclosedForm_isReadWithItsOwnCloserPutBack() async throws {
        let result = await run([
            "headline": "Дизайн", "form": Self.unclosedFormFromTheLiveRun,
        ])
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(_, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(inquiry.questions.count, 5)
        XCTAssertEqual(inquiry.questions[0].options.count, 5)
        XCTAssertEqual(inquiry.questions[0].options[0].label, "Минимализм + дыхание")

        // The recommendation, read from this very payload — the reason the reader exists.
        // Three of its four choice questions open an option's `detail` with «Рекомендую», and
        // ONE of those is not the first option: "Какой объём экранов перерабатываем?" lists
        // the full redesign first and recommends the narrower scope second (KNOWN_ISSUES A32).
        // Until 2026-09-12 the card badged the first option of all four, so it marked the
        // four-screen redesign the model had argued against and invented a recommendation for
        // the question that states none.
        XCTAssertNil(
            inquiry.questions[0].recommendedOption,
            "the model recommended no design direction, so nothing is marked")
        XCTAssertEqual(
            inquiry.questions[2].recommendedOption?.label,
            "Library + Player (основной путь)",
            "option index 1, not 0 — the question that A32 was filed for")
        XCTAssertEqual(try warnings(in: result), [
            SupervisorFormTextRepair.closedTheFormNote,
        ])
    }

    /// The note names WHICH bracket, because the two closer rungs recover different things
    /// and a model told only "a bracket was missing" learns nothing about where it slips.
    func testTheTwoCloserRepairs_reportThemselvesApart() {
        XCTAssertNotEqual(
            SupervisorFormTextRepair.closedTheFormNote,
            SupervisorFormTextRepair.insertedCloserNote)
    }

    /// Two containers open at the end is not the frame missing — it is a question the model
    /// was still writing. Closing it would hand the Supervisor a questionnaire that stops
    /// early and reads as whole (CLAUDE.md #293), so it is refused.
    ///
    /// RED: bound the tail rung by `maxDroppedClosers` instead of by ONE → this parks a form
    /// carrying one of the questions the model meant to ask.
    func testAFormAbandonedInsideItsQuestions_isRefused() async throws {
        let form = #"{"questions": [{"prompt": "Which scheme?", "kind": "free_text"}"#
        let result = await run(["headline": "H", "form": form])
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try diagnosis(in: result), "not_json")
        let message = try message(in: result)
        XCTAssertTrue(message.contains("`]}` still owed"), message)
        XCTAssertTrue(message.contains("free_text"), "the tail is quoted after the fault: \(message)")
    }

    /// And it is NOT told to append them. The one tail where appending is safe never reaches
    /// this message — the ladder put that bracket back and the form was read — so a refusal
    /// naming brackets to add would be asking the model to perform by hand the laundering the
    /// repair declines (CLAUDE.md #293): the result parses, and the completeness validator
    /// reads choices only, so a `free_text` question the model never finished disappears.
    ///
    /// RED: answer this state with "append `]}` to it" → the model appends, the form parks
    /// with the question it was mid-way through writing silently gone, and the Supervisor
    /// answers a questionnaire nobody wrote.
    func testAFormAbandonedInsideItsQuestions_isNeverToldToAppendTheBrackets() async throws {
        let result = await run([
            "headline": "H",
            "form": #"{"questions": [{"prompt": "Which scheme?", "kind": "free_text"}"#,
        ])
        let message = try message(in: result)
        XCTAssertFalse(message.contains("append"), message)
        XCTAssertTrue(message.contains("Send the whole form again"), message)
    }

    /// A text that breaks off before its last value is finished says so, and takes the same
    /// recovery. R1.8.5 — one code, and each state names its own fault whole.
    func testAFormThatBreaksOffMidValue_isToldToSendItAgain() async throws {
        let result = await run([
            "headline": "H", "form": #"{"questions": [{"prompt": "Which sch"#,
        ])
        XCTAssertTrue(result.isError, result.outputJSON)
        let message = try message(in: result)
        XCTAssertTrue(message.contains("before its last value is finished"), message)
        XCTAssertFalse(message.contains("append"), message)
    }

    /// The fault leads. Foundation's constant sentence said nothing the code and the caller's
    /// own prefix had not already said, and it pushed the sentence that names the fault into
    /// third place — behind an excerpt of Cyrillic the model then diagnosed instead (R1.8.1).
    ///
    /// RED: put `ctx.debugDescription` back in front of the excerpt → the message opens with
    /// two sentences of nothing.
    func testASyntaxRefusal_doesNotOpenWithFoundationsConstantSentence() async throws {
        let result = await run([
            "headline": "H", "form": Self.brokenFormFromTheLiveRun,
        ])
        XCTAssertTrue(result.isError, result.outputJSON)
        let message = try message(in: result)
        XCTAssertFalse(message.contains("The given data was not valid JSON"), message)
        XCTAssertTrue(message.hasPrefix("Invalid form: The parser stopped at character"), message)
    }
}
