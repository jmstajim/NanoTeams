import SwiftUI

// MARK: - Terminal Controls
//
// Custom Design-System replacements for the native macOS controls (Toggle,
// Button, Stepper, Slider, Picker). The native controls carry system chrome
// (vibrancy, the default blue accent, rounded-bezel popups) that fights the
// terminal aesthetic. These use DS tokens only — one lavender accent, sharp
// squircle corners, hairline borders, mono type, Reduce-Motion aware.

// MARK: - Toggle (pill switch)

/// Checkbox-style terminal switch: `[x]` ON / `[ ]` OFF, drawn as literal mono
/// characters per the design system's Switch spec (`components/forms/Switch.jsx`).
/// Applied via `.toggleStyle(.terminal)`; because `ToggleStyle` propagates
/// through the environment, setting it once at a window root restyles every
/// `Toggle` beneath it with no call-site changes.
struct TerminalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // @State/@Environment only work inside a real View, not on the style
        // struct itself — so the body lives in a nested view.
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: Spacing.s) {
                configuration.label
                Spacer(minLength: Spacing.s)
                switchVisual(isOn: configuration.isOn)
            }
            .opacity(isEnabled ? 1 : 0.5)
            // Tap anywhere on the row (label included) toggles, matching the native control.
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(reduceMotion ? nil : Animations.quick) {
                    configuration.isOn.toggle()
                }
            }
            // Keep a native, fully-described toggle in the accessibility tree while
            // the visual is custom (`$isOn` is the projected binding on the config).
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        // `[x]` / `[ ]` — bold mono brackets, signal color when on, tertiary when off.
        // Fixed-width text so the row doesn't shimmer when the inner glyph swaps.
        private func switchVisual(isOn: Bool) -> some View {
            Text(isOn ? "[x]" : "[ ]")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? Colors.accent : Colors.textTertiary)
                .monospacedDigit()
                .contentTransition(.identity)
        }
    }
}

extension ToggleStyle where Self == TerminalToggleStyle {
    static var terminal: TerminalToggleStyle { TerminalToggleStyle() }
}

// MARK: - Toggle (chip strip variant)

/// Chip variant of the DS toggle — used in multi-select chip strips like the
/// weekday picker in `TaskAutomationSheet` (Mo/Tu/We/Th/Fr/Sa/Su). The default
/// `.terminal` style renders `[x]/[ ]` plus label on a row; that idiom doesn't
/// fit a 7-cell strip. This style renders the label itself as a squircle chip
/// — accent fill + textOnAccent when ON, surfaceElevated + hairline border
/// when OFF. Same accessibilityRepresentation so VO still reads the row as a
/// native Toggle.
struct TerminalChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(Typography.term2xs.weight(.medium))
                .tracking(Typography.labelTracking)
                .foregroundStyle(foreground)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
                .frame(minWidth: 28)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small).fill(background)
                )
                .overlay(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .strokeBorder(border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : Animations.quick) {
                        configuration.isOn.toggle()
                    }
                }
                .trackHover($isHovered)
                .animationWithReduceMotion(Animations.quick, value: isHovered)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }
                }
                .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        }

        private var foreground: Color {
            if configuration.isOn { return Colors.textOnAccent }
            return Colors.textSecondary
        }

        private var background: Color {
            if configuration.isOn { return Colors.accent }
            return isHovered ? Colors.surfaceHover : Colors.surfaceElevated
        }

        private var border: Color {
            configuration.isOn ? .clear : Colors.borderSubtle
        }
    }
}

extension ToggleStyle where Self == TerminalChipToggleStyle {
    /// Multi-select chip-strip variant of `.terminal` — for compact label-as-chip
    /// affordances (weekday picker, day-of-week multi-select, tag pickers).
    static var terminalChip: TerminalChipToggleStyle { TerminalChipToggleStyle() }
}

// MARK: - Button

