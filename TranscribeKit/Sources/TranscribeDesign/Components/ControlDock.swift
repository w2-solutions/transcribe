import SwiftUI

public struct ControlDock<Content: View>: View {
    /// GlassEffectContainer(spacing: 18) { HStack(spacing: 18) { content } }, centred; place in safeAreaBar(edge: .bottom).
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        GlassEffectContainer(spacing: DS.Space.dockGap) {
            HStack(spacing: DS.Space.dockGap) { content }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

#Preview("Control dock") {
    VStack { Spacer() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            ControlDock {
                GlassCircleButton(systemImage: "square.and.arrow.down", size: .large, accessibilityLabel: "Import audio file") {}
                RecordButton(mode: .record, accessibilityLabel: "Start recording") {}
                GlassCircleButton(systemImage: "person.2", size: .large, accessibilityLabel: "Voices") {}
            }
        }
        .screenBackground()
}
