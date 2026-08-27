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
