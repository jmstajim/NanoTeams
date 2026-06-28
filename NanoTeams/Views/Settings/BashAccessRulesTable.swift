import SwiftUI

/// The shared `bash` access rules as one Folder × {Read, Write} table. The same
/// `BashSandboxPermissions` drives BOTH the Seatbelt sandbox (which enforces the
/// grants) and the judge (which is told the confinement and evaluates each command
/// against it) — so this single table is the source of truth for both.
///
/// Every read/write cell is a tappable `[x]`/`[ ]` chip except credential WRITE,
/// which is always blocked (a fixed dash). Always editable — the rules apply to the
/// judge whether or not the sandbox is enforcing them, so the table is never disabled.
struct BashAccessRulesTable: View {
    @Binding var permissions: BashSandboxPermissions

    private enum Cell {
        case blocked
        case editable(Binding<Bool>)
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
            GridRow {
                Text("Folder")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                Text("Read")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .gridColumnAlignment(.center)
                Text("Write")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .gridColumnAlignment(.center)
            }

            row("Work folder", "Your project files",
                read: .editable($permissions.workFolderRead),
                write: .editable($permissions.workFolderWrite))
            row("Temp directories", "TMPDIR, /private/tmp",
                read: .editable($permissions.tempRead),
                write: .editable($permissions.tempWrite))
            row("Credential stores", "~/.ssh, ~/.aws, Keychain, .netrc",
                read: .editable($permissions.credentialRead),
                write: .blocked)
            row("Home folder", "Your user folder (~), outside the project",
                read: .editable($permissions.homeRead),
                write: .editable($permissions.homeWrite))
            row("Everything else", "System paths outside home + the project",
                read: .editable($permissions.everythingElseRead),
                write: .editable($permissions.everythingElseWrite))
        }
    }

    private func row(_ name: String, _ subtitle: String, read: Cell, write: Cell) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Typography.subheadline)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            cell(read)
            cell(write)
        }
    }

    @ViewBuilder
    private func cell(_ cell: Cell) -> some View {
        switch cell {
        case .blocked:
            // Locked "off" — a muted dash, clearly not a toggle.
            glyphChip("—", foreground: Colors.textTertiary, background: .clear)
                .frame(maxWidth: .infinity)
                .help("Always blocked")
        case .editable(let binding):
            Button {
                binding.wrappedValue.toggle()
            } label: {
                glyphChip(
                    binding.wrappedValue ? "[x]" : "[ ]",
                    foreground: binding.wrappedValue ? Colors.accent : Colors.textTertiary,
                    background: Colors.surfaceElevated)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private func glyphChip(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle.squircle(CornerRadius.micro)
                    .fill(background)
            )
    }
}
