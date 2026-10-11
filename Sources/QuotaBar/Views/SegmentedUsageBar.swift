import SwiftUI

/// A continuous fill reveals partial segments as the quota changes, so the
/// caller's animation also moves the white fill and its glow smoothly together.
struct SegmentedUsageBar: View {
    var fraction: Double

    private var clampedFraction: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                UsageBarSegments()
                    .fill(.white.opacity(0.14))

                Color.white
                    .frame(width: geometry.size.width * clampedFraction)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .mask(UsageBarSegments())
                    .compositingGroup()
                    // Figma's 6pt blur maps to a 3pt SwiftUI shadow radius.
                    // Apply it after the segment mask so the glow can extend
                    // into the gaps and beyond the 315 × 20pt bar bounds.
                    .shadow(color: .white.opacity(0.56), radius: 3, x: 0, y: 0)
            }
        }
    }
}

private struct UsageBarSegments: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let segmentCount = 45
        let segmentWidth: CGFloat = 4
        let segmentHeight: CGFloat = 20
        let travel = rect.width - segmentWidth
        let y = rect.midY - segmentHeight / 2

        var path = Path()
        for index in 0..<segmentCount {
            // Space-between pins the first left edge and the last right edge
            // exactly to the bounds: at 315pt, each gap is 135 / 44pt.
            let x = rect.minX + travel * CGFloat(index) / CGFloat(segmentCount - 1)
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: segmentWidth, height: segmentHeight),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}
