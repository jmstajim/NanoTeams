import AppKit
import SwiftUI

/// The exact prompt every benchmark sample sends, readable and copyable.
///
/// The figures in the leaderboard are only interpretable against the workload behind them, and
/// until this sheet existed that workload was described in a hover tip and nowhere shown. Chrome
/// mirrors `BashJudgePreviewSheet` — the same feature one settings tab over.
///
/// What is on screen is `BenchmarkPrompt.canonicalText`: the wire string generator called with a
/// marked placeholder instead of a nonce. Not a reconstruction — the same function the runner
/// calls, so the two cannot drift.
struct BenchmarkPromptSheet: View {
    /// The target the run card is pointed at, so the request facet shows the body THIS screen
    /// would post — not a generic one. Passed in rather than rebuilt here: the settings view
    /// already owns the one config `start()` uses, and two spellings of it would drift.
    let config: LLMConfig

    @Environment(\.dismiss) private var dismiss

    /// Which of the two questions is on screen: what the model is asked, or what is sent.
    @State private var facet: Facet = .prompt

    nonisolated enum Facet: String, CaseIterable, Equatable {
        case prompt = "Prompt"
        case request = "Request body"
    }

    /// Outcome of the last copy, cleared two seconds later. This is the app's only copy button
    /// with feedback, and it earns it: the payload is eleven thousand invisible characters, so a
    /// silent success is indistinguishable from a dead button — and a silent FAILURE is
    /// indistinguishable from both.
    @State private var lastCopy: CopyOutcome?

    nonisolated enum CopyOutcome: Equatable {
        case copied
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Benchmark Prompt", marker: true)

                Spacer()

                Button {
                    copy()
                } label: {
                    Label(Self.copyLabel(lastCopy), systemImage: Self.copyIcon(lastCopy))
                        .font(Typography.caption)
                }
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.m)

            TerminalDivider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                TerminalSegmentedPicker(
                    selection: $facet,
                    options: Facet.allCases.map { ($0, $0.rawValue) })
                Text(Self.factsLine)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                Text(Self.explanation(for: facet))
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)

            TerminalDivider()

            // Plain `Text` in a `ScrollView`, deliberately: read-only rules out `TextEditor`
            // (CLAUDE.md #27), and an `NSScrollView`-backed representable would drag #50's
            // offscreen-mask trap into a pane that renders 11 000 characters. Selection spans the
            // whole payload because it is one text node rather than a lazy stack of lines.
            ScrollView {
                Text(shownText)
                    .font(Typography.monoCaption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Spacing.s)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: facet) {
            // The button describes the LAST copy, and after a facet switch that description is
            // about a payload no longer on screen.
            lastCopy = nil
        }
        .task(id: lastCopy) {
            guard lastCopy != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            // `try?` swallows the cancellation (CLAUDE.md #88), so without this a second copy's
            // restarted timer would be cleared by the first one's expiry.
            guard !Task.isCancelled else { return }
            lastCopy = nil
        }
    }

    /// Exactly what is on screen — nothing prepended, nothing appended.
    ///
    /// A header explaining the marker would make the pane and the clipboard disagree, and would
    /// corrupt the paste for the one use this button has: putting the workload into another tool.
    /// `setString` returns whether the write landed, and this is the one site in the app that
    /// reads it: the button's whole job is to say what happened, so discarding the answer would
    /// let it report a success the pasteboard refused.
    private func copy() {
        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(shownText, forType: .string)
        lastCopy = wrote ? .copied : .failed
    }

    /// Exactly what the pane is showing — the copy button and the pane can never disagree,
    /// because there is one value and both read it.
    private var shownText: String {
        switch facet {
        case .prompt: BenchmarkPrompt.canonicalText
        case .request: BenchmarkWireBody.json(config: config) ?? BenchmarkWireBody.unavailable
        }
    }

    static func copyLabel(_ outcome: CopyOutcome?) -> String {
        switch outcome {
        case .none: "Copy"
        case .copied: "Copied"
        case .failed: "Copy failed"
        }
    }

    static func copyIcon(_ outcome: CopyOutcome?) -> String {
        switch outcome {
        case .none: "doc.on.doc"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    // MARK: - Pure presentation (unit-tested)

    /// Interpolated from the shipped constants, never typed: a facts line that states a ceiling
    /// the runs no longer use is worse than no facts line.
    static var factsLine: String {
        [
            "\(BenchmarkPrompt.id) v\(BenchmarkPrompt.version)",
            "\(BenchmarkPrompt.charactersPerSample) characters",
            "one user turn",
            "no system prompt",
            "no tools",
            "output capped at \(BenchmarkPrompt.maxOutputTokens) tokens",
        ].joined(separator: " · ")
    }

    /// One sentence for the prompt facet, two for the request one — the facts line carries the
    /// rest, and "everything else is what is sent" was the pane restating its own premise.
    ///
    /// What was here before explained the warm-up, the prompt's depth and the tokenizer caveat —
    /// all true, all already stated where they are load-bearing (`BenchmarkPrompt`,
    /// `BenchmarkWarmUpPolicy`), and none of it answerable by looking at the pane below. A reader
    /// who has to get through a paragraph before the text starts reads neither.
    static func explanation(for facet: Facet) -> String {
        switch facet {
        case .prompt: promptExplanation
        case .request:
            "The JSON body posted for one sample, built by the same code the runner calls. The "
                + "facts above, in bytes."
        }
    }

    /// Above the text rather than below it: the marker is on line 1, and an explanation 112 lines
    /// down is not an explanation.
    static var promptExplanation: String {
        "\(BenchmarkPrompt.noncePlaceholder) is the only part that changes — "
            + "\(BenchmarkPrompt.nonceLength) fresh characters per sample, so the request cannot hit "
            + "the server's prompt cache."
    }
}
