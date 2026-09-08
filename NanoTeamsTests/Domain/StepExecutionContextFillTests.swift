import XCTest

@testable import NanoTeams

/// `StepExecution.contextFill` — the persisted half of the context indicator.
///
/// It has to survive a round trip because it is what a SUSPENDED step shows: no request is in
/// flight to re-measure, and the automatic trigger derives its verdict from it at re-entry. It
/// also has to be absent-safe, because every task written before this field existed decodes
/// without it.
final class StepExecutionContextFillTests: XCTestCase {

    private func makeStep(fill: ContextFill?) -> StepExecution {
        StepExecution(
            id: "engineer", role: .softwareEngineer, title: "work", contextFill: fill)
    }

    private func roundTrip(_ step: StepExecution) throws -> StepExecution {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        return try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: data)
    }

    func testRoundTrip_preservesEveryField() throws {
        let fill = ContextFill(
            promptTokens: 4200, window: 8192, budget: 2048, isEstimate: true, compactions: 3,
            measuredAt: Date(timeIntervalSince1970: 1_000_000))
        let decoded = try roundTrip(makeStep(fill: fill))
        XCTAssertEqual(decoded.contextFill, fill)
    }

    func testRoundTrip_withNilWindowAndBudget() throws {
        // A fixed instant, because the persistence date strategy is ISO 8601 with fractional
        // seconds — `MonotonicClock.now()` carries more precision than that survives, and the
        // round trip would fail on the timestamp rather than on the fields under test.
        let fill = ContextFill(
            promptTokens: 900, window: nil, budget: nil,
            measuredAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(try roundTrip(makeStep(fill: fill)).contextFill, fill)
    }

    /// `nil` is the honest answer for a step that never measured — the indicator hides rather
    /// than rendering a zero-width bar that claims the conversation is empty.
    func testAbsentFill_decodesAsNil() throws {
        XCTAssertNil(try roundTrip(makeStep(fill: nil)).contextFill)
    }

    /// A step written before the field existed must decode, and must not acquire a fabricated
    /// fill on the way in.
    func testLegacyJSON_withoutTheKey_decodes() throws {
        let json = """
        {"id":"engineer","role":"softwareEngineer","title":"work",
         "expectedArtifacts":[],"status":"pending","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
         "messages":[],"artifacts":[],"toolCalls":[],"consultations":[],
         "meetingIDs":[],"amendments":[],"needsSupervisorInput":false,
         "llmConversation":[]}
        """
        let decoded = try JSONCoderFactory.makeDateDecoder()
            .decode(StepExecution.self, from: Data(json.utf8))
        XCTAssertNil(decoded.contextFill)
    }

    /// Two keys are omitted when they carry no information, so a step that never overflowed
    /// and never compacted does not grow them in every `task.json`.
    func testEncoding_omitsTheDefaultedFlags() throws {
        let fill = ContextFill(
            promptTokens: 100, isEstimate: false, compactions: 0,
            measuredAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(fill)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("isEstimate"), text)
        XCTAssertFalse(text.contains("compactions"), text)
        XCTAssertEqual(try JSONCoderFactory.makeDateDecoder()
            .decode(ContextFill.self, from: data), fill)
    }

    /// `reset()` destroys the transcript the fill measured, so a surviving number would show
    /// the discarded attempt's occupancy against a conversation that no longer exists.
    func testReset_clearsTheFill() {
        var step = makeStep(fill: ContextFill(promptTokens: 4200))
        step.reset()
        XCTAssertNil(step.contextFill)
    }

    /// The default is `nil` at every construction site, so no caller has to state it.
    func testMemberwiseInit_defaultsToNil() {
        XCTAssertNil(
            StepExecution(id: "x", role: .softwareEngineer, title: "t").contextFill)
    }
}
