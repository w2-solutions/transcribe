import SwiftUI
import TranscribeCore

public struct WaveformBars: View {
    public struct Bar: Sendable, Equatable {
        public var height: Float; public var color: Color
        public init(height: Float, color: Color) { self.height = height; self.color = color }
    }
    /// Bars (radius 2) evenly spaced. If playedFraction is set, bars after it render at unplayedOpacity.
    let bars: [Bar]
    let barWidth: CGFloat
    let spacing: CGFloat
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let playedFraction: Double?
    let unplayedOpacity: Double

    public init(bars: [Bar], barWidth: CGFloat = 3, spacing: CGFloat = 3, maxHeight: CGFloat,
                minHeight: CGFloat = 3, playedFraction: Double? = nil, unplayedOpacity: Double = 0.35) {
        self.bars = bars; self.barWidth = barWidth; self.spacing = spacing; self.maxHeight = maxHeight
        self.minHeight = minHeight; self.playedFraction = playedFraction; self.unplayedOpacity = unplayedOpacity
    }

    public var body: some View {
        Canvas { context, size in
            let n = bars.count
            guard n > 0 else { return }
            // Evenly spaced across the available width; never closer than fits.
            let step: CGFloat = n > 1 ? Swift.max(barWidth, (size.width - barWidth) / CGFloat(n - 1)) : 0
            for (i, bar) in bars.enumerated() {
                let h = Swift.max(minHeight, Swift.min(maxHeight, CGFloat(bar.height) * maxHeight))
                let x = CGFloat(i) * step
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                var color = bar.color
                if let played = playedFraction, (Double(i) + 0.5) / Double(n) > played { color = color.opacity(unplayedOpacity) }
                context.fill(Path(roundedRect: rect, cornerRadius: DS.Radius.bar), with: .color(color))
            }
        }
        .frame(minWidth: CGFloat(bars.count) * (barWidth + spacing) - spacing, maxWidth: .infinity,
               minHeight: maxHeight, maxHeight: maxHeight)
        .accessibilityHidden(true)
    }

    /// Builds bars: peaks resampled to `count`; colour = slot dot of the speaker covering each bar, else `fallback`.
    public static func bars(peaks: [Float], count: Int, duration: TimeInterval, turns: [Turn],
                            slotForKey: (SpeakerKey) -> Int?, fallback: Color) -> [Bar] {
        guard count > 0 else { return [] }
        var heights = WaveformPeaks.resample(peaks, to: count)
        if heights.count < count { heights += [Float](repeating: 0, count: count - heights.count) }
        let keys = SpeakerTimeline.speakerKeys(barCount: count, duration: duration, turns: turns)
        return (0..<count).map { i in
            let key = i < keys.count ? keys[i] : nil
            let color = key.flatMap(slotForKey).map { SpeakerPalette.colour(slot: $0).dot } ?? fallback
            return Bar(height: heights[i], color: color)
        }
    }
}

/// Mockup-like demo peaks for previews.
let previewPeaks: [Float] = [0.33, 0.67, 0.89, 0.5, 0.78, 1, 0.56, 0.28, 0.72, 0.89, 0.44, 0.22, 0.61, 0.83, 0.5, 0.94, 0.67, 0.33, 0.56, 0.78, 0.39]

#Preview("Waveform bars") {
    let turns = [
        Turn(id: Turn.stableID(index: 0), speakerKey: "S1", range: TimeRange(start: 0, end: 10.6), words: []),
        Turn(id: Turn.stableID(index: 1), speakerKey: "S2", range: TimeRange(start: 10.7, end: 15.5), words: []),
        Turn(id: Turn.stableID(index: 2), speakerKey: "S1", range: TimeRange(start: 15.6, end: 20), words: []),
    ]
    let bars = WaveformBars.bars(peaks: previewPeaks, count: 21, duration: 20, turns: turns,
                                 slotForKey: { $0 == "S1" ? 0 : 1 }, fallback: DS.Colour.ink)
    VStack(spacing: 20) {
        WaveformBars(bars: bars, maxHeight: 18)
        WaveformBars(bars: bars, maxHeight: 28, playedFraction: 0.6)
    }
    .padding()
}
