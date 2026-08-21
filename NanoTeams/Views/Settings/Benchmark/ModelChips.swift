import SwiftUI

/// The two little capsules that sit beside a model's name where no column heading can name them:
/// its file format and its quantization, exactly as the server spells them.
///
/// Two render sites left — the sweep's model list and the Run tab's picker. The benchmark tables
/// used to draw the same pair here too, glued to the model name; they now hold `Format` and
/// `Quantization` columns of their own, which is what a heading is for. What both surfaces still
/// share is the SPELLING rule, and that lives in `ModelDescriptorText` rather than here, so a
/// capsule and a cell can never disagree about the same value.
nonisolated enum ModelChips {

    /// A chip beside the model name, with a stable identity of its own: two chips can spell the
    /// same text (an `MXFP4` quantization beside a hypothetical `mxfp4` format), so `ForEach`
    /// keys on which HALF of the pair a chip is, never on its content (CLAUDE.md #22).
    struct Chip: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case format, quantization }
        let kind: Kind
        let text: String
        var id: String { kind.rawValue }
    }

    /// File format first, then quantization — both spelled by `ModelDescriptorText`. A missing half
    /// is dropped rather than dashed: a chip is a claim, and an em-dash in a capsule reads as a
    /// value the server never reported. (The table columns make the opposite choice, and for the
    /// same reason — see `ModelDescriptorText`.)
    static func chips(format: String?, quantization: String?) -> [Chip] {
        var chips: [Chip] = []
        if let format = ModelDescriptorText.format(format) {
            chips.append(Chip(kind: .format, text: format))
        }
        if let quantization = ModelDescriptorText.quantization(quantization) {
            chips.append(Chip(kind: .quantization, text: quantization))
        }
        return chips
    }
}

/// Renders `ModelChips.chips` inline. Draws nothing at all when the server reported neither half,
/// so a row for a model nobody has asked about is simply a name — never a placeholder.
struct ModelChipsRow: View {
    let format: String?
    let quantization: String?

    init(format: String?, quantization: String?) {
        self.format = format
        self.quantization = quantization
    }

    /// Convenience for the two call sites that already hold a descriptor. A nil `info` is the
    /// common case (nothing fetched yet), and it renders as nothing.
    init(_ info: LLMModelInfo?) {
        self.init(format: info?.format, quantization: info?.quantization)
    }

    var body: some View {
        ForEach(ModelChips.chips(format: format, quantization: quantization)) { chip in
            Text(chip.text)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textSecondary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.neutralTint))
                .fixedSize()
        }
    }
}
