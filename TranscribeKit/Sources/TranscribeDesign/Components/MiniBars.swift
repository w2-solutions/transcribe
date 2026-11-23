import SwiftUI

public struct MiniBars: View {
    let peaks: [Float]
    let color: Color
    let barWidth: CGFloat
    let spacing: CGFloat
    let maxHeight: CGFloat

    public init(peaks: [Float], color: Color, barWidth: CGFloat = 2, spacing: CGFloat = 2, maxHeight: CGFloat = 18) {
        self.peaks = peaks; self.color = color; self.barWidth = barWidth; self.spacing = spacing; self.maxHeight = maxHeight
    }

    public var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: DS.Radius.bar, style: .continuous)
                    .fill(color)
                    .frame(width: barWidth, height: Swift.max(2, Swift.min(maxHeight, CGFloat(p) * maxHeight)))
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
    }
}

#Preview("Mini bars") {
    VStack(spacing: 12) {
        MiniBars(peaks: [0.3, 0.6, 1, 0.5, 0.8, 0.4, 0.9, 0.6, 0.3], color: SpeakerPalette.colour(slot: 0).dot)
        MiniBars(peaks: [0.3, 0.5, 0.8, 0.4, 0.6, 0.9, 0.55, 0.35, 0.7], color: SpeakerPalette.colour(slot: 1).dot,
                 barWidth: 3, maxHeight: 14)
    }
    .padding()
}
