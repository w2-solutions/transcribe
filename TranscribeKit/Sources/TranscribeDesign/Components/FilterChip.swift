import SwiftUI

public struct FilterChip: View {
    /// 36 tall, padding 16 (14 with dot); selected: ink fill, white 14 semibold; else plainCapsule, ink 14 medium.
    let title: String
    let isSelected: Bool
    let dotColor: Color?
    let action: () -> Void

    public init(title: String, isSelected: Bool, dotColor: Color? = nil, action: @escaping () -> Void) {
        self.title = title; self.isSelected = isSelected; self.dotColor = dotColor; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor { Circle().fill(dotColor).frame(width: 8, height: 8) }
                Text(title)
                    .scaledFont(size: 14, weight: isSelected ? .semibold : .medium, relativeTo: .subheadline)
                    .foregroundStyle(isSelected ? DS.Colour.onInk : DS.Colour.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, dotColor == nil ? 16 : 14)
            .frame(minHeight: 36)
            .background {
                if isSelected { Capsule(style: .continuous).fill(DS.Colour.ink) }
            }
            .modifier(PlainCapsuleIf(enabled: !isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlainCapsuleIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.plainCapsule() } else { content }
    }
}

#Preview("Filter chips") {
    HStack(spacing: 8) {
        FilterChip(title: "All", isSelected: true) {}
        FilterChip(title: "Favourites", isSelected: false) {}
        FilterChip(title: "Folders", isSelected: false) {}
        FilterChip(title: "Unnamed", isSelected: false, dotColor: DS.Colour.unnamed) {}
    }
    .padding()
    .screenBackground()
}
