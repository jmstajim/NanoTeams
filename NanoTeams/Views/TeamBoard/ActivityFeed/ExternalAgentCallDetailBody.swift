import SwiftUI

/// The window body for `ActivityDetailWindow.externalAgentCall`: one external Autovisor agent's
/// call in full, loaded when the window opens.
///
/// Loaded, it is the same `ToolCallDetailBody` a role's tool call opens — Arguments and Result,
/// Pretty/Raw, the error tint — so an agent's call reads exactly like a role's. A call that will
/// not load says so HERE, in the window the person just opened: the app's error banner is
/// cleared while any external call is in flight, and an agent waiting for events always has
/// one, so a failure routed there would read as a tap that did nothing.
struct ExternalAgentCallDetailBody: View {
    let toolName: String
    let isError: Bool
    let createdAt: Date
    let load: @MainActor () async -> ExternalAutovisorFullCall?

    enum Phase: Equatable {
        case loading
        case loaded(ExternalAutovisorFullCall)
        case unavailable
    }

    @State private var phase: Phase = .loading

    /// What a finished load shows. Static so the mapping is tested without a window.
    static func phase(after load: @MainActor () async -> ExternalAutovisorFullCall?) async -> Phase {
        guard let call = await load() else { return .unavailable }
        return .loaded(call)
    }

    var body: some View {
        content
            .task { phase = await Self.phase(after: load) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: Spacing.s) {
                NTMSLoader(.small)
                Text("Loading…")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textSecondary)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let call):
            ToolCallDetailBody(
                toolName: toolName,
                argumentsJSON: call.arguments,
                resultJSON: call.response,
                isError: isError,
                createdAt: createdAt
            )
        case .unavailable:
            NTMSEmptyState(
                title: "Couldn't load the full call",
                message: Self.unavailableMessage,
                systemImage: "exclamationmark.triangle"
            )
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static let unavailableMessage =
        "The request and response of this call are no longer on disk: its task was deleted, the work folder changed, or the file could not be read."
}
