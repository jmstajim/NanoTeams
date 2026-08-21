import XCTest

@testable import NanoTeams

/// Pins what a delete destroys and what its confirmation says it destroys — the two must be the
/// same number. Pure value types plus one temp-directory store, so the suite is not `@MainActor`.
final class BenchmarkDeletionTests: XCTestCase {

    private let promptVersion = 4

    // MARK: - Scope

    func testEverything_takesEveryRun() {
        let request = BenchmarkDeletion.everything(
            in: [run(model: "a"), run(model: "b"), run(model: "c")],
            currentPromptVersion: promptVersion)
        XCTAssertEqual(request.runIDs.count, 3)
        XCTAssertEqual(request.olderPromptCount, 0)
    }

    /// RED: count older-prompt runs across the whole history instead of within the request → a
    /// single-model delete reports other models' old runs as part of what it is about to remove.
    func testModel_countsOlderPromptRunsOnlyInsideItsOwnScope() {
        let mine = run(model: "m", promptVersion: promptVersion - 1)
        let theirs = run(model: "other", promptVersion: promptVersion - 1)
        let request = BenchmarkDeletion.model(
            row: row(model: "m"), in: [mine, theirs], currentPromptVersion: promptVersion)

        XCTAssertEqual(request.runIDs, [mine.id])
        XCTAssertEqual(request.olderPromptCount, 1)
    }

    /// RED: widen this to the model's other runs → the Runs tab's per-row delete quietly becomes a
    /// per-model delete, which is the button beside it.
    func testRun_isExactlyOneRun() {
        let target = run(model: "m")
        let sibling = run(model: "m")
        let request = BenchmarkDeletion.run(target, currentPromptVersion: promptVersion)
        XCTAssertEqual(request.runIDs, [target.id])
        XCTAssertFalse(request.runIDs.contains(sibling.id))
    }

    func testModel_withNoMatchingRuns_isEmpty() {
        let request = BenchmarkDeletion.model(
            row: row(model: "ghost"), in: [run(model: "m")], currentPromptVersion: promptVersion)
        XCTAssertTrue(request.isEmpty)
    }

    /// The dialog presents by identity, so two different requests must not share one.
    func testIDs_distinguishTheThreeScopes() {
        let all = BenchmarkDeletion.everything(in: [run(model: "m")], currentPromptVersion: promptVersion)
        let model = BenchmarkDeletion.model(
            row: row(model: "m"), in: [run(model: "m")], currentPromptVersion: promptVersion)
        let single = BenchmarkDeletion.run(run(model: "m"), currentPromptVersion: promptVersion)
        XCTAssertEqual(Set([all.id, model.id, single.id]).count, 3)
    }

    /// Two rows for one model on two servers are two deletes, and the dialog must be able to tell
    /// them apart. RED: drop the endpoint from `id` → confirming one can act on the other.
    func testModelIDs_differPerServer() {
        let here = BenchmarkDeletion.model(
            row: row(model: "m", baseURL: "http://127.0.0.1:1234"),
            in: [], currentPromptVersion: promptVersion)
        let there = BenchmarkDeletion.model(
            row: row(model: "m", baseURL: "http://192.168.1.9:1234"),
            in: [], currentPromptVersion: promptVersion)
        XCTAssertNotEqual(here.id, there.id)
    }

    // MARK: - Copy

    /// RED: hardcode the number in the label → the button can promise a count the request does not
    /// hold, which is the one thing a confirmation must never do.
    func testConfirmLabel_statesTheCountTheRequestActuallyHolds() {
        let request = BenchmarkDeletion.everything(
            in: (0..<7).map { run(model: "m\($0)") }, currentPromptVersion: promptVersion)
        XCTAssertTrue(
            BenchmarkDeletion.confirmLabel(for: request).contains("7"),
            BenchmarkDeletion.confirmLabel(for: request))
    }

    func testConfirmLabel_isSingularForOneRun() {
        let request = BenchmarkDeletion.run(run(model: "m"), currentPromptVersion: promptVersion)
        XCTAssertEqual(BenchmarkDeletion.confirmLabel(for: request), "Delete run")

        let one = BenchmarkDeletion.everything(in: [run(model: "m")], currentPromptVersion: promptVersion)
        XCTAssertEqual(BenchmarkDeletion.confirmLabel(for: one), "Delete the run")
    }

