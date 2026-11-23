import SwiftUI

public struct StatusPill: View {
    public enum Style: Sendable, Equatable { case accent, neutral, progress(Double), failed }
    /// accent: accentFill bg, accentText 12 semibold, 24 tall, padding 9 ("✓ Voices recognised", "New" (11 pt, 18 tall)).
    /// neutral: ink 5–7% bg, secondary text ("Speakers pending", "You"). progress: neutral + tiny ring. failed: destructive text.
    let text: String
    let systemImage: String?
    let style: Style
    let compact: Bool

    public init(_ text: String, systemImage: String? = nil, style: Style = .neutral, compact: Bool = false) {
        self.text = text; self.systemImage = systemImage; self.style = style; self.compact = compact
    }

    private var foreground: Color {
        switch style {
        case .accent: DS.Colour.accentText
        case .neutral, .progress: DS.Colour.secondary
        case .failed: DS.Colour.destructive
        }
    }

    private var background: Color {
        switch style {
        case .accent: DS.Colour.accentFill
        case .neutral, .progress: DS.Colour.neutralFill
        case .failed: DS.Colour.destructive.opacity(0.10)
        }
    }

    public var body: some View {
        HStack(spacing: 5) {
            if case .progress(let fraction) = style {
                ZStack {
                    Circle().stroke(DS.Colour.accent.opacity(0.16), lineWidth: 2)
                    Circle().trim(from: 0, to: Swift.max(0.04, Swift.min(1, fraction)))
                        .stroke(DS.Colour.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? 7 : 9)
        .frame(height: compact ? 18 : 24)
        .background(Capsule(style: .continuous).fill(background))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#Preview("Status pills") {
    VStack(alignment: .leading, spacing: 10) {
        StatusPill("Voices recognised", systemImage: "checkmark", style: .accent)
        StatusPill("New", style: .accent, compact: true)
        StatusPill("Speakers pending")
        StatusPill("You", compact: true)
        StatusPill("Separating speakers… 2/3", style: .progress(0.6))
        StatusPill("Couldn't process", style: .failed)
    }
    .padding()
    .screenBackground()
}
