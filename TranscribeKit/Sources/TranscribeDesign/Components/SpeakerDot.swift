import SwiftUI

public struct SpeakerDot: View {
    let slot: Int?
    let diameter: CGFloat
    /// nil → amber
    public init(slot: Int?, diameter: CGFloat = 8) { self.slot = slot; self.diameter = diameter }

    public var body: some View {
        Circle()
            .fill(slot.map { SpeakerPalette.colour(slot: $0).dot } ?? SpeakerPalette.unnamed.dot)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

#Preview("Speaker dots") {
    HStack(spacing: 8) {
        ForEach(0..<6, id: \.self) { SpeakerDot(slot: $0, diameter: 12) }
        SpeakerDot(slot: nil, diameter: 12)
    }
    .padding()
}
