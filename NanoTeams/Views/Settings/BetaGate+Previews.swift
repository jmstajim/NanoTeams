import SwiftUI

/// The gate's two states, drawn from the pure copy with no store behind them — the whole reason
/// `BetaGateScreen` takes a `BetaGateCopy` rather than reading the configuration itself.
#Preview("Beta gate — External Agents") {
    BetaGateScreen(copy: BetaGateCopy.copy(for: .externalAgents), onAccept: {})
        .frame(width: 700, height: 680)
}

#Preview("Beta gate — MCP Servers") {
    BetaGateScreen(copy: BetaGateCopy.copy(for: .mcpServers), onAccept: {})
        .frame(width: 700, height: 680)
}
