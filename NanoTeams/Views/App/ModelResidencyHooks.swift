import SwiftUI

/// Observes every setting that changes which LM Studio models NanoTeams should
/// have resident, and drives the residency reconciler.
///
/// These live at the app ROOT rather than in the Settings views: a model can be
/// committed from the Settings picker OR the status-bar quick picker, and
/// Settings is a separate window that isn't always mounted. Observing the
/// configuration properties here covers every writer with one hook.
///
/// Extracted into its own `ViewModifier` because appending them inline to
/// `MainLayoutView.body` pushed it past the type-checker's budget
/// ("unable to type-check this expression in reasonable time" — CLAUDE.md #10).
struct ModelResidencyHooks: ViewModifier {

    let store: NTMSOrchestrator

    func body(content: Content) -> some View {
        content
            .onChange(of: store.configuration.llmModelName) { oldModel, newModel in
                let base = store.configuration.llmBaseURLString
                // Read at handler time: on a provider FLIP the didSet resets
                // URL+model, so this hook fires with the NEW provider — the
                // explicit-load half is correctly skipped for Ollama while
                // reconcile still reclaims the orphaned LM Studio instance.
                let provider = store.configuration.llmProvider
                Task {
                    await store.switchChatModel(
                        oldModel: oldModel, newModel: newModel, baseURLString: base,
                        provider: provider)
                }
            }
            .onChange(of: store.configuration.visionModelName) { oldModel, newModel in
                // Vision off ⇒ no request will ever target this slot, so
                // swapping instances for it would be pure churn. Turning Vision
                // OFF is handled by the residency hook below, which reclaims
                // the override.
                guard store.configuration.visionEnabled else { return }
                // Empty means "inherit the global model". Resolved by
                // `StoreConfiguration` so this matches `visionLLMConfig`
                // exactly — a hand-rolled copy here diverged on whitespace (it
                // tested the raw value, so "   " read as a real model name).
                let config = store.configuration
                let old = config.resolvedVisionModel(for: oldModel)
                let new = config.resolvedVisionModel(for: newModel)
                let base = config.resolvedVisionBaseURL
                let provider = config.resolvedVisionProvider
                Task {
                    await store.switchChatModel(
                        oldModel: old, newModel: new, baseURLString: base,
                        provider: provider)
                }
            }
            // Every OTHER setting that can orphan a managed model. These change
            // which slots reference which model without being a model swap, so
            // they reconcile rather than switch: turning Vision off reclaims
            // its override, disabling a judge reclaims its override, and a
            // server-URL change moves a slot to a different endpoint.
            .onChange(of: store.residencyRelevantSettings) { _, _ in
                Task { await store.reconcileAndReportResidency() }
            }
    }
}

extension View {
    func modelResidencyHooks(store: NTMSOrchestrator) -> some View {
        modifier(ModelResidencyHooks(store: store))
    }
}
