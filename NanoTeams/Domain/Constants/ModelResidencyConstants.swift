import Foundation

/// Tunables for chat-model residency management.
nonisolated enum ModelResidencyConstants {

    /// How long to wait for an unloaded instance to actually disappear before
    /// giving up and proceeding with the load anyway.
    ///
    /// LM Studio acknowledges `POST /api/v1/models/unload` BEFORE the memory is
    /// released — measured 2026-07-19: ack at 213 ms, instance out of the
    /// listing and ~4 GB of RAM returned at 400 ms. Loading the replacement
    /// inside that window sees the memory as still taken and fails with
    /// `model_load_failed`. Budgeted ~7x the measurement because a large
    /// model's teardown is not the 4 GB case — but bounded, because a reconcile
    /// reclaims orphans in a loop and a server that keeps reporting a dead
    /// instance must not stall the switch by this much per model.
    static let unloadSettleTimeout: TimeInterval = 3

    static let unloadSettlePollInterval: Duration = .milliseconds(100)
}
