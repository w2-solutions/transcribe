import SwiftUI

public struct RecordButton: View {
    public enum Mode: Sendable { case record, stop }
    /// 84 pt glass ring (.glassEffect(.regular.interactive(), in: .circle)) around a 62 pt #E5484D disc,
    /// or a 30 pt radius-8 square for .stop. Inner highlight + glow (0,4,14) record at 0.45. Morph animates.
    let mode: Mode
    let label: String
    let action: () -> Void

    public init(mode: Mode, accessibilityLabel: String, action: @escaping () -> Void) {
        self.mode = mode; self.label = accessibilityLabel; self.action = action
    }

    public var body: some View {
        let side = mode == .record ? DS.Size.recordInner : DS.Size.stopSquare
        let shape = RoundedRectangle(cornerRadius: mode == .record ? side / 2 : 8, style: .continuous)
        Button(action: action) {
            shape
                .fill(DS.Colour.record)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center),
                                       lineWidth: 2)
                }
                .frame(width: side, height: side)
                .shadow(color: DS.Colour.record.opacity(0.45), radius: 7, x: 0, y: 4)
                .frame(width: DS.Size.recordOuter, height: DS.Size.recordOuter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(.bouncy(duration: 0.35), value: mode)
        .accessibilityLabel(label)
    }
}

#Preview("Record button") {
    HStack(spacing: 30) {
        RecordButton(mode: .record, accessibilityLabel: "Start recording") {}
        RecordButton(mode: .stop, accessibilityLabel: "Stop recording") {}
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenBackground()
}
