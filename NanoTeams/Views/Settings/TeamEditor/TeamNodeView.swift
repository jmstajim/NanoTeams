import SwiftUI

// MARK: - Team Node View

/// A draggable node representing a role in the team graph.
/// Dynamic height to fit content; fixed width.
struct TeamNodeView: View {
    let roleName: String
    let icon: String
    let tintColor: Color
    let dependencies: RoleDependencies
    let isSelected: Bool
    let position: CGPoint
    let onSelect: () -> Void
    let onDrag: (CGPoint) -> Void
    var onDragEnd: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onRemoveFromGraph: (() -> Void)? = nil
    var onMeasure: ((CGSize) -> Void)? = nil
    var isSupervisor: Bool = false

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    static let nodeMaxWidth: CGFloat = 200

    var body: some View {
        Button(action: onSelect) {
        VStack(spacing: Spacing.xxs) {
            // Role icon and name
            HStack(spacing: Spacing.xxs) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(roleName)
                    .font(.system(.caption2, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(tintColor)

            Divider()

            // Input artifacts (required)
            if !dependencies.requiredArtifacts.isEmpty {
                HStack(alignment: .top, spacing: Spacing.xxs) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Colors.info)
                        .padding(.top, 1)
                    Text(dependencies.requiredArtifacts.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Output artifacts (produces)
            if !dependencies.producesArtifacts.isEmpty {
                HStack(alignment: .top, spacing: Spacing.xxs) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Colors.artifact)
                        .padding(.top, 1)
                    Text(dependencies.producesArtifacts.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, CornerRadius.small)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: Self.nodeMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(isDragging ? .elevated : .card)
        .scaleEffect(isDragging ? 1.05 : 1.0)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onMeasure?(proxy.size) }
                    .onChange(of: proxy.size) { _, newSize in onMeasure?(newSize) }
            }
        )
        .position(
            x: position.x + dragOffset.width,
            y: position.y + dragOffset.height
        )
        }
        .buttonStyle(.plain)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    let newPosition = CGPoint(
                        x: position.x + value.translation.width,
                        y: position.y + value.translation.height
                    )
                    dragOffset = .zero
                    onDrag(newPosition)
                    onDragEnd?()
                }
        )
        .onTapGesture(count: 2) {
            onDoubleTap?()
        }
        .accessibilityAction(named: "Edit Role") {
            onDoubleTap?()
        }
        .contextMenu {
            if let onDoubleTap {
                Button {
                    onDoubleTap()
                } label: {
                    Label("Edit Role...", systemImage: "pencil")
                }
            }

            if !isSupervisor {
                Divider()

                if let onRemoveFromGraph {
                    Button {
                        onRemoveFromGraph()
                    } label: {
                        Label("Remove from Graph", systemImage: "eye.slash")
                    }
                }
            }
        }
        .animationWithReduceMotion(.spring(response: 0.3), value: isDragging)
        .animationWithReduceMotion(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityHint("Double-tap to edit, drag to reposition")
    }

    // MARK: - Helpers

    // MARK: - Computed Properties

    private var backgroundColor: Color {
        if isSelected {
            return tintColor.opacity(DynamicTintOpacity.badge)
        }
        return Colors.surfaceCard
    }

    private var borderColor: Color {
        if isSelected {
            return tintColor
        }
        return Colors.borderSubtle
    }
}
#Preview {
    ZStack {
        TeamNodeView(
            roleName: "Junior Engineer",
            icon: "wrench.and.screwdriver.fill",
            tintColor: .blue,
            dependencies: RoleDependencies(
                requiredArtifacts: [
                    "Dependency 1"
                ],
                producesArtifacts: [
                    "Dependency 1"
                ]
            ),
            isSelected: false,
            position: CGPoint(x: 200, y: 110),
            onSelect: {},
            onDrag: { _ in }
        )

        TeamNodeView(
            roleName: "Software Engineer",
            icon: "hammer.fill",
            tintColor: .green,
            dependencies: RoleDependencies(
                requiredArtifacts: [
                    "Dependency 1",
                    "Dependency 2"
                ],
                producesArtifacts: [
                    "Dependency 1",
                    "Dependency 2"
                ]
            ),
            isSelected: false,
            position: CGPoint(x: 200, y: 240),
            onSelect: {},
            onDrag: { _ in }
        )

        TeamNodeView(
            roleName: "Tech Lead",
            icon: "cpu",
            tintColor: .orange,
            dependencies: RoleDependencies(
                requiredArtifacts: [
                    "Dependency 1",
                    "Dependency 2",
                    "Dependency 3"
                ],
                producesArtifacts: [
                    "Dependency 1",
                    "Dependency 2",
                    "Dependency 3"
                ]
            ),
            isSelected: true,
            position: CGPoint(x: 200, y: 370),
            onSelect: {},
            onDrag: { _ in }
        )

        TeamNodeView(
            roleName: "Architect",
            icon: "building.columns.fill",
            tintColor: .purple,
            dependencies: RoleDependencies(
                requiredArtifacts: [
                    "Dependency 1",
                    "Dependency 2",
                    "Dependency 3",
                    "Dependency 4"
                ],
                producesArtifacts: [
                    "Dependency 1",
                    "Dependency 2",
                    "Dependency 3",
                    "Dependency 4"
                ]
            ),
            isSelected: false,
            position: CGPoint(x: 200, y: 520),
            onSelect: {},
            onDrag: { _ in }
        )
    }
    .frame(width: 420, height: 650)
}
