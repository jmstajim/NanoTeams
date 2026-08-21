import Foundation

/// Why the benchmark cannot start right now.
///
/// A reason rather than a `Bool`, because the two cases are indistinguishable to a boolean and
/// have opposite advice: a running TASK is somebody else's work that the user may not want to
/// interrupt, while a running SWEEP is this screen's own and has a Cancel button three lines away.
/// The single flag it replaces was passed `hasRunningTasks || isMeasuring` and then narrated as
/// "a task is running" — true half the time, and unfalsifiable from the screen.
nonisolated enum BenchmarkBlockReason: Equatable, Sendable {
    /// A team task is streaming. Its stream shares the machine, so a measurement taken now would
    /// be of both at once.
    case taskRunning
    /// The benchmark itself is measuring something. One machine, one measurement.
    case measuring

    /// The clause a footer appends after naming the button it explains.
    var explanation: String {
        switch self {
        case .taskRunning:
            "A task is running. Its stream shares the machine, so a measurement taken now would "
                + "be of both at once — this is disabled until it finishes."
        case .measuring:
            "A measurement is already running. There is one machine, so models are measured one "
                + "at a time — cancel it to start something else."
        }
    }
}
