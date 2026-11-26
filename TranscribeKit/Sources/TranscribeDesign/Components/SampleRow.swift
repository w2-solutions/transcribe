import SwiftUI
import TranscribeCore

public struct SampleRow: View {
    /// VoiceDetail sample: 56 tall; 44 pt plain circle play button; quote in curly quotes 15 truncating; MiniBars 14 tall
    /// slot colour; duration mono 13. A non-nil `unavailableCaption` ("Recording deleted", "No clip saved", "Audio is on
    /// your iPad") disables play and replaces the bars, in caption type and secondary colour; nil = playable.
    let quote: String
    let duration: TimeInterval
    let slot: Int
    let peaks: [Float]
    let isPlaying: Bool
    let unavailableCaption: String?
    let action: () -> Void

    public init(quote: String, duration: TimeInterval, slot: Int, peaks: [Float], isPlaying: Bool, unavailableCaption: String?,
                action: @escaping () -> Void) {
        self.quote = quote; self.duration = duration; self.slot = slot; self.peaks = peaks
        self.isPlaying = isPlaying; self.unavailableCaption = unavailableCaption; self.action = action
    }

    private var isAvailable: Bool { unavailableCaption == nil }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isAvailable ? DS.Colour.ink : DS.Colour.tertiary)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle().fill(DS.Colour.chipFill)
                            .overlay { Circle().strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityLabel("\(isPlaying ? "Pause" : "Play") sample: \(quote)")

            VStack(alignment: .leading, spacing: 5) {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colour.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let unavailableCaption {
                    Text(unavailableCaption)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Colour.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    MiniBars(peaks: fixedCount(peaks, 27), color: SpeakerPalette.colour(slot: slot).dot, barWidth: 3, maxHeight: 14)
                }
            }
            // The quote takes the free width before the spacer, so it truncates only when it does not fit (an equal
            // share with the spacer cut "I'll be there in five." to "I'll be there in f…" on an iPhone 15).
            .layoutPriority(1)
            Spacer(minLength: 4)
            Text(DisplayFormat.duration(duration))
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

#Preview("Sample rows") {
    VStack(spacing: 0) {
        SampleRow(quote: "Uh yes, testing the transcription app.", duration: 3, slot: 1,
                  peaks: [0.3, 0.5, 0.8, 0.4, 0.6, 0.9, 0.55, 0.35, 0.7], isPlaying: false, unavailableCaption: nil) {}
        SampleRow(quote: "And now this is me starting to speak…", duration: 4, slot: 1,
                  peaks: [], isPlaying: false, unavailableCaption: "Recording deleted") {}
        SampleRow(quote: "Can you hear me from there?", duration: 5, slot: 1,
                  peaks: [], isPlaying: false, unavailableCaption: "No clip saved") {}
        SampleRow(quote: "Let's do it tomorrow.", duration: 4, slot: 1,
                  peaks: [], isPlaying: false, unavailableCaption: "Audio is on your iPad") {}
    }
    .cardSurface(padding: EdgeInsets())
    .padding(16)
    .screenBackground()
}