/// DS button style. Variants mirror the design's Button spec: `primary` (the one
/// accent-filled action), `secondary` (neutral elevated), `ghost` (text until
/// hover), `danger` (terracotta outline). Replaces `.borderedProminent`/`.bordered`.
struct TerminalButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger }
    var variant: Variant = .secondary

    func makeBody(configuration: Configuration) -> some View {
        // Hover/enabled state must live in a real View, not the style struct.
        StyleBody(configuration: configuration, variant: variant)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            // `Button.jsx` default: `brackets = true` for every variant. The
            // bracket spans render at `font-weight: var(--nt-fw-regular)` +
            // `opacity: 0.55` so the cell reads as `[ resume ]` — TUI feel
            // that distinguishes a terminal button from a filled mac pill.
            // Brackets use `\u{00A0}` non-breaking spaces matching DS's
            // `[&nbsp;` / `&nbsp;]` whitespace.
            HStack(spacing: 0) {
                bracket("[\u{00A0}")
                configuration.label
                    .font(Typography.subheadline.weight(.semibold))
                bracket("\u{00A0}]")
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs + 1)
            .frame(minHeight: Spacing.l + Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small).fill(background)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small).strokeBorder(border, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
            .trackHover($isHovered)
            .animationWithReduceMotion(Animations.quick, value: isHovered)
        }

        /// Bracket glyph at DS-spec `opacity: 0.55` + regular weight.
        @ViewBuilder private func bracket(_ glyph: String) -> some View {
            Text(glyph)
                .font(Typography.subheadline.weight(.regular))
                .opacity(0.55)
        }

        private var foreground: Color {
            switch variant {
            case .primary: return Colors.textOnAccent
            // DS spec — secondary inverts to reverse-video on hover:
            // `.nt-btn--secondary:hover { background: var(--nt-text); color: var(--nt-bg); }`
            case .secondary: return isHovered ? Colors.surfaceBackground : Colors.textPrimary
            case .ghost: return Colors.accent
            case .danger: return Colors.error
            }
        }

        private var background: Color {
            switch variant {
            case .primary: return Colors.accent
            // Transparent at rest per `Button.jsx` (`background: transparent`);
            // reverse-video on hover so the secondary button reads as a TUI
            // bracket cell, not a filled macOS pill.
            case .secondary: return isHovered ? Colors.textPrimary : .clear
            case .ghost: return isHovered ? Colors.accentTint : .clear
            case .danger: return isHovered ? Colors.errorTint : .clear
            }
        }

        private var border: Color {
            switch variant {
            case .primary: return .clear
            // `--nt-border-strong` at rest, becomes textPrimary on hover to
            // match the reverse-video fill — single 1px outline at all times.
            case .secondary: return isHovered ? Colors.textPrimary : Colors.borderStrong
            case .ghost: return .clear
            case .danger: return Colors.errorBorder
            }
        }
    }
}

extension ButtonStyle where Self == TerminalButtonStyle {
    static var terminalPrimary: TerminalButtonStyle { .init(variant: .primary) }
    static var terminalSecondary: TerminalButtonStyle { .init(variant: .secondary) }
    static var terminalGhost: TerminalButtonStyle { .init(variant: .ghost) }
    static var terminalDanger: TerminalButtonStyle { .init(variant: .danger) }
}

// MARK: - Stepper (chevron up/down)

/// The DS stepper control — a stacked `+` / `−` text-glyph pair (mono characters,
/// not SF Symbols — terminal idiom). Replaces the native `Stepper`'s bezel.
/// Used by `SettingsStepperControl` and any standalone stepper.
struct TerminalStepperButtons: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Optional a11y value override (e.g. the "Unlimited" sentinel string).
    var valueText: String? = nil
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            glyphButton("+", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step); onChange?()
            }
            Rectangle().fill(Colors.borderSubtle).frame(height: 1)
            glyphButton("−", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step); onChange?()
            }
        }
        .frame(width: 22)
        .background(Colors.surfaceElevated, in: RoundedRectangle.squircle(CornerRadius.small))
        .overlay(
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(Colors.borderSubtle, lineWidth: 1)
        )
        // Present as ONE adjustable element (like the native Stepper) rather than
        // two unlabelled glyph buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityValue(valueText ?? "\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
            onChange?()
        }
    }

    private func glyphButton(_ glyph: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(enabled ? Colors.textSecondary : Colors.textQuaternary)
                .frame(width: 22, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Slider

/// A custom DS slider: hairline rectangular track + accent fill + draggable
/// square knob (sharp 1px-radius cell — terminal idiom), with optional square
/// tick marks when `step` divides the range into a small count.
struct TerminalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil

    private let trackHeight: CGFloat = 4
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = fractionFor(value)
            let knobX = knob / 2 + fraction * max(0, width - knob)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Colors.surfaceElevated)
                    .overlay(Rectangle().strokeBorder(Colors.borderSubtle, lineWidth: 1))
                    .frame(height: trackHeight)

                Rectangle()
                    .fill(Colors.accent)
                    .frame(width: max(trackHeight, knobX), height: trackHeight)

                if let ticks = tickFractions {
                    ForEach(ticks.indices, id: \.self) { i in
                        Rectangle()
                            .fill(Colors.textQuaternary)
                            .frame(width: 2, height: 2)
                            .offset(x: knob / 2 + ticks[i] * max(0, width - knob) - 1)
                    }
                }

                RoundedRectangle.squircle(CornerRadius.accent)
                    .fill(Colors.accent)
                    .overlay(
                        RoundedRectangle.squircle(CornerRadius.accent)
                            .strokeBorder(Colors.surfacePrimary, lineWidth: 2)
                    )
                    .frame(width: knob, height: knob)
                    .offset(x: knobX - knob / 2)
                    .shadow(.card)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, (g.location.x - knob / 2) / max(1, width - knob)))
                        value = valueFor(fraction: f)
                    }
            )
        }
        .frame(height: knob)
        .accessibilityRepresentation {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }

    private func fractionFor(_ v: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    private func valueFor(fraction f: CGFloat) -> Double {
        let span = range.upperBound - range.lowerBound
        var v = range.lowerBound + Double(f) * span
        if let step, step > 0 {
            v = (v / step).rounded() * step
        }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private var tickFractions: [CGFloat]? {
        guard let step, step > 0 else { return nil }
        let count = (range.upperBound - range.lowerBound) / step
        guard count >= 2, count <= 24 else { return nil }
        let n = Int(count.rounded())
        return (0...n).map { CGFloat(Double($0) / Double(n)) }
    }
}

// MARK: - Picker (menu dropdown)

/// A DS dropdown picker — a custom-labelled `Menu` (current value + `⌄` chevron
/// glyph) over a transient option menu. Replaces the native popup `Picker`'s
/// bezel. Options are `(value, label)` pairs.
struct TerminalPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var placeholder: String = "—"

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(currentLabel)
                    .font(Typography.termSm)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Colors.accent)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs + 1)
            .frame(minHeight: Spacing.l + Spacing.s)
            .background(Colors.surfaceElevated, in: RoundedRectangle.squircle(CornerRadius.small))
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Segmented (tab-style picker)

