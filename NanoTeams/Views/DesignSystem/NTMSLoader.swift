import SwiftUI

// MARK: - Glow Colors (design-system palette)

/// Shared gradient colors for glow effects.
enum GlowPalette {
    static let colors: [Color] = [
        Colors.cyan,
        .clear,
        .clear,
        .clear,
        .clear,

        Colors.info,
        .clear,
        .clear,
        .clear,
        .clear,

        Colors.artifact,
        .clear,
        .clear,
        .clear,
        .clear,

        Colors.purple,
        .clear,
        .clear,
        .clear,
        .clear,

        Colors.emerald,
        .clear,
        .clear,
        .clear,
        .clear,
    ]
}

// MARK: - NTMSLoader

/// A branded loading indicator that renders a glowing, animated lobe-based spinner.
///
/// `NTMSLoader` uses a rotating angular gradient and a slowly counter-rotating shape
/// to create a more distinctive loading state than the system spinner. Choose one of
/// the provided ``Size`` presets for the intended presentation context.
///
/// Available sizes:
/// - `.inline`: For compact inline status indicators.
/// - `.mini`: For small status affordances.
/// - `.small`: For compact controls and buttons.
/// - `.regular`: The default size for general loading states.
/// - `.large`: For prominent loading states.
/// - `.extraLarge`: For splash screens or onboarding.
///
/// Example:
/// ```swift
/// NTMSLoader()              // Uses the default `.regular` size
/// NTMSLoader(.small)        // Suitable for compact controls
/// NTMSLoader(.large)        // Suitable for full-screen loading states
/// ```
struct NTMSLoader: View {
    /// Pre-defined size presets mirroring ControlSize semantics.
    enum Size {
        /// Matches system icon size for inline status indicators (14×14).
        case inline
        case mini
        case small
        case regular
        case large
        case extraLarge

        var width: CGFloat {
            switch self {
            case .inline:     return 14
            case .mini:       return 24
            case .small:      return 36
            case .regular:    return 60
            case .large:      return 100
            case .extraLarge: return 200
            }
        }

        var height: CGFloat {
            switch self {
            case .inline: return 14
            default:      return width / 2
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .inline:     return 1
            case .mini:       return 1
            case .small:      return 1
            case .regular:    return 2
            case .large:      return 2
            case .extraLarge: return 3
            }
        }
    }

    private let size: Size

    init(_ size: Size = .regular) {
        self.size = size
    }

    /// Color rotation period in seconds (faster).
    private let colorPeriod: Double = 3.0
    /// Shape rotation period in seconds (slower, reverse direction).
    private let shapePeriod: Double = 10.0

    @State private var startDate = Date.now

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let colorAngle = elapsed / colorPeriod * 360
            let shapeAngle = -(elapsed / shapePeriod * 360)

            let gradient = AngularGradient(
                colors: GlowPalette.colors,
                center: .center,
                startAngle: .degrees(colorAngle),
                endAngle: .degrees(colorAngle + 360)
            )

            lobeShape
                .stroke(lineWidth: size.lineWidth)
                .fill(gradient)
                .rotationEffect(.degrees(shapeAngle))
        }
        .frame(width: size.width, height: size.height)
    }

    private var lobeShape: LobeShape { LobeShape() }
}

// MARK: - Previews

#Preview("NTMSLoader — All Sizes") {
    VStack(spacing: 24) {
        ForEach(
            [NTMSLoader.Size.inline, .mini, .small, .regular, .large, .extraLarge],
            id: \.width
        ) { size in
            HStack {
                Text("\(size)")
                    .font(.caption.monospaced())
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(.secondary)
                NTMSLoader(size)
            }
        }
    }
    .padding(40)
    .background(Colors.surfacePrimary)
}

// MARK: - Lobe Shape

/// Five-lobed rose curve shape.
private struct LobeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let half = min(rect.width, rect.height) / 2 * 0.9
        let segments = 100

        var path = Path()
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments) * .pi * 2
            let r = abs(cos(2.5 * t))
            let pt = CGPoint(x: cx + r * cos(t) * half, y: cy + r * sin(t) * half)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

