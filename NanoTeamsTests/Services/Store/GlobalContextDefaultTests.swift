import XCTest

@testable import NanoTeams

/// `AppDefaults.globalContext` is injected into the system prompt of EVERY
/// tool-loop role on EVERY request, so its exact shape is a production concern.
/// These pins protect three things: the rule keeps shipping and stays a BARE
/// rule, installs pinned to a retired default get unpinned, and nothing the user
/// actually chose is ever discarded.
///
/// Why it ships at all: local models batch tool calls without it (observed on
/// `qwen3.6`), so a future "the slot belongs to the user" cleanup must not quietly
/// empty it — `testGlobalContextDefault_shipsTheOneToolRule` is that tripwire.
///
/// Why it is BARE: both retired values stated the rule and then revoked it on a
/// predicate the model had to judge each turn ("2–3 genuinely independent reads").
/// A measured Autovisor turn spent 1520 output tokens and five verbatim reversals
/// deciding nothing, then degenerated into a repetition loop on the next turn.
/// These pins exist because a future prompt-compression pass would naturally
/// re-invent an escape clause — including the subtler form, a RATIONALE, from
/// which the model simply derives the exception back.
@MainActor
final class GlobalContextDefaultTests: XCTestCase {

    private var storage: InMemoryStorage!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryStorage()
    }

    override func tearDown() async throws {
        storage = nil
        try await super.tearDown()
    }

    /// Fresh storage seeded with a stored value, plus the config that read it.
    /// The purge runs in `init`, so every case needs its own storage instance.
    private func loadConfig(stored: String) -> (config: StoreConfiguration, storage: InMemoryStorage) {
        let storage = InMemoryStorage()
        storage.set(stored, forKey: UserDefaultsKeys.globalContext)
        return (StoreConfiguration(storage: storage), storage)
    }

    // MARK: - What the app ships

    /// The rule must actually ship. Without it local models batch tool calls
    /// (observed on `qwen3.6`), so an empty default is a silent behaviour
    /// regression, not a tidy-up.
    func testGlobalContextDefault_shipsTheOneToolRule() {
        let text = AppDefaults.globalContext

        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "emptying this ships no tool-call discipline at all — read the constant's doc first")
        XCTAssertTrue(
            text.lowercased().contains("one tool"),
            "the rule the whole constant exists for must survive any rewrite")
    }

    /// One rule, nothing to adjudicate. Both an explicit exception and a stated
    /// reason reopen the argument, so both are banned. This is the pin that keeps
    /// a compression pass from re-introducing `Exception: 2–3 …`.
    func testGlobalContextDefault_statesOneRuleWithNoEscapeClause() {
        let text = AppDefaults.globalContext

        for banned in ["exception", "independent", "at most", "unless", "except"] {
            XCTAssertFalse(
                text.lowercased().contains(banned),
                "'\(banned)' reopens the rule the model must otherwise just follow")
        }
        XCTAssertFalse(
            text.lowercased().contains("cannot see"),
            "a rationale is an exception the model derives instead of reads")
        XCTAssertFalse(
            text.contains("\n"),
            "a second line is where the revocation historically lived")
    }

    /// Ties the default's VALUE to its rendered CONSEQUENCE across the real
    /// templates, so neither half can regress alone: the shipped rule must reach
    /// the prompt under an intact `## Global guidance` header.
    func testShippedDefault_rendersUnderTheGlobalGuidanceHeader() {
        for (name, template) in [
            ("software", SystemTemplates.softwareTemplate),
            ("generic", SystemTemplates.genericTemplate),
            ("autovisor", SystemTemplates.autovisorTemplate),
        ] {
            let resolved = render(template, globalContext: AppDefaults.globalContext)

            XCTAssertTrue(
                resolved.contains("## Global guidance"),
                "[\(name)] the shipped rule must not be stripped as an empty section")
            XCTAssertTrue(
                resolved.contains(AppDefaults.globalContext),
                "[\(name)] the rule text itself must reach the prompt")
            XCTAssertEqual(
                resolved.components(separatedBy: "## Global guidance").count - 1, 1,
                "[\(name)] exactly one section — the chip must suppress the legacy auto-append")
        }
    }

    /// Clearing the field is a supported choice, and it must cost nothing: the
    /// chip resolves to "" and `stripOrphanHeaders` removes the now-bodyless
    /// header rather than shipping it. Pinned separately from the default so the
    /// two can regress independently.
    func testClearedGlobalContext_rendersNoGlobalGuidanceSection() {
        for (name, template) in [
            ("software", SystemTemplates.softwareTemplate),
            ("generic", SystemTemplates.genericTemplate),
            ("autovisor", SystemTemplates.autovisorTemplate),
        ] {
            let resolved = render(template, globalContext: "")

            XCTAssertFalse(
                resolved.contains("## Global guidance"),
                "[\(name)] an empty value must strip the header, not ship it bodyless")
        }
    }

    /// The Autovisor's standing memory rides the globalContext channel and opens
    /// with its OWN `##` header. Mirrors the composition in
    /// `LLMExecutionService+ConversationManagement`; pinned because the resulting
    /// prompt shape is invisible from either side alone.
    func testAutovisorMemory_composesUnderTheShippedDefault() {
        let block = "## Current Memory (your standing notes from prior reviews)\nReviewed 3 tasks."
        let composed = AppDefaults.globalContext.isEmpty
            ? block
            : AppDefaults.globalContext + "\n\n" + block

        let resolved = render(SystemTemplates.autovisorTemplate, globalContext: composed)

        XCTAssertTrue(
            resolved.contains("## Current Memory"),
            "the manager's memory must reach the prompt")
        XCTAssertTrue(
            resolved.contains(AppDefaults.globalContext),
            "the shipped rule must survive being concatenated with the memory block")
    }

    /// Shared render helper — exercises the same two-argument shape production
    /// uses (chip placeholder AND the auto-append argument), so a test can't
    /// accidentally pass by feeding only one of them.
    private func render(_ template: String, globalContext: String) -> String {
        TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: ["globalContext": PromptBuilder.formatGlobalContext(globalContext)],
            globalContext: globalContext
        )
    }

    // MARK: - The retired roster

    /// Byte-exact matching is the migration's only safety property, so the
    /// literals must keep their exact bytes. V0 is the trap: EM dashes (U+2014)
    /// in the prose but plain HYPHENS in `2-3` / `5-9` — the opposite of V1's
    /// en dash (U+2013). A wrong dash is a purge that silently never fires.
    func testRetiredDefaults_keepTheirExactBytes() {
        XCTAssertTrue(
            AppDefaults.retiredGlobalContextV0.unicodeScalars.contains("\u{2014}"),
            "V0's prose dashes are EM dashes")
        XCTAssertTrue(
            AppDefaults.retiredGlobalContextV0.contains("2-3 genuinely independent reads"),
            "V0 spells the range with a plain hyphen, unlike V1")
        XCTAssertFalse(
            AppDefaults.retiredGlobalContextV0.unicodeScalars.contains("\u{2013}"),
            "an en dash anywhere in V0 means it was retyped, not copied from git")

        XCTAssertTrue(
            AppDefaults.retiredGlobalContextV1.unicodeScalars.contains("\u{2013}"),
            "V1's range is an EN dash")
    }

    /// Both retired texts are exactly the thing the current default replaced: they
    /// carry the escape clause. If a retired literal ever passed the
    /// no-escape-clause pin, it would not have needed retiring.
    func testRetiredDefaults_areTheOnesCarryingTheEscapeClause() {
        for retired in AppDefaults.retiredGlobalContextDefaults {
            XCTAssertTrue(
                retired.lowercased().contains("exception"),
                "a retired default without the escape clause is a retirement with no reason")
        }
    }

    /// The roster is the purge's entire input — a literal missing from it is an
    /// install that stays pinned forever. V0 shipped 2026-05-03 and was left out
    /// until 2026-07-27 for exactly the want of this assertion.
    func testRetiredRoster_listsEveryRetiredDefault() {
        XCTAssertEqual(
            AppDefaults.retiredGlobalContextDefaults,
            [
                AppDefaults.retiredGlobalContextV0,
                AppDefaults.retiredGlobalContextV1,
            ],
            "retiring a default means adding its literal here in the SAME commit")
    }

    /// A live default in the roster would fight itself: the purge would delete the
    /// stored copy on every launch. An `""` entry is worse — it would delete the
    /// stored key of every user who deliberately CLEARED the field, converting a
    /// choice into "never touched" and resurrecting the default for them.
    func testRetiredRoster_excludesTheCurrentDefaultAndEmpty() {
        XCTAssertFalse(
            AppDefaults.retiredGlobalContextDefaults.contains(AppDefaults.globalContext),
            "purging the current default would fight the default")
        XCTAssertFalse(
            AppDefaults.retiredGlobalContextDefaults.contains(""),
            "an empty roster entry converts every deliberate clear into never-touched")
        XCTAssertEqual(
            Set(AppDefaults.retiredGlobalContextDefaults).count,
            AppDefaults.retiredGlobalContextDefaults.count,
            "a duplicate is a copy-paste that probably meant to add a NEW literal")
    }

    // MARK: - Reaching existing installs

    /// An install that never touched the setting has no stored key (the `init`
    /// fallback does not persist — `didSet` never fires during `init`), so it
    /// follows the shipped default for free.
    func testUntouchedInstall_followsTheShippedDefault_andStoresNoKey() {
        let config = StoreConfiguration(storage: storage)

        XCTAssertEqual(config.globalContext, AppDefaults.globalContext)
        XCTAssertNil(
            storage.object(forKey: UserDefaultsKeys.globalContext),
            "the init fallback must not persist, or the next default change can't reach this install")
    }

    /// The cohort the purge exists for: every install that clicked the old "Reset
    /// to Default" button or ran `resetToDefaults()` while both ASSIGNED the
    /// then-current default and persisted a copy through `didSet`. Removing the
    /// KEY — not overwriting it with today's default — is what makes the install
    /// follow FUTURE defaults too.
    func testEveryRetiredDefault_isPurged_keyAndAll() {
        for retired in AppDefaults.retiredGlobalContextDefaults {
            let (config, storage) = loadConfig(stored: retired)

            XCTAssertEqual(
                config.globalContext, AppDefaults.globalContext,
                "a stored copy of a shipped default is a copy, never a choice")
            XCTAssertNil(
                storage.object(forKey: UserDefaultsKeys.globalContext),
                "overwriting instead of removing re-pins the install to today's default")
        }
    }

    /// The safety property of matching byte-exactly: anything the user actually
    /// wrote is untouched, including near-misses on every retired text.
    func testCustomGlobalContext_isNeverPurged() {
        let survivors = [
            "Always run the build before you report.",
            // Near-miss on V0: em dashes flattened to hyphens.
            AppDefaults.retiredGlobalContextV0.replacingOccurrences(of: "\u{2014}", with: "-"),
            // Near-miss on V1: same words, hyphen instead of the en dash.
            AppDefaults.retiredGlobalContextV1.replacingOccurrences(of: "\u{2013}", with: "-"),
            // Near-miss on the CURRENT default: same sentence, no full stop. Must
            // survive both the purge (not retired) and any equality shortcut.
            AppDefaults.globalContext.replacingOccurrences(of: ".", with: ""),
        ]

        for value in survivors {
            let (config, _) = loadConfig(stored: value)

            XCTAssertEqual(
                config.globalContext, value,
                "only a byte-exact match is provably a copy of a shipped default")
        }
    }

    /// A deliberately emptied field is a CHOICE. Both halves matter: the value
    /// must stay empty (the purge must not resurrect the default) AND the key must
    /// survive, because key presence is the only thing separating "cleared" from
    /// "never touched" — and only the latter should follow a future default.
    func testDeliberatelyClearedField_keepsItsValueAndItsStoredKey() {
        let (config, storage) = loadConfig(stored: "")

        XCTAssertEqual(
            config.globalContext, "",
            "the purge must not resurrect the default over a deliberate clear")
        XCTAssertNotNil(
            storage.object(forKey: UserDefaultsKeys.globalContext),
            "clearing must stay distinguishable from never-touched, or the next "
                + "default change would resurrect itself in this install")
    }

    /// Idempotent: the second launch has nothing to purge and must not disturb the
    /// state the first launch settled on.
    func testPurge_isIdempotentAcrossLaunches() {
        storage.set(AppDefaults.retiredGlobalContextV1, forKey: UserDefaultsKeys.globalContext)

        _ = StoreConfiguration(storage: storage)
        let second = StoreConfiguration(storage: storage)

        XCTAssertEqual(second.globalContext, AppDefaults.globalContext)
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.globalContext))
    }

    // MARK: - Reset

    /// `resetToDefaults()` removes the key and then restores the default — and a
    /// bare assignment's `didSet` would write a copy straight back. Dropping the
    /// key after the assignment is what keeps a reset install following FUTURE
    /// defaults instead of joining the pinned cohort.
    func testResetToDefaults_leavesNoStoredGlobalContextKey() {
        let config = StoreConfiguration(storage: storage)
        config.globalContext = "CUSTOM"
        XCTAssertNotNil(storage.object(forKey: UserDefaultsKeys.globalContext))

        config.resetToDefaults()

        XCTAssertEqual(config.globalContext, AppDefaults.globalContext)
        XCTAssertNil(
            storage.object(forKey: UserDefaultsKeys.globalContext),
            "the assignment's didSet re-persists the default — reset must re-remove the key")
    }

    /// The settings card's "Reset to Default" button routes here. It is the path
    /// that CREATED the pinned cohort back when it assigned the default directly,
    /// so it must restore the value in memory while leaving nothing on disk.
    func testResetGlobalContextToDefault_restoresValueWithoutPinningACopy() {
        let config = StoreConfiguration(storage: storage)
        config.globalContext = "CUSTOM"
        XCTAssertNotNil(storage.object(forKey: UserDefaultsKeys.globalContext))

        config.resetGlobalContextToDefault()

        XCTAssertEqual(
            config.globalContext, AppDefaults.globalContext,
            "the user asked for the default back — it must be observable immediately")
        XCTAssertNil(
            storage.object(forKey: UserDefaultsKeys.globalContext),
            "persisting a copy of the default is exactly what pins an install")
    }

    /// The button and the global reset must not drift: both are "restore the
    /// shipped default", and a divergence would silently re-open the cohort
    /// through whichever path forgot the key removal.
    func testBothResetPaths_leaveIdenticalStorageState() {
        let viaCard = InMemoryStorage()
        let viaGlobal = InMemoryStorage()
        StoreConfiguration(storage: viaCard).resetGlobalContextToDefault()
        StoreConfiguration(storage: viaGlobal).resetToDefaults()

        XCTAssertNil(viaCard.object(forKey: UserDefaultsKeys.globalContext))
        XCTAssertNil(viaGlobal.object(forKey: UserDefaultsKeys.globalContext))
    }
}

private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
    var store: [String: Any] = [:]
    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
