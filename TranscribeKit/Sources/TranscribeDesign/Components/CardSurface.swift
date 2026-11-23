import SwiftUI

extension DS.Colour {
    /// Text/icons drawn on an `ink` fill (white in light mode, near-black in dark mode).
    static let onInk = Color.adaptive(light: Color.white, dark: Color(hex: 0x0E1116))
}

public extension View {
    /// AmbientBackground behind the whole screen + hides scroll content background. Every screen root uses it.
    func screenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
    }

    /// Plain content card: cardFill, 1 pt cardStroke, radius 28 default, shadow (0, 6, blur 24) at 0.07. NOT glass.
    func cardSurface(padding: EdgeInsets = EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18),
                     radius: CGFloat = DS.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .padding(padding)
            .background {
                shape.fill(DS.Colour.cardFill)
                    .overlay { shape.strokeBorder(DS.Colour.cardStroke, lineWidth: 1) }
                    .shadow(color: DS.Colour.shadow.opacity(0.07), radius: 12, x: 0, y: 6)
            }
    }

    /// Plain capsule: chipFill + chipStroke (filter chips, clip rows, in-card play buttons). NOT glass.
    func plainCapsule() -> some View {
        background {
            Capsule(style: .continuous).fill(DS.Colour.chipFill)
                .overlay { Capsule(style: .continuous).strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
        }
    }

    /// Floating glass capsule/rounded rect: `.glassEffect(.regular.interactive(interactive), in: shape)` — padding first.
    func floatingGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        glassEffect(.regular.interactive(interactive), in: shape)
    }
}

#Preview("Card surface") {
    VStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wed 18 Nov · 2:29 pm").font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            Text("Just checking if it remembers who is speaking, like if it'll auto-detect that I'm Liam.")
                .font(DS.Typo.cardBody).foregroundStyle(DS.Colour.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        Text("Favourites").font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(height: 36).plainCapsule()
        Text("Moment marked 0:14").padding(.horizontal, 16).padding(.vertical, 10).floatingGlass(Capsule())
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenBackground()
}
