import SwiftUI

/// Ink capsule, white 17 semibold.
public struct PrimaryButton: View {
    let title: String
    let height: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, height: CGFloat = 52, action: @escaping () -> Void) {
        self.title = title; self.height = height; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.Colour.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule(style: .continuous).fill(DS.Colour.ink.opacity(isEnabled ? 1 : 0.25)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 44 tall ink capsule 15 semibold ("Name speakers").
public struct InkPillButton: View {
    let title: String
    let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colour.onInk)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule(style: .continuous).fill(DS.Colour.ink))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Floating glass capsule button ("Continue in background", "Copy", "Try again", "No").
/// Use `.glassCapsuleFullWidth()` to stretch it to the available width.
public struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String?
    let height: CGFloat
    let action: () -> Void
    @Environment(\.glassCapsuleFullWidth) private var fullWidth
    @Environment(\.glassCapsuleCompact) private var compact
    @ScaledMetric(relativeTo: .subheadline) private var compactFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var compactIconSize: CGFloat = 16

    public init(_ title: String, systemImage: String? = nil, height: CGFloat = 50, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.height = height; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 7 : 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(compact ? .system(size: compactIconSize, weight: .semibold) : .system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(compact ? .system(size: compactFontSize, weight: .semibold) : .body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(DS.Colour.ink)
            .padding(.leading, compact ? 14 : 20)
            .padding(.trailing, compact ? 16 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension EnvironmentValues {
    @Entry var glassCapsuleFullWidth: Bool = false
    @Entry var glassCapsuleCompact: Bool = false
}

public extension View {
    /// Makes `GlassCapsuleButton`s inside stretch to the available width.
    func glassCapsuleFullWidth(_ enabled: Bool = true) -> some View { environment(\.glassCapsuleFullWidth, enabled) }
    /// The smaller capsule of the transcript's Copy button: 14 pt semibold label, icon gap 7, padding 14 / 16.
    func glassCapsuleCompact(_ enabled: Bool = true) -> some View { environment(\.glassCapsuleCompact, enabled) }
}

/// accentText, min 44 tall
public struct LinkButton: View {
    let title: String
    let systemImage: String?
    let font: Font
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, font: Font = .subheadline.weight(.semibold), action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.font = font; self.action = action
    }

    private var iconTrailing: Bool { systemImage?.hasPrefix("chevron") ?? false }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage, !iconTrailing { Image(systemName: systemImage) }
                Text(title)
                if let systemImage, iconTrailing { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            }
            .font(font)
            .foregroundStyle(DS.Colour.accentText)
            .frame(minHeight: DS.Space.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Buttons") {
    VStack(spacing: 16) {
        PrimaryButton("Save and label 2 turns") {}
        PrimaryButton("Continue") {}.disabled(true)
        InkPillButton("Name speakers") {}
        GlassCapsuleButton("Continue in background") {}.glassCapsuleFullWidth()
        GlassCapsuleButton("Copy", systemImage: "doc.on.doc", height: 44) {}
        LinkButton("Show transcript now") {}
        LinkButton("Speaker settings", systemImage: "chevron.right") {}
        LinkButton("Wrong speaker? Change", systemImage: "arrow.left.arrow.right", font: .footnote.weight(.semibold)) {}
    }
    .padding(20)
    .screenBackground()
}
