import SwiftUI
import TranscribeCore

public struct ClipRow: View {
    /// Name sheet "Listen" row: 48 tall plainCapsule; 36 pt disc (slot fill, slot-text play icon / pause when playing),
    /// 9 MiniBars (20 tall, slot dot), quote 15 one line truncating, duration mono 13.
    /// Without local audio (`canPlay` false: audio not on this device, because it is not in iCloud, not downloaded yet,
    /// or not syncing here) the row is a quote: a quote mark in the disc, no button.
    let quote: String
    let duration: TimeInterval
    let slot: Int
    let peaks: [Float]
    let isPlaying: Bool
    let canPlay: Bool
    let action: () -> Void

    public init(quote: String, duration: TimeInterval, slot: Int, peaks: [Float], isPlaying: Bool, canPlay: Bool = true,
                action: @escaping () -> Void) {
        self.quote = quote; self.duration = duration; self.slot = slot; self.peaks = peaks
        self.isPlaying = isPlaying; self.canPlay = canPlay; self.action = action
    }

    public var body: some View {
        if canPlay {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isPlaying ? "Pause" : "Play") clip: \(quote)")
                .accessibilityValue(DisplayFormat.spokenDuration(duration))
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Quote: \(quote)")
                .accessibilityValue(DisplayFormat.spokenDuration(duration))
        }
    }

    private var row: some View {
        let palette = SpeakerPalette.colour(slot: slot)
        return HStack(spacing: 10) {
            Circle().fill(palette.fill)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: canPlay ? (isPlaying ? "pause.fill" : "play.fill") : "quote.opening")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                }
            if canPlay {
                MiniBars(peaks: fixedCount(peaks, 9), color: palette.dot, maxHeight: 20)
            }
            Text(quote)
                .font(.subheadline)
                .foregroundStyle(DS.Colour.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(DisplayFormat.duration(duration))
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Colour.secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 48)
        .plainCapsule()
        .contentShape(Capsule())
    }
}

/// Exactly `count` values: max-pooled when longer, repeated when shorter, flat when empty.
func fixedCount(_ values: [Float], _ count: Int) -> [Float] {
    guard count > 0 else { return [] }
    guard !values.isEmpty else { return [Float](repeating: 0.4, count: count) }
    return (0..<count).map { i in
        let a = i * values.count / count
        let b = Swift.max(a + 1, (i + 1) * values.count / count)
        return values[a..<Swift.min(b, values.count)].max() ?? 0
    }
}

#Preview("Clip rows") {
    VStack(spacing: 8) {
        ClipRow(quote: "Uh yes, testing the transcription app.", duration: 3, slot: 1,
                peaks: [0.3, 0.6, 1, 0.5, 0.8, 0.4, 0.9, 0.6, 0.3], isPlaying: false) {}
        ClipRow(quote: "Okay, I got the spelling wrong, but it's alright.", duration: 4, slot: 1,
                peaks: [0.5, 0.7, 0.4, 0.9, 0.6, 0.3, 0.8, 0.5, 0.4], isPlaying: true) {}
    }
    .padding(20)
    .screenBackground()
}
