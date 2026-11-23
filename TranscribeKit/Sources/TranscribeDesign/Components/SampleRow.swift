import SwiftUI
import TranscribeCore

public struct SampleRow: View {
    /// VoiceDetail sample: 56 tall; 44 pt plain circle play button; quote in curly quotes 15 truncating; MiniBars 14 tall
    /// slot colour; duration mono 13. isAvailable false → play disabled + "Recording deleted" caption.
    let quote: String
    let duration: TimeInterval
    let slot: Int
    let peaks: [Float]
    let isPlaying: Bool
    let isAvailable: Bool
    let action: () -> Void

    public init(quote: String, duration: TimeInterval, slot: Int, peaks: [Float], isPlaying: Bool, isAvailable: Bool, action: @escaping () -> Void) {
        self.quote = quote; self.duration = duration; self.slot = slot; self.peaks = peaks
        self.isPlaying = isPlaying; self.isAvailable = isAvailable; self.action = action
    }

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
                if isAvailable {
                    MiniBars(peaks: fixedCount(peaks, 27), color: SpeakerPalette.colour(slot: slot).dot, barWidth: 3, maxHeight: 14)
                } else {
                    Text("Recording deleted").font(DS.Typo.caption).foregroundStyle(DS.Colour.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(DisplayFormat.duration(duration))
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Colour.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

#Preview("Sample rows") {
    VStack(spacing: 0) {
        SampleRow(quote: "Uh yes, testing the transcription app.", duration: 3, slot: 1,
                  peaks: [0.3, 0.5, 0.8, 0.4, 0.6, 0.9, 0.55, 0.35, 0.7], isPlaying: false, isAvailable: true) {}
        SampleRow(quote: "And now this is me starting to speak…", duration: 4, slot: 1,
                  peaks: [], isPlaying: false, isAvailable: false) {}
    }
    .cardSurface(padding: EdgeInsets())
    .padding(16)
    .screenBackground()
}
