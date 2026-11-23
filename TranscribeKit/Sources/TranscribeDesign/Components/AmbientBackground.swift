import SwiftUI

public struct AmbientBackground: View {
    /// Three blurred circles placed proportionally (mockup offsets ÷ 390×844): teal at (-90,120) 300 pt;
    /// lavender at right -110, top 430, 320 pt; peach at left 40, bottom -120, 280 pt. drawingGroup(),
    /// ignoresSafeArea, allowsHitTesting(false), accessibilityHidden. `drift`: ±12 pt over 20 s unless Reduce Motion.
    let drift: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    public init(drift: Bool = false) { self.drift = drift }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let k = colorScheme == .dark ? 0.4 : 1.0
            let d: CGFloat = drifted ? 12 : 0
            ZStack {
                DS.Colour.ground
                blob(DS.Colour.Blob.teal, size: 300, opacity: 0.45 * k, blur: 70)
                    .position(x: w * 60 / 390 + d, y: h * 270 / 844 - d)
                blob(DS.Colour.Blob.lavender, size: 320, opacity: 0.42 * k, blur: 80)
                    .position(x: w * 340 / 390 - d, y: h * 590 / 844 + d)
                blob(DS.Colour.Blob.peach, size: 280, opacity: 0.40 * k, blur: 80)
                    .position(x: w * 180 / 390 + d * 0.5, y: h * 824 / 844 - d)
            }
            .frame(width: w, height: h)
            .clipped()
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard drift, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true)) { drifted = true }
        }
    }

    private func blob(_ color: Color, size: CGFloat, opacity: Double, blur: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size).opacity(opacity).blur(radius: blur)
    }
}

#Preview("Ambient background") { AmbientBackground(drift: true) }
