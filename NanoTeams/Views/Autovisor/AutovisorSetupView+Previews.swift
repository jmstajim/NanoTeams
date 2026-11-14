import SwiftUI

/// The Autovisor start page's states from mocked facts, for a design review rendered through
/// `./render_preview.sh` — one `#Preview` per state, one per line (the renderer picks by index).
// periphery:ignore - used in #Preview macros below
enum AutovisorSetupPreview {
    static func builtIn() -> AutovisorSetupPresentation {
        presentation(driver: .builtInModel)
    }

    /// An agent holds a token and the server listens: nothing is missing.
    static func externalReady() -> AutovisorSetupPresentation {
        presentation(driver: .externalAgent, agentCount: 1)
    }

    static func externalWithNoAgent() -> AutovisorSetupPresentation {
        presentation(driver: .externalAgent, agentCount: 0)
    }

    static func externalWithServerOff() -> AutovisorSetupPresentation {
        presentation(driver: .externalAgent, externalAgentsEnabled: false, listenerState: .stopped, agentCount: 1)
    }

    private static func presentation(
        driver: AutovisorDriver,
        externalAgentsEnabled: Bool = true,
        listenerState: HostedMCPListenerState = .listening(port: 47321),
        agentCount: Int = 1
    ) -> AutovisorSetupPresentation {
        AutovisorSetupPresentation.make(
            driver: driver,
            persistedGoal: "",
            externalAgentsEnabled: externalAgentsEnabled,
            listenerState: listenerState,
            configuredPort: 47321,
            agentCount: agentCount)
    }
}

/// The page with the environment its goal composer reads.
// periphery:ignore - used in #Preview macros below
private struct AutovisorSetupPreviewHost: View {
    let presentation: AutovisorSetupPresentation
    @State private var store = PreviewStore.make()

    var body: some View {
        AutovisorSetupContent(presentation: presentation, actions: .inert)
            .environment(store)
            .environment(store.engineState)
            .environment(store.configuration)
            .environment(store.streamingPreviewManager)
            .environment(DictationService())
            .frame(width: 800, height: 760)
    }
}

#Preview("Built-in model") { AutovisorSetupPreviewHost(presentation: AutovisorSetupPreview.builtIn()) }
#Preview("External agent — ready") { AutovisorSetupPreviewHost(presentation: AutovisorSetupPreview.externalReady()) }
#Preview("External agent — no agent yet") { AutovisorSetupPreviewHost(presentation: AutovisorSetupPreview.externalWithNoAgent()) }
#Preview("External agent — server off") { AutovisorSetupPreviewHost(presentation: AutovisorSetupPreview.externalWithServerOff()) }
