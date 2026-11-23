import SwiftUI

public enum DS {
    public enum Colour {
        public static let ground       = Color.adaptive(light: Color(hex: 0xEEF1F5), dark: Color(hex: 0x0D1015))
        public static let ink          = Color.adaptive(light: Color(hex: 0x0E1116), dark: Color(hex: 0xF2F4F7))
        public static let secondary    = Color.adaptive(light: Color(hex: 0x4A5361), dark: Color(hex: 0xA3ACB9))
        public static let tertiary     = Color.adaptive(light: Color(hex: 0x8C95A3), dark: Color(hex: 0x6B7482))  // waiting step ring
        public static let chevron      = Color.adaptive(light: Color(hex: 0x5E6875), dark: Color(hex: 0x8C95A3))  // row chevrons (settings, voice profile)
        public static let accent       = Color.adaptive(light: Color(hex: 0x2457F5), dark: Color(hex: 0x5B82FF))
        public static let accentText   = Color.adaptive(light: Color(hex: 0x1B45C9), dark: Color(hex: 0x8EA8FF))
        public static let accentFill   = Color.adaptive(light: Color(hex: 0x2457F5, opacity: 0.10), dark: Color(hex: 0x5B82FF, opacity: 0.18))
        public static let record       = Color(hex: 0xE5484D)
        public static let destructive  = Color.adaptive(light: Color(hex: 0xC62828), dark: Color(hex: 0xFF6B6B))
        public static let unnamed      = Color.adaptive(light: Color(hex: 0xB4530A), dark: Color(hex: 0xF0A060))  // dashed outline, waiting dot
        public static let unnamedText  = Color.adaptive(light: Color(hex: 0x8A3F06), dark: Color(hex: 0xF0A060))
        public static let cardFill     = Color.adaptive(light: Color.white.opacity(0.74), dark: Color(hex: 0x1A1E25, opacity: 0.80))
        public static let cardStroke   = Color.adaptive(light: Color.white.opacity(0.85), dark: Color.white.opacity(0.08))
        public static let chipFill     = Color.adaptive(light: Color.white.opacity(0.55), dark: Color.white.opacity(0.08))   // plain chip / clip row
        public static let chipStroke   = Color.adaptive(light: Color.white.opacity(0.75), dark: Color.white.opacity(0.10))
        public static let fieldFill    = Color.adaptive(light: Color.white.opacity(0.80), dark: Color.white.opacity(0.08))
        public static let divider      = Color.adaptive(light: Color(hex: 0x0E1116, opacity: 0.08), dark: Color.white.opacity(0.10))
        public static let neutralFill  = Color.adaptive(light: Color(hex: 0x0E1116, opacity: 0.06), dark: Color.white.opacity(0.10))  // icon tiles, pills
        public static let switchOff    = Color(hex: 0x0E1116, opacity: 0.18)
        public static let shadow       = Color(red: 20/255, green: 30/255, blue: 50/255)   // used at 0.07 (cards) / 0.10–0.18
        public enum Blob {
            public static let teal     = Color(hex: 0x8FD3DC)   // 300 pt, 0.45, blur 70
            public static let lavender = Color(hex: 0xBDB4F5)   // 320 pt, 0.42, blur 80
            public static let peach    = Color(hex: 0xF6C3A6)   // 280 pt, 0.40, blur 80; dark mode all ×0.4
        }
    }
    public enum Radius {
        public static let card: CGFloat = 28, panel: CGFloat = 32, sheet: CGFloat = 36, banner: CGFloat = 24
        public static let row: CGFloat = 20, field: CGFloat = 16, iconTile: CGFloat = 8, bar: CGFloat = 2
    }
    public enum Space {
        public static let screenInset: CGFloat = 16, cardPadding: CGFloat = 18, cardGap: CGFloat = 14
        public static let dockGap: CGFloat = 18, dockBottom: CGFloat = 30
        /// Minimum hit target: 44 pt for touch, 32 pt for the pointer on the Mac.
        #if os(macOS)
        public static let hit: CGFloat = 32
        #else
        public static let hit: CGFloat = 44
        #endif
    }
    public enum Size {
        public static let dockButton: CGFloat = 52, recordOuter: CGFloat = 84, recordInner: CGFloat = 62, stopSquare: CGFloat = 30
        public static let toolbarButton: CGFloat = 44, chipCompact: CGFloat = 26, chipRegular: CGFloat = 28
        public static let playerHeight: CGFloat = 64, avatar: CGFloat = 44, ringAvatar: CGFloat = 88, iconTile: CGFloat = 30
        public static let settingsRow: CGFloat = 52, voiceRow: CGFloat = 72
    }
    public enum Typo {
        public static let largeTitle = Font.largeTitle.weight(.bold)                 // 34 "Recordings", "Voices", "Settings", "New recording"
        public static let screenTitle = Font.title.weight(.bold)                     // 28 "Who is this?", "Karan"
        public static let panelTitle = Font.title2.weight(.bold)                     // 22 "Working out who said what"
        public static let headline = Font.headline                                   // 17 semibold
        #if os(macOS)
        public static let transcript = Font.system(size: 15)                         // Mac mockup: 15 on a 24 pt line
        /// Extra leading for `transcript` (iPhone 17 on 26; Mac 15 on 24).
        public static let transcriptLineSpacing: CGFloat = 6
        #else
        public static let transcript = Font.body                                     // 17, lineSpacing 5.7 (26 pt line)
        public static let transcriptLineSpacing: CGFloat = 5.7
        #endif
        public static let cardBody = Font.callout                                    // 16, lineSpacing 3.3 (23 pt line)
        public static let subheadline = Font.subheadline                             // 15
        public static let rowTitle = Font.body                                       // 17 settings rows
        public static let meta = Font.footnote                                       // 13
        public static let chip = Font.footnote.weight(.semibold)                     // 13 semibold
        public static let caption = Font.caption                                     // 12
        public static let sectionHeader = Font.footnote.weight(.semibold)            // 13 uppercase, tracking 0.4
        public static let mono = Font.system(.footnote, design: .monospaced).monospacedDigit()   // 13 times/durations
        public static let monoSmall = Font.system(.caption, design: .monospaced).monospacedDigit()
        public static let monoStatus = Font.system(.subheadline, design: .monospaced).weight(.medium).monospacedDigit() // recording capsule 14–15
    }
}
