import XCTest
@testable import NanoTeams

/// `SurfacedErrorScope` — whose error is whose (D-M18, 2026-11-13).
///
/// An operation's outcome is the error ITS task tree surfaced while it ran: the op, its awaited
/// callees, the child tasks it spawns. Not what another task surfaced while the op was
/// suspended, not what a task the op spawned surfaces after the op returned, and not a banner put
/// back on the slot. The same scope keeps an external agent's banners off the person's screen —
/// its own, not the person's.
@MainActor
final class SurfacedErrorScopeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - What is the operation's

    func testNothingSurfaced_answersNil_andPassesTheValueThrough() async {
        let (value, error) = await sut.surfacingError { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertNil(error)
    }

    func testAnErrorBeforeTheOperation_isNotItsOutcome() async {
        sut.lastErrorMessage = "earlier"

        let error = await sut.surfacingError { }.error

        XCTAssertNil(error)
    }

    func testTheLatestOwnError_isTheOutcome_evenIfTheBannerConsumedIt() async {
        let error = await sut.surfacingError {
            self.sut.lastErrorMessage = "first"
            self.sut.lastErrorMessage = "second"
            self.sut.lastErrorMessage = nil    // the banner rendering
        }.error

        XCTAssertEqual(error, "second")
    }

    func testARepeatedIdenticalError_isStillTheOutcome() async {
        sut.lastErrorMessage = "Disk full."

        let error = await sut.surfacingError { self.sut.lastErrorMessage = "Disk full." }.error

        XCTAssertEqual(error, "Disk full.")
    }

    func testAChildTaskTheOperationAwaits_isPartOfIt() async {
        let error = await sut.surfacingError {
            await Task { @MainActor in
                await Task.yield()
                self.sut.lastErrorMessage = "from the child"
            }.value
        }.error

        XCTAssertEqual(error, "from the child")
    }

    // MARK: - What is not

    func testAnotherTaskDuringTheOperation_isNotItsOutcome_butIsStillCounted() async {
        let foreign = ForeignErrorSurface(sut, message: "foreign")
        defer { foreign.cancel() }
        let countBefore = sut.errorSurfaceCount

        let error = await sut.surfacingError { await foreign.fire() }.error

        XCTAssertNil(error)
        XCTAssertEqual(sut.errorSurfaceCount, countBefore + 1, "the process still records it")
        XCTAssertEqual(sut.lastSurfacedError, "foreign")
    }

    /// `Task.detached` inherits no task-local: a detached body that surfaced on the main actor
    /// would be invisible to the operation. None does — the detached writes hand their errors back
    /// to the awaiting caller — and this pins what the scope sees if one ever did.
    func testADetachedTask_isNotPartOfTheOperation() async {
        let error = await sut.surfacingError {
            await Task.detached { @MainActor [orchestrator = self.sut!] in
                orchestrator.lastErrorMessage = "detached"
            }.value
        }.error

        XCTAssertNil(error)
    }

    /// A task spawned inside the operation and left running (an engine's run loop) inherits the
    /// scope; what it surfaces after the operation returned is not the operation's.
    func testAChildTaskThatOutlivesTheOperation_isNotItsOutcomeAfterward() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        var child: Task<Void, Never>?
        let (_, error) = await sut.surfacingError {
            child = Task { @MainActor in
                for await _ in gate { break }
                self.sut.lastErrorMessage = "after the op"
            }
        }
        open.yield()
        await child?.value

        XCTAssertNil(error)
        XCTAssertEqual(sut.lastErrorMessage, "after the op", "nothing suppresses a banner after the op")
    }

    func testARestoredBanner_isNotSurfaced_andNotCounted() async {
        let countBefore = sut.errorSurfaceCount

        let error = await sut.surfacingError { self.sut.restoreBanner("what was on screen") }.error

        XCTAssertNil(error)
        XCTAssertEqual(sut.errorSurfaceCount, countBefore)
        XCTAssertEqual(sut.lastErrorMessage, "what was on screen", "the banner is back")
    }

    // MARK: - Nesting

    func testANestedOperationsError_isAlsoTheEnclosingOnes() async {
        var inner: String?
        let outer = await sut.surfacingError {
            inner = await self.sut.surfacingError { self.sut.lastErrorMessage = "inner" }.error
        }.error

        XCTAssertEqual(inner, "inner")
        XCTAssertEqual(outer, "inner")
    }

    func testTheEnclosingOperationsOwnError_isNotTheNestedOnes() async {
        var inner: String? = "unset"
        _ = await sut.surfacingError {
            self.sut.lastErrorMessage = "outer"
            inner = await self.sut.surfacingError { }.error
        }

        XCTAssertNil(inner)
    }

    // MARK: - Banner suppression

    func testSuppression_clearsTheOperationsOwnBanners_andStillRecordsThem() async {
        let countBefore = sut.errorSurfaceCount
        var error: String?

        await sut.suppressingBanners {
            error = await self.sut.surfacingError {
                self.sut.lastErrorMessage = "refused"
                self.sut.lastInfoMessage = "info"
            }.error
        }

        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertNil(sut.lastInfoMessage)
        XCTAssertEqual(error, "refused", "suppressed is not unrecorded")
        XCTAssertEqual(sut.errorSurfaceCount, countBefore + 1)
    }

    func testSuppression_leavesAnotherTasksBanner_onScreen() async {
        let foreign = ForeignErrorSurface(sut, message: "the person's")
        defer { foreign.cancel() }

        await sut.suppressingBanners { await foreign.fire() }

        XCTAssertEqual(sut.lastErrorMessage, "the person's")
    }

    func testSuppression_endsWithTheOperation_forATaskItLeftRunning() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        var child: Task<Void, Never>?
        await sut.suppressingBanners {
            child = Task { @MainActor in
                for await _ in gate { break }
                self.sut.lastErrorMessage = "the engine's, later"
            }
        }
        open.yield()
        await child?.value

        XCTAssertEqual(sut.lastErrorMessage, "the engine's, later")
    }
}