/// A DS segmented control for small mutually-exclusive choices that read as a
/// tab strip (not a dropdown). Custom-drawn — no native segmented bezel.
struct TerminalSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : Animations.quick) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Typography.termXs.weight(.medium))
                        .foregroundStyle(isSelected ? Colors.textOnAccent : Colors.textSecondary)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xxs)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle.squircle(CornerRadius.micro)
                                .fill(isSelected ? Colors.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(Spacing.xxs)
        .background(Colors.surfaceElevated, in: RoundedRectangle.squircle(CornerRadius.small))
        .overlay(
            RoundedRectangle.squircle(CornerRadius.small)
                .strokeBorder(Colors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - TextField (terminal chrome)

/// `terminalField()` styles a SwiftUI `TextField` after `.textFieldStyle(.plain)`
/// with the DS chrome: 2pt squircle, `surfacePrimary` fill, 1px `borderSubtle`
/// hairline, mono content. Replaces `.textFieldStyle(.roundedBorder)`'s native
/// bezel everywhere. Pair with `.textFieldStyle(.plain)` at the call site so
/// AppKit's bezel disappears before our chrome is drawn over it.
struct TerminalFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typography.termBase)
            .foregroundStyle(Colors.textPrimary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs + 1)
            .frame(minHeight: Spacing.l + Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    /// DS chrome for a `TextField`. Use with `.textFieldStyle(.plain)` to drop
    /// the native bezel first.
    func terminalField() -> some View { modifier(TerminalFieldChrome()) }
}

// MARK: - DatePicker (terminal chrome)

/// A DS date/time picker — the native `DatePicker` rendered `.field` style and
/// wrapped in our chrome (squircle, hairline border, `surfaceElevated` fill,
/// accent caret). Reuses native interaction (popover calendar / spinner). Lives
/// here so every call site reads `TerminalDatePicker(...)` instead of repeating
/// the same chrome wrap inline.
struct TerminalDatePicker: View {
    @Binding var selection: Date
    var components: DatePickerComponents = [.date, .hourAndMinute]
    var label: String = ""

    var body: some View {
        DatePicker(label, selection: $selection, displayedComponents: components)
            .labelsHidden()
            .datePickerStyle(.field)
            .font(Typography.termSm)
            .foregroundStyle(Colors.textPrimary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.l + Spacing.s)
            .background(Colors.surfaceElevated, in: RoundedRectangle.squircle(CornerRadius.small))
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Previews

#Preview("Terminal Controls") {
    @Previewable @State var enterSendsMessage = true
    @Previewable @State var autovisor = false
    @Previewable @State var iterations = 12
    @Previewable @State var temperature = 0.4
    @Previewable @State var teamName = "Engineering"
    @Previewable @State var when = Date.now

    VStack(alignment: .leading, spacing: Spacing.l) {
        TerminalPane(title: "Input") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Toggle(isOn: $enterSendsMessage) {
                    Text("Enter sends message").font(Typography.termBase)
                }
                Toggle(isOn: $autovisor) {
                    Text("Enable Autovisor").font(Typography.termBase)
                }
            }
            .toggleStyle(.terminal)
        }

        TerminalPane(title: "Text Field") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Team name").font(Typography.termXs).foregroundStyle(Colors.textTertiary)
                TextField("Enter team name", text: $teamName)
                    .textFieldStyle(.plain)
                    .terminalField()
            }
        }

        TerminalPane(title: "Stepper") {
            HStack(spacing: Spacing.m) {
                Text("Max iterations").font(Typography.termBase)
                Spacer()
                Text("\(iterations)")
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textPrimary)
                    .monospacedDigit()
                TerminalStepperButtons(value: $iterations, range: 0...100)
            }
        }

        TerminalPane(title: "Slider") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Temperature").font(Typography.termBase)
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.accent)
                        .monospacedDigit()
                }
                TerminalSlider(value: $temperature, range: 0...1, step: 0.1)
            }
        }

        TerminalPane(title: "Date / Time") {
            HStack(spacing: Spacing.m) {
                Text("Fire at").font(Typography.termBase)
                Spacer()
                TerminalDatePicker(selection: $when, components: [.date, .hourAndMinute])
            }
        }
    }
    .padding(Spacing.xl)
    .frame(width: 560)
    .background(Colors.surfacePrimary)
}
