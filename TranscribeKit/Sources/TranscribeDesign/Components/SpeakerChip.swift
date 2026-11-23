import SwiftUI

public struct SpeakerChip: View {
    public enum Style: Sendable { case filled, unnamed, suggested }
    public enum Size: Sendable { case compact, regular }       // 26 / 28 tall
    /// filled: slot fill, slot dot, slot text. unnamed: 1 pt dashed amber Capsule (dash [3,2]), slot dot, amber text.
    /// suggested: 1 pt dashed SLOT-colour outline, slot dot, slot text, trailing "?". 13 pt semibold; padding 0/10/0/8.
    /// recognisedBadge: 18 pt accentFill circle with 11 pt accent checkmark after the capsule (gap 6).
    /// showsPencil: 12 pt pencil after the name (unnamed chips in transcripts).
    let name: String
    let slot: Int
    let style: Style
    let size: Size
    let recognisedBadge: Bool
    let showsPencil: Bool

    public init(name: String, slot: Int, style: Style, size: Size = .regular, recognisedBadge: Bool = false, showsPencil: Bool = false) {
        self.name = name; self.slot = slot; self.style = style; self.size = size
        self.recognisedBadge = recognisedBadge; self.showsPencil = showsPencil
    }

    private var palette: SpeakerColour { SpeakerPalette.colour(slot: slot) }
    private var textColor: Color { style == .unnamed ? SpeakerPalette.unnamed.text : palette.text }
    private var height: CGFloat { size == .compact ? DS.Size.chipCompact : DS.Size.chipRegular }
    /// Grows the capsule with Dynamic Type (the minimum height stays 26 / 28 at the default size).
    @ScaledMetric(relativeTo: .footnote) private var verticalPadding: CGFloat = 3

    public var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                SpeakerDot(slot: slot)
                Text(style == .suggested ? "\(name)?" : name)
                    .font(DS.Typo.chip)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsPencil {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(textColor)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: height)
            .background { capsule }
            if recognisedBadge {
                Circle()
                    .fill(DS.Colour.accentFill)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Colour.accent)
                    }
            }
        }
        // Ideal width when there is room; a long name truncates instead of pushing past its row.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }

    @ViewBuilder private var capsule: some View {
        let dash = StrokeStyle(lineWidth: 1, dash: [3, 2])
        switch style {
        case .filled: Capsule(style: .continuous).fill(palette.fill)
        case .unnamed: Capsule(style: .continuous).strokeBorder(DS.Colour.unnamed, style: dash)
        case .suggested: Capsule(style: .continuous).strokeBorder(palette.dot, style: dash)
        }
    }
}

#Preview("Speaker chips") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
            SpeakerChip(name: "Liam", slot: 0, style: .filled, size: .compact)
            SpeakerChip(name: "Karan", slot: 1, style: .filled, size: .compact)
        }
        HStack(spacing: 6) {
            SpeakerChip(name: "Liam", slot: 0, style: .filled, size: .compact)
            SpeakerChip(name: "Speaker 2", slot: 1, style: .unnamed, size: .compact)
        }
        SpeakerChip(name: "Speaker 2", slot: 1, style: .unnamed, showsPencil: true)
        SpeakerChip(name: "Karan", slot: 1, style: .suggested)
        SpeakerChip(name: "Liam", slot: 0, style: .filled, recognisedBadge: true)
    }
    .padding()
    .screenBackground()
}
