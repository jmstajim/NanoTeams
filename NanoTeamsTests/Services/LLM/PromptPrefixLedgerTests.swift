import XCTest
@testable import NanoTeams

/// The ledger's whole reason to exist is that comparison is owner-against-itself. These pin that
/// two parallel roles on one model never become each other's baseline, and that out-of-order
/// recording (both clients send from a `Task.detached`) cannot corrupt a chain.
final class PromptPrefixLedgerTests: XCTestCase {

    private let base = "http://127.0.0.1:1234"
    private let model = "test-model"

    private var sut: PromptPrefixLedger!

    override func setUp() {
        super.setUp()
        sut = PromptPrefixLedger()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    private func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }

    private func record(
        _ owner: LLMCallOwner,
        _ messages: [ChatMessage],
        tools: String = ""
    ) async -> PromptPrefixLedger.Observation {
        await sut.record(
            baseURL: base, model: model, owner: owner,
            messages: messages, toolSchemaText: tools)
    }

    private let roleA = LLMCallOwner.step(taskID: 1, stepID: "engineer")
    private let roleB = LLMCallOwner.step(taskID: 1, stepID: "reviewer")

    // MARK: - Own-chain comparison

    func testFirstRequestForAnOwner_isNeverAMiss() async {
        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.structural, .firstRequestForOwner)
        XCTAssertEqual(observation.discardedTokens, 0)
    }

    func testAppendOnlySecondRequest_isReuse() async {
        _ = await record(roleA, [system("s"), user("a")])
        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
    }

    func testMidArrayRewrite_isAMissAndIsPriced() async {
        let long = String(repeating: "word ", count: 4000)
        _ = await record(roleA, [system("s"), user("a"), user(long)])
        let observation = await record(roleA, [system("s"), user("REWRITTEN"), user(long)])

        guard let diagnosis = observation.structural.diagnosis else {
            return XCTFail("expected a miss")
        }
        XCTAssertEqual(diagnosis.cause, .conversationRewritten(atSegment: 1))
        XCTAssertGreaterThan(
            diagnosis.discardedTokens, PrefixCachePolicy.materialTokenThreshold,
            "the long tail after the rewrite must be priced, not reported as zero")
        XCTAssertEqual(observation.discardedTokens, diagnosis.discardedTokens)
    }

    func testToolCatalogChange_reportsSystemPromptChanged() async {
        _ = await record(roleA, [system("s"), user("a")], tools: "read_file")
        let observation = await record(roleA, [system("s"), user("a")], tools: "read_file bash")
        XCTAssertEqual(observation.structural.diagnosis?.cause, .systemPromptChanged)
    }

    // MARK: - Owner isolation (the point of the design)

    func testTwoRolesOnOneModel_neverBecomeEachOthersBaseline() async {
        _ = await record(roleA, [system("s"), user("A1")])
        _ = await record(roleB, [system("s"), user("B1")])

        // Role A appends. If the ledger had one slot per model, B1 would be A's baseline and
        // this would report a total miss.
        let observation = await record(roleA, [system("s"), user("A1"), user("A2")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
    }

    func testInterleavedRecording_doesNotCorruptAChain() async {
        // Both clients send from a `Task.detached`, so a sibling's records can land between
        // ours. Chains are keyed per owner, so no amount of interleaving can make B's
        // conversation our baseline. (Ordering is the actor's own `seq`, assigned on arrival —
        // there is no caller-supplied stamp left to put out of order.)
        _ = await record(roleA, [system("s"), user("A1")])
        _ = await record(roleB, [system("s"), user("B1")])
        _ = await record(roleB, [system("s"), user("B1"), user("B2")])

        let observation = await record(roleA, [system("s"), user("A1"), user("A2")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
    }

    func testDifferentModels_areIndependent() async {
        _ = await sut.record(
            baseURL: base, model: "model-x", owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "")
        let observation = await sut.record(
            baseURL: base, model: "model-y", owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "")
        XCTAssertEqual(
            observation.structural, .firstRequestForOwner,
            "the same role on a different model has no shared cache")
    }

    func testBaseURLIsNormalized() async {
        _ = await sut.record(
            baseURL: "http://127.0.0.1:1234/", model: model, owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "")
        let observation = await sut.record(
            baseURL: "HTTP://127.0.0.1:1234", model: model, owner: roleA,
            messages: [system("s"), user("a"), user("b")], toolSchemaText: "")
        XCTAssertEqual(observation.structural, .reused(segments: 2))
    }

    // MARK: - One-shots

    func testOneShot_neverGetsAVictimVerdict() async {
        let judge = LLMCallOwner.oneShot(label: "bash judge")
        _ = await record(judge, [system("j"), user("cmd 1")])
        let observation = await record(judge, [system("j"), user("cmd 2")])
        XCTAssertEqual(
            observation.structural, .firstRequestForOwner,
            "a judge call is a fresh 2-message conversation; it has no prefix to lose")
    }

    func testChainOwner_doesAccumulate() async {
        let consultation = LLMCallOwner.chain(id: "consultation:tech-lead")
        _ = await record(consultation, [system("c"), user("q1")])
        let observation = await record(consultation, [system("c"), user("q1"), user("q2")])
        XCTAssertEqual(
            observation.structural, .reused(segments: 2),
            "ask_teammate resends the whole run-long chat — it is a chain, not a one-shot")
    }

    // MARK: - Suspects

    func testSuspect_namesAnInterleaverThatArrivedAfterOurLastRequest() async {
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(.oneShot(label: "bash judge"), [system("j"), user("cmd")])

        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertEqual(observation.suspect, LLMCallOwner.oneShot(label: "bash judge").key)
    }

    func testSuspect_isNilWhenNobodyElseRanSinceOurLastRequest() async {
        _ = await record(.oneShot(label: "vision"), [user("x")])
        _ = await record(roleA, [system("s"), user("a")])
        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertNil(
            observation.suspect,
            "a caller from before our own last request cannot have taken the cache since")
    }

    func testSuspect_neverNamesOurself() async {
        _ = await record(roleA, [system("s"), user("a")])
        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertNil(observation.suspect)
    }

    /// The anchor comparison is `<=`, so two records that a clock would have stamped
    /// identically must still be distinguishable. With a wall-clock `Date()` this was a real
    /// tie — `entry.at <= since` returned nil and dropped a genuine suspect; the actor-assigned
    /// sequence makes the tie unrepresentable. Nothing sleeps here: back-to-back `await`s on one
    /// actor are exactly the case a clock could not separate.
    func testSuspect_survivesRecordsAClockWouldHaveTied() async {
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(.oneShot(label: "bash judge"), [system("j"), user("cmd")])
        let observation = await record(roleA, [system("s"), user("a"), user("b")])

        XCTAssertEqual(
            observation.suspect, LLMCallOwner.oneShot(label: "bash judge").key,
            "an interleaver recorded in the same instant is still an interleaver")
    }

    // MARK: - Warm floor

    func testWarmFloor_tracksTheMinimumAndCountsSamples() async {
        await note(nsPerToken: 500, promptTokens: 4000)
        await note(nsPerToken: 27, promptTokens: 12_000)
        await note(nsPerToken: 40, promptTokens: 900)

        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.warmFloorNsPerToken, 27, "a hit is the fastest a prefill can be")
        XCTAssertEqual(observation.floorSampleCount, 3)
    }

    /// The depth is recorded with the MINIMUM, not with the latest sample: the rate is roughly
    /// `overhead / depth` on a hit, so the floor is only comparable against requests of a
    /// similar size, and it is the winning sample's size that says which those are.
    func testWarmFloor_recordsTheDepthOfTheWinningSample() async {
        await note(nsPerToken: 500, promptTokens: 900)
        await note(nsPerToken: 27, promptTokens: 12_960)
        await note(nsPerToken: 40, promptTokens: 300)

        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.warmFloorPromptTokens, 12_960)
    }

    func testWarmFloor_ignoresNonPositiveSamples() async {
        await note(nsPerToken: 30, promptTokens: 1000)
        await note(nsPerToken: 0, promptTokens: 1000)
        await note(nsPerToken: -5, promptTokens: 1000)

        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.warmFloorNsPerToken, 30)
        XCTAssertEqual(observation.floorSampleCount, 1)
    }

    private func note(nsPerToken: Double, promptTokens: Int) async {
        await sut.noteServerPrefill(
            baseURL: base, model: model, nsPerToken: nsPerToken, promptTokens: promptTokens)
    }

    // MARK: - Lifecycle

    func testForgetOwner_dropsTheChainSoTheNextRequestStartsClean() async {
        _ = await record(roleA, [system("s"), user("a")])
        await sut.forgetOwner(roleA)
        let observation = await record(roleA, [system("s"), user("REWRITTEN")])
        XCTAssertEqual(observation.structural, .firstRequestForOwner)
    }

    /// The reason it is owner-scoped and not `(server, model)`-scoped: a fresh conversation
    /// invalidates the comparison on EVERY server this owner used, and the key moves under it —
    /// `preflightCheck` can fall back to the global config, and a role's `llmOverride` can be
    /// edited between runs. A keyed drop clears one slot and leaves the stale chain live under
    /// the other, which is silent until a later run lands on it again.
    func testForgetOwner_dropsTheChainOnEveryServerAndModel() async {
        let otherBase = "http://127.0.0.1:9999"
        let otherModel = "override-model"
        _ = await record(roleA, [system("s"), user("a")])
        _ = await sut.record(
            baseURL: otherBase, model: otherModel, owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "")

        await sut.forgetOwner(roleA)

        // `await` cannot live inside an XCTAssert autoclosure — hoist both.
        let onDefault = await record(roleA, [system("s"), user("a")]).structural
        let onOverride = await sut.record(
            baseURL: otherBase, model: otherModel, owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "").structural

        XCTAssertEqual(onDefault, .firstRequestForOwner)
        XCTAssertEqual(onOverride, .firstRequestForOwner)
    }

    func testForgetOwner_doesNotTouchOtherOwners() async {
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(roleB, [system("s"), user("b")])
        await sut.forgetOwner(roleA)
        let observation = await record(roleB, [system("s"), user("b"), user("b2")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
    }

    // MARK: - Corner cases: owner-key selection

    /// The reason `OwnerEntry` stores `ownerKey` instead of parsing it back out of the composite
    /// `base|model|owner`: `normalizedBaseURL` cannot contain `|`, but NOTHING constrains a model
    /// name. A suffix match would be a guess, and this is the input that makes the guess wrong.
    func testForgetOwner_isUnconfusedByAPipeInTheModelName() async {
        let sneaky = "weird|step:1:engineer"
        _ = await sut.record(
            baseURL: base, model: sneaky, owner: roleB,
            messages: [system("s"), user("b")], toolSchemaText: "")

        await sut.forgetOwner(roleA)  // roleA never recorded on that model

        let observation = await sut.record(
            baseURL: base, model: sneaky, owner: roleB,
            messages: [system("s"), user("b"), user("b2")], toolSchemaText: "")
        XCTAssertEqual(
            observation.structural, .reused(segments: 2),
            "selection is by EQUALITY on the stored owner key — a model name that happens to end "
                + "in another owner's key must not make it collateral")
    }

    /// `step:1:engineer` is a strict prefix of `step:1:engineer2`. Equality is immune; any
    /// `hasPrefix`/`contains` rewrite would not be.
    func testForgetOwner_doesNotDropAPrefixSiblingOwner() async {
        let sibling = LLMCallOwner.step(taskID: 1, stepID: "engineer2")
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(sibling, [system("s"), user("a")])

        await sut.forgetOwner(roleA)

        let dropped = await record(roleA, [system("s"), user("a")]).structural
        let kept = await record(sibling, [system("s"), user("a"), user("more")]).structural
        XCTAssertEqual(dropped, .firstRequestForOwner)
        XCTAssertEqual(kept, .reused(segments: 2), "`engineer2` is a different owner entirely")
    }

    /// The three kinds are namespaced by their `key` prefix, so a chain and a one-shot sharing a
    /// label are still different owners.
    func testForgetOwner_doesNotConfuseOwnerKinds() async {
        let chain = LLMCallOwner.chain(id: "vision")
        _ = await record(chain, [system("s"), user("a")])
        _ = await record(.oneShot(label: "vision"), [system("s"), user("a")])

        await sut.forgetOwner(.oneShot(label: "vision"))

        let kept = await record(chain, [system("s"), user("a"), user("b")]).structural
        XCTAssertEqual(
            kept, .reused(segments: 2),
            "forgetting the one-shot must not touch the chain that shares its label")
    }

    func testForgetOwner_onAnUnknownOwner_isANoOp() async {
        _ = await record(roleA, [system("s"), user("a")])
        await sut.forgetOwner(.step(taskID: 99, stepID: "never-ran"))
        let survived = await record(roleA, [system("s"), user("a"), user("b")]).structural
        XCTAssertEqual(survived, .reused(segments: 2))
    }

    /// A one-shot never stores a chain in the first place (`accumulatesPrefix == false`), so
    /// forgetting it is vacuous — but it must not throw or disturb the model's activity ring.
    func testForgetOwner_onAOneShot_leavesItUsableAsASuspect() async {
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(.oneShot(label: "bash judge"), [user("cmd")])
        await sut.forgetOwner(.oneShot(label: "bash judge"))

        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertEqual(
            observation.suspect, LLMCallOwner.oneShot(label: "bash judge").key,
            "the activity ring is not the chain store — forgetting a chain-less owner must not "
                + "erase the interleaving it recorded")
    }

    // MARK: - Corner cases: the warm floor

    /// A sample whose depth is unknown would be stored as the floor's depth, and
    /// `isComparableDepth` refuses a non-positive `floorTokens` — so accepting one would silently
    /// retire the eviction branch for this model.
    func testWarmFloor_ignoresASampleWithNoUsableDepth() async {
        await note(nsPerToken: 30, promptTokens: 0)
        await note(nsPerToken: 30, promptTokens: -1)

        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertNil(observation.warmFloorNsPerToken, "an undated sample is not a floor")
        XCTAssertNil(observation.warmFloorPromptTokens)
        XCTAssertEqual(observation.floorSampleCount, 0, "it must not count toward the minimum either")
    }

    /// Ties keep the FIRST winner's depth. Arbitrary but deterministic — pinned so a refactor
    /// cannot silently flip which depth the comparison is anchored to.
    func testWarmFloor_anEqualRateDoesNotMoveTheRecordedDepth() async {
        await note(nsPerToken: 27, promptTokens: 12_960)
        await note(nsPerToken: 27, promptTokens: 400)

        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.warmFloorPromptTokens, 12_960)
    }

    func testWarmFloor_isPerModel_notPerProcess() async {
        await note(nsPerToken: 27, promptTokens: 12_960)
        let other = await sut.record(
            baseURL: base, model: "another-model", owner: roleA,
            messages: [system("s"), user("a")], toolSchemaText: "")
        XCTAssertNil(
            other.warmFloorNsPerToken,
            "one model's warm rate says nothing about another's — they are different weights")
    }

    // MARK: - Corner cases: appended-tail pricing

    func testAppendedTokens_areZeroWhenTheRequestIsIdentical() async {
        _ = await record(roleA, [system("s"), user("a")])
        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
        XCTAssertEqual(
            observation.appendedTokens, 0,
            "a byte-identical resend hands the server nothing new to prefill")
    }

    /// A SHORTER resend is a full hit (the cache is a prefix), and it appends nothing.
    func testAppendedTokens_areZeroWhenTheRequestIsAStrictPrefix() async {
        _ = await record(roleA, [system("s"), user("a"), user("b"), user("c")])
        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(observation.structural, .reused(segments: 2))
        XCTAssertEqual(observation.appendedTokens, 0)
    }

    func testAppendedTokens_countOnlyTheNewTail_notTheWholeConversation() async {
        let head = String(repeating: "head ", count: 2000)
        let tail = "just a little more"
        _ = await record(roleA, [system("s"), user(head)])
        let observation = await record(roleA, [system("s"), user(head), user(tail)])

        XCTAssertEqual(
            observation.appendedTokens,
            WorkFolderContextPromptPlanner.estimateTokens(tail),
            "pricing the whole prompt here would make every long conversation look like a big "
                + "append, which is precisely what the guard must not do")
        XCTAssertLessThan(observation.appendedTokens, observation.totalPromptTokens / 10)
    }

    // MARK: - Bounds: the owner LRU

    /// `maxTrackedOwners` and the eviction it drives had no test at all. The bound is what keeps
    /// a long-lived process from accumulating one chain per step that ever ran; the safety
    /// argument is that an evicted owner costs at most one `.firstRequestForOwner`, which is
    /// never reported.
    ///
    /// Pinned through BEHAVIOR rather than a count accessor: what the cap has to guarantee is
    /// "the oldest chain is the one that goes", and an owner-count getter would not say that.
    private func owner(_ i: Int) -> LLMCallOwner { .step(taskID: i, stepID: "r") }

    func testOwnerLRU_evictsTheOldestOnceTheCapIsPassed() async {
        _ = await record(owner(0), [system("s"), user("a")])
        for i in 1..<513 { _ = await record(owner(i), [system("s"), user("a")]) }

        let evicted = await record(owner(0), [system("s"), user("a")])
        XCTAssertEqual(
            evicted.structural, .firstRequestForOwner,
            "513 owners against a cap of 512 must drop exactly the least recently recorded")

        let survivor = await record(owner(512), [system("s"), user("a")])
        XCTAssertEqual(
            survivor.structural, .reused(segments: 2), "the newest owner must survive")
    }

    func testOwnerLRU_atExactlyTheCap_evictsNothing() async {
        for i in 0..<512 { _ = await record(owner(i), [system("s"), user("a")]) }

        let observation = await record(owner(0), [system("s"), user("a"), user("b")])
        XCTAssertEqual(
            observation.structural, .reused(segments: 2),
            "the prune is `>` the cap, not `>=` — at exactly 512 nothing is evicted")
    }

    func testEvictedOwner_costsOneUnreportedFirstRequest_neverAMiss() async {
        _ = await record(owner(0), [system("s"), user("a"), user("b"), user("c")])
        for i in 1..<600 { _ = await record(owner(i), [system("s"), user("a")]) }

        let observation = await record(owner(0), [system("s"), user("a")])
        XCTAssertEqual(
            observation.structural, .firstRequestForOwner,
            "an evicted chain must read as 'no baseline', never as a rewrite")
        XCTAssertEqual(observation.discardedTokens, 0)
    }

    func testOwnerLRU_keepsTheMostRecentlyRecorded() async {
        for i in 0..<512 { _ = await record(owner(i), [system("s"), user("a")]) }
        // Touch the oldest so it is no longer least-recently-used, then overflow by one.
        _ = await record(owner(0), [system("s"), user("a")])
        _ = await record(owner(9999), [system("s"), user("a")])

        let observation = await record(owner(0), [system("s"), user("a")])
        XCTAssertEqual(
            observation.structural, .reused(segments: 2),
            "recording refreshes `seq`, so a touched owner must survive the next prune")
    }

    // MARK: - Bounds: the per-model activity ring

    /// `activityWindow` bounds suspect naming. Beyond it, an interleaver is simply forgotten —
    /// which is correct: a suspect is a lead, and a stale lead is worse than none.
    func testSuspect_isDroppedOnceItFallsOutOfTheActivityWindow() async {
        _ = await record(roleA, [system("s"), user("a")])
        _ = await record(.oneShot(label: "vision"), [system("s")])
        // Nine further interleavers push "vision" past the 8-entry ring.
        for i in 0..<9 { _ = await record(.oneShot(label: "judge-\(i)"), [system("s")]) }

        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertNotEqual(
            observation.suspect, LLMCallOwner.oneShot(label: "vision").key,
            "an interleaver that has fallen out of the ring must not be named")
    }

    func testSuspect_withManyIdenticalOwners_neverNamesItself() async {
        for _ in 0..<12 { _ = await record(roleA, [system("s"), user("a")]) }
        let observation = await record(roleA, [system("s"), user("a"), user("b")])
        XCTAssertNil(
            observation.suspect,
            "a ring full of our own requests names nobody — we are never our own suspect")
    }

    // MARK: - Corner cases: the warm floor and forgetOwner

    func testNoteServerPrefill_extremeSamples() async {
        await sut.noteServerPrefill(baseURL: base, model: model, nsPerToken: -1, promptTokens: 100)
        await sut.noteServerPrefill(
            baseURL: base, model: model, nsPerToken: .greatestFiniteMagnitude,
            promptTokens: 12960)
        let observation = await record(roleA, [system("s"), user("a")])
        XCTAssertEqual(
            observation.floorSampleCount, 1,
            "the negative sample is dropped; the absurd-but-positive one still counts")
        XCTAssertEqual(observation.warmFloorNsPerToken, .greatestFiniteMagnitude)
    }

    func testModelKey_normalizesTrailingSlashesButNotHostAliases() {
        XCTAssertEqual(
            PromptPrefixLedger.modelKey(baseURL: "http://127.0.0.1:1234//", model: "m"),
            PromptPrefixLedger.modelKey(baseURL: "http://127.0.0.1:1234", model: "m"))
        XCTAssertNotEqual(
            PromptPrefixLedger.modelKey(baseURL: "http://localhost:1234", model: "m"),
            PromptPrefixLedger.modelKey(baseURL: "http://127.0.0.1:1234", model: "m"),
            "localhost and 127.0.0.1 are different network identities — never collapsed")
    }

    func testOwnerKey_isUnconfusedByAPipeInTheModelName() {
        let a = PromptPrefixLedger.ownerKey(
            baseURL: "http://h:1", model: "weird|name", owner: .chain(id: "x"))
        let b = PromptPrefixLedger.ownerKey(
            baseURL: "http://h:1", model: "weird", owner: .chain(id: "name|x"))
        XCTAssertNotEqual(a, b, "the composite key must not be ambiguous under a pipe")
    }
}
