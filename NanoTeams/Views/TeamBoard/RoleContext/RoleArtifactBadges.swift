import SwiftUI

/// Compact row of artifact capsule badges for a step's produced artifacts.
struct RoleArtifactBadges: View {
    let artifacts: [Artifact]

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(artifacts, id: \.id) { artifact in
                Label(artifact.name, systemImage: artifact.icon)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.artifactTint)
                    )
                    .foregroundStyle(Colors.artifact)
            }

            Spacer()
        }
    }
}
