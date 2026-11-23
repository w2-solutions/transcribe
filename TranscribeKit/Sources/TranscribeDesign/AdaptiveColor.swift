import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Dynamic light/dark colour (UIColor dynamic provider on iOS, NSColor(name:dynamicProvider:) on macOS).
    static func adaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        let l = UIColor(light), d = UIColor(dark)
        return Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? d : l })
        #elseif canImport(AppKit)
        let l = NSColor(light), d = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
        #else
        return light
        #endif
    }
}

/// Mixes two 0xRRGGBB colours: `amount` 0 → a, 1 → b.
func mixHex(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
    func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
    func mix(_ shift: UInt32) -> UInt32 {
        UInt32((ch(a, shift) + (ch(b, shift) - ch(a, shift)) * amount).rounded()) & 0xFF
    }
    return (mix(16) << 16) | (mix(8) << 8) | mix(0)
}