    /// RED: drop the irreversibility sentence from any branch → a destructive dialog stops saying
    /// the history has no undo, and this file is the only place that says it.
    func testEveryMessage_saysItCannotBeUndone() {
        let requests = [
            BenchmarkDeletion.everything(in: [run(model: "m")], currentPromptVersion: promptVersion),
            BenchmarkDeletion.model(
                row: row(model: "m"), in: [run(model: "m")], currentPromptVersion: promptVersion),
            BenchmarkDeletion.run(run(model: "m"), currentPromptVersion: promptVersion),
        ]
        for request in requests {
            XCTAssertTrue(
                BenchmarkDeletion.message(for: request).contains("cannot be undone"),
                BenchmarkDeletion.message(for: request))
        }
    }

    /// The Clear button destroys rows the filter is hiding, and the table cannot be used to check
    /// the count. RED: omit the clause → the number in the dialog looks wrong to anyone counting
    /// the rows on screen, and is in fact right.
    func testEverythingMessage_namesWhatTheFilterIsHiding() {
        let runs = (0..<5).map { run(model: "m\($0)") }
        let hidden = BenchmarkDeletion.everything(
            in: runs, currentPromptVersion: promptVersion, hiddenByFilter: 3)
        let none = BenchmarkDeletion.everything(in: runs, currentPromptVersion: promptVersion)

        XCTAssertTrue(
            BenchmarkDeletion.message(for: hidden).contains("3 the filter is hiding"),
            BenchmarkDeletion.message(for: hidden))
        XCTAssertFalse(
            BenchmarkDeletion.message(for: none).contains("filter"),
            BenchmarkDeletion.message(for: none))
    }

    /// RED: leave the older-prompt runs unmentioned → the count exceeds the rows the leaderboard
    /// shows for that model and reads as a bug in the dialog.
    func testModelMessage_accountsForRunsTheLeaderboardNeverShowed() {
        let current = run(model: "m")
        let older = run(model: "m", promptVersion: promptVersion - 1)
        let request = BenchmarkDeletion.model(
            row: row(model: "m"), in: [current, older], currentPromptVersion: promptVersion)

        let message = BenchmarkDeletion.message(for: request)
        XCTAssertTrue(message.contains("older prompt"), message)
        XCTAssertTrue(message.contains("1 of them"), message)
    }

    func testModelMessage_whenEveryRunIsOlder_saysSoWithoutACount() {
        let older = (0..<2).map { _ in run(model: "m", promptVersion: promptVersion - 1) }
        let request = BenchmarkDeletion.model(
            row: row(model: "m"), in: older, currentPromptVersion: promptVersion)
        let message = BenchmarkDeletion.message(for: request)
        XCTAssertTrue(message.contains("All of them"), message)
        XCTAssertFalse(message.contains("2 of them"), message)
    }

    /// RED: title the model dialog "Delete this row?" → the confirmation names nothing the user
    /// can check against the table.
    func testTitle_namesTheModelForAModelDelete() {
        let request = BenchmarkDeletion.model(
            row: row(model: "qwen3.6"), in: [], currentPromptVersion: promptVersion)
        XCTAssertTrue(BenchmarkDeletion.title(for: request).contains("qwen3.6"))
    }

    func testModelMessage_namesTheEndpointItIsScopedTo() {
        let request = BenchmarkDeletion.model(
            row: row(model: "m", baseURL: "http://192.168.1.9:1234"),
            in: [], currentPromptVersion: promptVersion)
        XCTAssertTrue(
            BenchmarkDeletion.message(for: request).contains("192.168.1.9:1234"),
            BenchmarkDeletion.message(for: request))
    }

    // MARK: - When the store could not

    /// RED: return a message for `.removed` → a successful delete leaves an error line under a
    /// table that no longer holds the row it names.
    func testFailureMessage_isSilentOnSuccess() {
        XCTAssertNil(BenchmarkDeletion.failureMessage(.removed))
    }

    /// The two failure shapes leave the history in different states and only one is actionable, so
    /// they must not share a sentence. RED: fold them into one message → the reader cannot tell
    /// "nothing happened" from "half happened".
    func testFailureMessage_saysWhichFailureThisWas() {
        let nothing = BenchmarkDeletion.failureMessage(.nothingWritten(reason: "disk full"))
        let partial = BenchmarkDeletion.failureMessage(
            .samplesLeftBehind(rows: 3, reason: "disk full"))

        XCTAssertNotEqual(nothing, partial)
        XCTAssertTrue(try XCTUnwrap(nothing).contains("Nothing was deleted"), nothing ?? "")
        XCTAssertTrue(try XCTUnwrap(partial).contains("3 sample rows"), partial ?? "")
        // Both must carry the reason the store gave — an error with no cause cannot be acted on.
        XCTAssertTrue(try XCTUnwrap(nothing).contains("disk full"), nothing ?? "")
        XCTAssertTrue(try XCTUnwrap(partial).contains("disk full"), partial ?? "")
    }

