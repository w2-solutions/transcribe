import SwiftUI

public struct LiveLevelMeter: View {
    /// `height` pt tall row (96 by default) of 3 pt bars, gap 3, centred; ink, last `recentCount` bars record red;
    /// bar heights from levels, up to `maxHeight`.
    let levels: [Float]
    let recentCount: Int
    let maxHeight: CGFloat
    let height: CGFloat

    public init(levels: [Float], recentCount: Int = 10, maxHeight: CGFloat = 64, height: CGFloat = 96) {
        self.levels = levels; self.recentCount = recentCount; self.maxHeight = maxHeight; self.height = height
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                RoundedRectangle(cornerRadius: DS.Radius.bar, style: .continuous)
                    .fill(i >= levels.count - recentCount ? DS.Colour.record : DS.Colour.ink)
                    .frame(width: 3, height: Swift.max(4, Swift.min(maxHeight, CGFloat(level) * maxHeight)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview("Live level meter") {
    LiveLevelMeter(levels: (0..<56).map { i in Float(0.2 + 0.6 * abs(sin(Double(i) * 0.45))) })
        .padding()
        .screenBackground()
}
