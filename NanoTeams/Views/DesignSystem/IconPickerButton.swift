import SwiftUI

/// Compact SF Symbol picker — shows selected icon as a button, opens popover grid on click.
struct IconPickerButton: View {
    @Binding var selectedIcon: String
    var iconForeground: Color = .white
    var iconBackground: Color = Colors.accent
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var gridItemSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var popoverWidth: CGFloat = 370
    @ScaledMetric(relativeTo: .body) private var popoverHeight: CGFloat = 340
    @State private var showingPicker = false

    static let icons: [String] = [
        // Documents — specs, plans, reports, notes
        "doc.text", "doc.text.fill", "doc.richtext", "doc.plaintext",
        "doc.append", "doc.on.doc", "doc.on.clipboard",
        "doc.text.magnifyingglass", "doc.badge.plus", "doc.badge.gearshape",
        "note.text", "note.text.badge.plus", "square.and.pencil",
        "text.justify.left", "text.alignleft", "text.badge.checkmark",
        // Books & Knowledge
        "book.fill", "book.closed.fill", "text.book.closed.fill",
        "books.vertical.fill", "bookmark.fill", "graduationcap.fill",
        // Lists & Checklists
        "checklist", "checklist.checked", "list.clipboard.fill",
        "list.bullet.clipboard", "list.bullet.rectangle.fill",
        "list.bullet", "list.number",
        // Folders & Storage
        "folder.fill", "folder.badge.gearshape", "folder.badge.plus",
        "archivebox.fill", "tray.full.fill", "tray.2.fill",
        "externaldrive.fill", "internaldrive.fill",
        // Code & Engineering
        "swift", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "terminal.fill", "apple.terminal.fill",
        "cpu.fill", "memorychip.fill", "server.rack",
        "desktopcomputer", "laptopcomputer", "network",
        "antenna.radiowaves.left.and.right",
        // Analysis & Charts
        "chart.line.uptrend.xyaxis", "chart.bar.fill", "chart.pie.fill",
        "chart.xyaxis.line", "waveform.path.ecg", "function",
        "number", "percent", "sum",
        // Communication & Collaboration
        "bubble.left.and.bubble.right.fill", "text.bubble.fill",
        "bubble.left.fill", "quote.bubble.fill",
        "envelope.fill", "paperplane.fill", "megaphone.fill",
        "person.2.fill", "person.3.fill", "person.crop.circle.fill",
        // Creative & Design
        "paintbrush.pointed.fill", "paintpalette.fill",
        "photo.fill", "camera.fill", "sparkles", "wand.and.stars",
        "theatermasks.fill", "music.note", "film.fill",
        "pencil", "lightbulb.fill", "eye.fill", "eyedropper.full",
        "ruler.fill", "perspective",
        // Business & Product
        "briefcase.fill", "building.2.fill", "cart.fill", "banknote.fill",
        "target", "flag.fill", "globe", "map.fill",
        "tag.fill", "shippingbox.fill",
        // Quality & Review
        "checkmark.seal.fill", "star.fill", "hand.thumbsup.fill",
        "magnifyingglass", "binoculars.fill",
        "stethoscope", "testtube.2",
        // Status & Symbols
        "crown.fill", "trophy.fill", "medal.fill",
        "bolt.fill", "flame.fill", "leaf.fill",
        "heart.fill", "bell.fill",
        // Security & Compliance
        "shield.fill", "shield.checkered", "checkmark.shield.fill",
        "lock.fill", "key.fill", "hand.raised.fill",
        // Science & Nature
        "atom", "flask.fill", "brain.fill", "brain.head.profile",
        "sun.max.fill", "moon.fill", "cloud.fill",
        // Time & Progress
        "clock.fill", "timer", "hourglass",
        "calendar", "clock.arrow.circlepath",
        // Navigation & Links
        "location.fill", "safari.fill", "link",
        "pin.fill", "mappin.and.ellipse",
        "arrowshape.turn.up.right.fill", "square.and.arrow.up.fill",
        // Tools & Settings
        "hammer.fill", "wrench.fill", "gearshape.fill",
        "slider.horizontal.3", "wand.and.rays",
        "power.fill", "bolt.shield.fill",
        // Gaming & Fun
        "dice.fill", "gamecontroller.fill", "puzzlepiece.fill",
        "figure.fencing", "scalemass.fill",
        // Alerts & Info
        "exclamationmark.triangle.fill", "questionmark.circle.fill",
        "info.circle.fill", "checkmark.circle.fill", "xmark.circle.fill",
        "nosign", "rectangle.and.hand.point.up.left.filled"
    ]

    var body: some View {
        Button {
            showingPicker.toggle()
        } label: {
            Image(systemName: selectedIcon)
                .font(.title3)
                .foregroundStyle(iconForeground)
                .frame(width: buttonSize, height: buttonSize)
                .background(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous).fill(iconBackground))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(gridItemSize), spacing: 6), count: 10), spacing: 6) {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(selectedIcon == icon ? iconForeground : .primary)
                                .frame(width: gridItemSize, height: gridItemSize)
                                .background(
                                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                        .fill(selectedIcon == icon ? iconBackground : Colors.surfaceCard)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
            .frame(width: popoverWidth, height: popoverHeight)
        }
    }
}

#Preview {
    @Previewable @State var icon = "doc.text.fill"
    HStack(spacing: 16) {
        IconPickerButton(selectedIcon: $icon)
        IconPickerButton(
            selectedIcon: $icon,
            iconForeground: .white,
            iconBackground: Colors.success
        )
    }
    .padding()
    .background(Colors.surfacePrimary)
}