    /// RED: tell the user to "delete again" → after a row delete that row is gone from the table,
    /// so the instruction names a button that is no longer on screen.
    func testFailureMessage_pointsAtSomethingStillClickable() {
        let partial = BenchmarkDeletion.failureMessage(
            .samplesLeftBehind(rows: 1, reason: "denied"))
        XCTAssertTrue(try XCTUnwrap(partial).contains("Delete all"), partial ?? "")
    }

    func testFailureMessage_isSingularForOneRow() {
        let one = BenchmarkDeletion.failureMessage(.samplesLeftBehind(rows: 1, reason: "denied"))
        XCTAssertTrue(try XCTUnwrap(one).contains("1 sample row could not"), one ?? "")
    }

    // MARK: - The whole chain

    /// The seam the copy is a promise about: a row's request, handed to the store, removes exactly
    /// that row's runs and their samples and leaves the neighbour alone.
    ///
    /// RED: build the request from the row's contributing runs only (drop the throttled one) → the
    /// row rebuilds itself from what survived, which is "I deleted it and it came back".
    func testRequestForARow_appliedToTheStore_removesThatRowAndOnlyThatRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BenchmarkHistoryStore(directory: directory)

        let clean = run(model: "m")
        let throttled = run(model: "m", throttled: true)
        let neighbour = run(model: "other")
        for candidate in [clean, throttled, neighbour] {
            store.append(run: candidate)
            store.append(samples: [sample(runID: candidate.id)])
        }

        let request = BenchmarkDeletion.model(
            row: row(model: "m"), in: store.loadRuns(), currentPromptVersion: promptVersion)
        store.delete(runIDs: request.runIDs)

        XCTAssertEqual(store.loadRuns().map(\.modelName), ["other"])
        XCTAssertEqual(store.loadSamples().map(\.runID), [neighbour.id])
        XCTAssertTrue(
            BenchmarkLeaderboard.rows(
                runs: store.loadRuns(), samples: store.loadSamples(),
                currentPromptVersion: promptVersion
            ).allSatisfy { $0.modelName != "m" },
            "the deleted row came back")
    }

    // MARK: - Builders

    private func row(
        model: String, baseURL: String = "http://127.0.0.1:1234"
    ) -> BenchmarkLeaderboard.Row {
        BenchmarkLeaderboard.Row(
            id: BenchmarkLeaderboard.groupKey(
                provider: .lmStudio, baseURLString: baseURL, modelName: model),
            provider: .lmStudio,
            modelName: model,
            baseURLString: baseURL,
            providerVersion: "0.32.14",
            generationTokensPerSecond: 40,
            generationRateSource: .serverDecodeWindow,
            bestGenerationTokensPerSecond: 40,
            timeToFirstTokenMs: 600,
            prefillTokensPerSecond: 2000,
            prefillSource: .serverPromptEval,
            runCount: 1,
            failedRunCount: 0,
            lastMeasuredAt: Date(timeIntervalSince1970: 1000),
            isThrottled: false)
    }

    private func run(
        model: String,
        baseURL: String = "http://127.0.0.1:1234",
        promptVersion: Int? = nil,
        throttled: Bool = false
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            startedAt: Date(timeIntervalSince1970: 1000),
            provider: .lmStudio,
            baseURLString: baseURL,
            modelName: model,
            requestTimeoutSeconds: 600,
            promptID: "prose-en",
            promptVersion: promptVersion ?? self.promptVersion,
            repeats: 5,
            thermalState: throttled ? BenchmarkThermalState.serious : BenchmarkThermalState.nominal,
            lowPowerMode: false,
            modelWasResident: true,
            appVersion: "1.8.8")
    }

    private func sample(runID: UUID) -> GenerationBenchmarkSample {
        GenerationBenchmarkSample(
            runID: runID,
            recordedAt: Date(timeIntervalSince1970: 1000),
            phase: .measured,
            sampleIndex: 0,
            inputTokens: 800,
            outputTokens: 401,
            timeToFirstTokenMs: 600,
            generationMs: 10_000,
            prefillMs: 400,
            prefillSource: .serverPromptEval)
    }
}
