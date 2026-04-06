import SwiftUI

// MARK: - Artifact Dependency Editor

/// Reusable component for editing artifact dependencies.
struct ArtifactDependencyEditor: View {
    @Binding var requiredArtifacts: [String]
    @Binding var producedArtifacts: [String]
    let availableArtifacts: [String]
    /// Artifacts excluded from the "Produced" selector (e.g. SystemTemplates.supervisorTaskArtifactName is Supervisor-only)
    var excludeFromProduced: Set<String> = []
    var onCreateNewForRequired: (() -> Void)? = nil
    var onCreateNewForProduced: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            // Required Artifacts
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Colors.info)
                    Text("Required Artifacts")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                ArtifactSelectorView(
                    selected: $requiredArtifacts,
                    availableArtifacts: availableArtifacts,
                    placeholder: "This role doesn't require any artifacts",
                    onCreateNew: onCreateNewForRequired
                )
            }

            Divider()

            // Produced Artifacts
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Colors.artifact)
                    Text("Produced Artifacts")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                ArtifactSelectorView(
                    selected: $producedArtifacts,
                    availableArtifacts: availableArtifacts.filter { !excludeFromProduced.contains($0) },
                    placeholder: "This role doesn't produce any artifacts",
                    onCreateNew: onCreateNewForProduced
                )
            }
        }
    }
}

// MARK: - Artifact Selector View

/// Individual artifact selector with add/remove functionality.
struct ArtifactSelectorView: View {
    @Binding var selected: [String]
    let availableArtifacts: [String]
    let placeholder: String
    var onCreateNew: (() -> Void)? = nil

    private var remaining: [String] {
        availableArtifacts.filter { !selected.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // Selected artifacts (with remove button)
            if selected.isEmpty {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(Spacing.s)
            } else {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(selected, id: \.self) { artifact in
                        HStack(spacing: Spacing.xs) {
                            Text(artifact)
                                .font(.caption)

                            Button {
                                selected.removeAll { $0 == artifact }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Colors.surfaceCard)
                        )
                        
                    }
                }
            }

            // Add artifact menu
            Menu {
                ForEach(remaining, id: \.self) { artifact in
                    Button(artifact) {
                        selected.append(artifact)
                    }
                }

                if remaining.isEmpty {
                    Text("All artifacts selected")
                        .foregroundStyle(.secondary)
                }

                if let onCreateNew {
                    Divider()
                    Button("New Artifact...") {
                        onCreateNew()
                    }
                }
            } label: {
                Label("Add Artifact", systemImage: "plus.circle")
                    .font(.caption)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(remaining.isEmpty && onCreateNew == nil)
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.surfacePrimary)
        )
        
    }
}

#Preview("Artifact Dependencies") {
    @Previewable @State var required = ["Supervisor Task", "Product Requirements"]
    @Previewable @State var produced = ["Implementation Plan"]

    ArtifactDependencyEditor(
        requiredArtifacts: $required,
        producedArtifacts: $produced,
        availableArtifacts: [
            "Supervisor Task", "Product Requirements", "Implementation Plan",
            "Design Spec", "Engineering Notes", "Code Review"
        ],
        excludeFromProduced: ["Supervisor Task"]
    )
    .padding()
    .frame(width: 400)
    .background(Colors.surfacePrimary)
}

// MARK: - Flow Layout

/// Simple flow layout for wrapping items horizontally.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}
