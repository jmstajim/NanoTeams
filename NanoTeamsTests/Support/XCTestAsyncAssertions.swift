import XCTest

/// `XCTAssertThrowsError` for an `async` expression.
///
/// XCTest's own version takes `@autoclosure () throws -> T`, and an autoclosure is not an async
/// context — so the moment a production call becomes `async`, every assertion wrapping it stops
/// compiling and the tempting repair is to unwrap the assertion into a bare `do`/`catch` at each
/// site. Swift lets an autoclosure BE async; XCTest simply never updated. One helper keeps the
/// call sites reading as assertions.
///
/// Lives in `NanoTeamsTests/Support` because that is the deliverable-side home for shared test
/// code (CLAUDE.md #112) — `Ratchet/` is not synced to the mirror.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        let detail = message()
        XCTFail(
            detail.isEmpty ? "expected an error, none thrown" : detail,
            file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

/// Polls until `condition` holds, and FAILS the test if the budget runs out.
///
/// ## Why the failure is the point
///
/// The give-up loop is the right shape for "nothing must have happened" — a short budget only
/// ever weakens such an assertion in the safe direction. It is the wrong shape for "this must
/// have happened", and a version that returns SILENTLY on timeout is worse than either: the
/// assertions after it then run against whatever state exists, so a real regression reads as a
/// normal failure somewhere else, or (when the assertion is a `contains`) as nothing at all.
///
/// DEBTS.md D-30 catalogued six tests waiting on the wrong signal; three of them were blind
/// `Task.sleep`s standing in for a condition (200 ms against a documented 3 s worst case in one
/// case), and one was a silent-timeout poller. Fourteen private copies of this helper existed
/// across the suite with at least six materially different signatures — a guard written at N
/// sites one at a time (CLAUDE.md #51).
///
/// `description` is not decoration: on timeout it is the only thing that says WHAT was awaited,
/// and a helper that fails with "timed out" alone sends the next reader to the wrong place.
///
/// Lives in `NanoTeamsTests/Support` for the same reason as its neighbour above (CLAUDE.md #112).
func waitUntil(
    _ description: String,
    timeoutSeconds: Double = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out after \(timeoutSeconds)s waiting for: \(description)", file: file, line: line)
}
