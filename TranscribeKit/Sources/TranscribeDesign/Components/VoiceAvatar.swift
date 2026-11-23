import SwiftUI

public struct VoiceAvatar: View {
    public enum Style: Sendable { case filled, unnamed }  // unnamed: 1.5 pt dashed amber ring + person glyph (amber text)
    let initial: String
    let slot: Int?
    let style: Style
    let diameter: CGFloat

    public init(initial: String, slot: Int?, style: Style = .filled, diameter: CGFloat = 44) {
        self.initial = initial; self.slot = slot; self.style = style; self.diameter = diameter
    }

    public var body: some View {
        Group {
            switch style {
            case .filled:
                let palette = SpeakerPalette.colour(slot: slot ?? 0)
                Circle().fill(SpeakerPalette.avatarDisc(slot: slot ?? 0))
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1) }
                    .overlay {
                        Text(initial)
                            .font(.system(size: diameter * 0.4, weight: .semibold))
                            .foregroundStyle(palette.text)
                    }
            case .unnamed:
                // Outline only (no fill), like the dashed "Speaker N" chip: unnamed voices read as not yet saved.
                Circle().fill(Color.clear)
                    .overlay { Circle().strokeBorder(DS.Colour.unnamed, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                    .overlay {
                        Image(systemName: "person")
                            .font(.system(size: diameter * 0.45, weight: .medium))
                            .foregroundStyle(SpeakerPalette.unnamed.text)
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

public struct VoiceRingAvatar: View {
    /// 88 pt: disc avatarDisc(slot) with initial 36 semibold slot text, ringed by `maxSamples` (8) tick groups; the
    /// first `min(sampleCount, maxSamples)` groups are slot dot colour, the rest neutralFill.
    let initial: String
    let slot: Int
    let sampleCount: Int
    let maxSamples: Int

    public init(initial: String, slot: Int, sampleCount: Int, maxSamples: Int = 8) {
        self.initial = initial; self.slot = slot; self.sampleCount = sampleCount; self.maxSamples = maxSamples
    }

    /// Tick lengths per group (mockup rhythm), 4 ticks per group, 9° apart.
    private static let tickLengths: [CGFloat] = [3, 5, 7, 4, 2, 5, 3, 6, 4, 7, 5, 3, 5, 2, 6, 4,
                                                  3, 6, 4, 2, 7, 5, 3, 5, 4, 6, 2, 5, 6, 3, 4, 7]

    public var body: some View {
        let palette = SpeakerPalette.colour(slot: slot)
        let groups = Swift.max(1, maxSamples)
        let filled = Swift.max(0, Swift.min(sampleCount, groups))
        ZStack {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let ring = Path(ellipseIn: CGRect(x: c.x - 52, y: c.y - 52, width: 104, height: 104))
                context.stroke(ring, with: .color(palette.dot.opacity(0.12)), lineWidth: 1)
                let perGroup = 4
                let groupSpan = 360.0 / Double(groups)
                for g in 0..<groups {
                    let color: Color = g < filled ? palette.dot.opacity(0.55) : DS.Colour.neutralFill
                    for t in 0..<perGroup {
                        let angle = (Double(g) * groupSpan + Double(t) * groupSpan / Double(perGroup + 1) + 4 - 90) * .pi / 180
                        let len = Self.tickLengths[(g * perGroup + t) % Self.tickLengths.count]
                        let r0: CGFloat = 47, r1 = 47 + len
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + r0 * cos(angle), y: c.y + r0 * sin(angle)))
                        p.addLine(to: CGPoint(x: c.x + r1 * cos(angle), y: c.y + r1 * sin(angle)))
                        context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            }
            .frame(width: 112, height: 112)

            Circle().fill(SpeakerPalette.avatarDisc(slot: slot))
                .overlay { Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1) }
                .shadow(color: palette.dot.opacity(0.16), radius: 10, x: 0, y: 6)
                .overlay {
                    Text(initial).font(.system(size: 36, weight: .semibold)).tracking(-0.5).foregroundStyle(palette.text)
                }
                .frame(width: DS.Size.ringAvatar, height: DS.Size.ringAvatar)
        }
        .frame(width: DS.Size.ringAvatar, height: DS.Size.ringAvatar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sampleCount == 1 ? "1 voice sample" : "\(sampleCount) voice samples")
    }
}

#Preview("Voice avatars") {
    VStack(spacing: 28) {
        HStack(spacing: 14) {
            VoiceAvatar(initial: "L", slot: 0)
            VoiceAvatar(initial: "K", slot: 1)
            VoiceAvatar(initial: "", slot: nil, style: .unnamed)
        }
        VoiceRingAvatar(initial: "K", slot: 1, sampleCount: 2)
        VoiceRingAvatar(initial: "L", slot: 0, sampleCount: 3)
    }
    .padding(30)
    .screenBackground()
}
