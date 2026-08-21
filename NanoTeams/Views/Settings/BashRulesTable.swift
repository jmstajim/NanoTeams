import SwiftUI

/// The custom command rules as one editable table: each row is a command pattern
/// plus what to do with it (Deny / Ask / Allow). Backs the same three arrays
/// (`bashDenyRules` / `bashAskRules` / `bashAllowRules`) the gate evaluates —
/// precedence stays fixed deny → ask → allow regardless of row order.
///
/// Rows are the editing source: seeded once from the bindings at init, then every
/// edit re-partitions them back into the three arrays. Empty patterns are dropped
/// on write (a half-typed new row stays editable but isn't persisted).
struct BashRulesTable: View {
    @Binding var denyRules: [String]
    @Binding var askRules: [String]
    @Binding var allowRules: [String]

    enum Decision: CaseIterable, Hashable {
        case deny, ask, allow
        var label: String {
            switch self {
            case .deny: return "Deny"
            case .ask: return "Ask"
            case .allow: return "Allow"
            }
        }
    }

    private struct RuleRow: Identifiable {
        let id = UUID()
        var pattern: String
        var decision: Decision
    }

    @State private var rows: [RuleRow]

    init(denyRules: Binding<[String]>, askRules: Binding<[String]>, allowRules: Binding<[String]>) {
        self._denyRules = denyRules
        self._askRules = askRules
        self._allowRules = allowRules
        self._rows = State(initialValue:
            denyRules.wrappedValue.map { RuleRow(pattern: $0, decision: .deny) }
                + askRules.wrappedValue.map { RuleRow(pattern: $0, decision: .ask) }
                + allowRules.wrappedValue.map { RuleRow(pattern: $0, decision: .allow) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach($rows) { $row in
                HStack(spacing: Spacing.s) {
                    TextField("command or pattern", text: $row.pattern)
                        .textFieldStyle(.plain)
                        .terminalField()
                        .frame(maxWidth: .infinity)
                        .onChange(of: row.pattern) { _, _ in commit() }

                    TerminalSegmentedPicker(
                        selection: $row.decision,
                        options: Decision.allCases.map { ($0, $0.label) })
                        .frame(width: 170)
                        .onChange(of: row.decision) { _, _ in commit() }

                    Button {
                        delete(row.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typography.caption2.weight(.semibold))
                            .foregroundStyle(Colors.textTertiary)
                            .frame(width: Spacing.standard, height: Spacing.standard)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove this rule")
                }
            }

            SettingsPillButton(title: "Add rule", icon: "plus") {
                rows.append(RuleRow(pattern: "", decision: .allow))
            }
        }
    }

    private func delete(_ id: UUID) {
        rows.removeAll { $0.id == id }
        commit()
    }

    private func commit() {
        denyRules = patterns(for: .deny)
        askRules = patterns(for: .ask)
        allowRules = patterns(for: .allow)
    }

    private func patterns(for decision: Decision) -> [String] {
        rows
            .filter { $0.decision == decision }
            .map { $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
