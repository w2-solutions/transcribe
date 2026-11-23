import SwiftUI

/// Glass capsule.
public struct Toast: View {
    let text: String
    let systemImage: String?
    public init(_ text: String, systemImage: String? = nil) { self.text = text; self.systemImage = systemImage }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
            Text(text).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(DS.Colour.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

public extension View {
    /// Shows Toast (accessibility id `id`) at the top for 2 s whenever `text` changes to a non-nil value.
    func toast(_ text: String?, systemImage: String? = nil, id: String) -> some View {
        modifier(ToastModifier(text: text, systemImage: systemImage, id: id))
    }
}

private struct ToastModifier: ViewModifier {
    let text: String?
    let systemImage: String?
    let id: String
    @State private var shown: String?
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    Toast(shown, systemImage: systemImage)
                        .accessibilityIdentifier(id)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: text) { _, new in
                guard let new else { return }
                withAnimation(.snappy) { shown = new }
                generation += 1
            }
            .task(id: generation) {
                guard generation > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { shown = nil }
            }
    }
}

#Preview("Toast") {
    Text("Content").frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Toast("Moment marked 0:14", systemImage: "bookmark.fill").padding(.top, 8) }
        .screenBackground()
}
