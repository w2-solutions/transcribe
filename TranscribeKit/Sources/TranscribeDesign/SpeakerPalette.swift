import SwiftUI
import TranscribeCore

public struct SpeakerColour: Sendable {
    public let dot: Color     // dots, bars, avatar ring
    public let fill: Color    // chip/avatar background (dot at 12%; rose 10%)
    public let text: Color    // chip text / initial
    public init(dot: Color, fill: Color, text: Color) { self.dot = dot; self.fill = fill; self.text = text }
}

public enum SpeakerPalette {
    // slot: dot / text (light). Dark: text = dot lightened 45% toward white, fill = dot at 22%.
    // 0 teal   #0E7C86 / #0A5C64
    // 1 rose   #C2255C / #9C1C49   (fill 10%)
    // 2 violet #6741D9 / #5030B5
    // 3 green  #2B8A3E / #1F6A2F
    // 4 slate  #3B5BA9 / #2C4580
    // 5 brown  #8C5A2B / #6B4420
    static let slots: [(dot: UInt32, text: UInt32, fill: Double)] = [
        (0x0E7C86, 0x0A5C64, 0.12),
        (0xC2255C, 0x9C1C49, 0.10),
        (0x6741D9, 0x5030B5, 0.12),
        (0x2B8A3E, 0x1F6A2F, 0.12),
        (0x3B5BA9, 0x2C4580, 0.12),
        (0x8C5A2B, 0x6B4420, 0.12),
    ]

    static func slotIndex(_ slot: Int) -> Int { slot < 0 ? 0 : slot % SpeakerSlots.count }

    private static let colours: [SpeakerColour] = slots.map { s in
        SpeakerColour(
            dot: Color(hex: s.dot),
            fill: Color.adaptive(light: Color(hex: s.dot, opacity: s.fill), dark: Color(hex: s.dot, opacity: 0.22)),
            text: Color.adaptive(light: Color(hex: s.text), dark: Color(hex: mixHex(s.dot, 0xFFFFFF, 0.45))))
    }

    /// slot % 6, negatives → 0
    public static func colour(slot: Int) -> SpeakerColour { colours[slotIndex(slot)] }

    /// Amber "unnamed" styling (outline + text); never a slot.
    /// dot #B4530A, fill amber 18%, text #8A3F06
    public static let unnamed = SpeakerColour(
        dot: DS.Colour.unnamed,
        fill: Color.adaptive(light: Color(hex: 0xB4530A, opacity: 0.18), dark: Color(hex: 0xF0A060, opacity: 0.22)),
        text: DS.Colour.unnamedText)

    private static let discs: [Color] = slots.map { s in
        Color.adaptive(light: Color(hex: mixHex(0xFFFFFF, s.dot, 0.12)), dark: Color(hex: mixHex(0x1A1E25, s.dot, 0.30)))
    }

    /// Avatar disc fill for VoiceRingAvatar: white mixed with dot at 12% (rose → ≈ #F6E3EA).
    public static func avatarDisc(slot: Int) -> Color { discs[slotIndex(slot)] }
}
