import SwiftUI

public struct GlassCircleButton: View {
    public enum Size: Sendable { case regular, large }          // 44 / 52
    let systemImage: String
    let size: Size
    let label: String
    let action: () -> Void

    public init(systemImage: String, size: Size = .regular, accessibilityLabel: String, action: @escaping () -> Void) {
        self.systemImage = systemImage; self.size = size; self.label = accessibilityLabel; self.action = action
    }

    private var diameter: CGFloat { size == .large ? DS.Size.dockButton : DS.Size.toolbarButton }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size == .large ? 22 : 20, weight: .medium))
                .foregroundStyle(DS.Colour.ink)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

#Preview("Glass circle buttons") {
    HStack(spacing: 18) {
        GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: "Minimise recording") {}
        GlassCircleButton(systemImage: "square.and.arrow.down", size: .large, accessibilityLabel: "Import audio file") {}
        GlassCircleButton(systemImage: "person.2", size: .large, accessibilityLabel: "Voices") {}
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenBackground()
}
