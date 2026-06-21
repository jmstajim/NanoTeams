import SwiftUI

// MARK: - MonoLabel

/// The design system's signature labelling device: small UPPERCASE monospace
/// text with wide tracking and an optional `▌` marker / trailing hairline rule.
/// Use it for section headers, field labels, and graph annotations.
///
/// Write the text in normal case — it's uppercased here.
struct MonoLabel: View {
    enum Size { case xs, sm }

    let text: String
    var size: Size = .sm
    /// Tint the label with the lavender accent instead of tertiary text.
    var accent: Bool = false
    /// Stretch full-width with a hairline rule after the text (section separator).
    var rule: Bool = false
    /// Leading `▌` accent marker.
    var marker: Bool = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                if marker {
                    Text("▌")
                        .font(font)
                        .foregroundStyle(Colors.accent)
                        .accessibilityHidden(true)
                }
                Text(text.uppercased())
                    .font(font)
                    .fontWeight(.medium)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(accent ? Colors.accent : Colors.textTertiary)
            }
            .fixedSize()

            if rule {
                Rectangle()
                    .fill(Colors.borderSubtle)
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    private var font: Font {
        switch size {
        case .xs: Typography.term2xs
        case .sm: Typography.termXs
        }
    }
}

// MARK: - Prompt Marker

/// A leading terminal prompt marker (`›`) in the accent color, optionally with a
/// blinking block cursor. Used in inputs and command surfaces.
struct PromptMarker: View {
    var cursor: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = true

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(TerminalGlyph.prompt)
                .foregroundStyle(Colors.accent)
            if cursor {
                Text(TerminalGlyph.cursor)
                    .foregroundStyle(Colors.accent)
                    .opacity(blink ? 1 : 0)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.55).repeatForever()) { blink.toggle() }
                    }
            }
        }
        .font(Typography.termBase)
        .accessibilityHidden(true)
    }
}

#Preview("MonoLabel") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        MonoLabel(text: "Activity feed")
        MonoLabel(text: "Live", accent: true, marker: true)
        MonoLabel(text: "Roles", rule: true)
        MonoLabel(text: "run #4", size: .xs)
        HStack { PromptMarker(cursor: true); Text("describe your task…").font(Typography.termBase).foregroundStyle(Colors.textTertiary) }
    }
    .padding(Spacing.l)
    .frame(width: 360, alignment: .leading)
    .background(Colors.surfaceCard)
}
