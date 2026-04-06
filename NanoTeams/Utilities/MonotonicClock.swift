import Foundation

/// Thread-safe monotonic timestamp generator that guarantees strictly increasing timestamps.
/// Ensures that each call to `now()` returns a Date greater than all previous calls.
/// Uses NSLock for thread safety (synchronous, can be called from any context).
public final class MonotonicClock {
    public static let shared = MonotonicClock()

    private let lock = NSLock()
    private var lastTimestamp: Date = .distantPast

    /// Returns a timestamp guaranteed to be greater than all previous calls.
    /// Uses system time when possible, adding 1ms offset when necessary.
    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }

        let systemNow = Date()
        let minNext = lastTimestamp.addingTimeInterval(0.001) // +1ms
        let result = max(systemNow, minNext)
        lastTimestamp = result
        return result
    }

    #if DEBUG
    /// Resets the clock state for testing purposes.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastTimestamp = .distantPast
    }
    #endif
}
