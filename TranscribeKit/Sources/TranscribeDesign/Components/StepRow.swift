import SwiftUI

public struct StepRow: View {
    public enum State: Sendable, Equatable { case done, active(Double?), waiting, skipped }
    /// 28 pt indicator column + connector (2 pt; accent 35% after done, ink 10% otherwise; hidden when !showsConnector).
    /// done: accent disc + white check (shadow accent 0.28). active: ring spinner (track accent 16%, arc accent, 2.4 stroke;
    /// static arc under Reduce Motion). waiting: tertiary 2 pt ring. skipped: tertiary ring + minus.
    /// Title 16 semibold ink (waiting: 16 medium secondary); subtitle 13 secondary (active: 13 medium accentText).
    let title: String
    let subtitle: String
    let state: State
    let showsConnector: Bool

    public init(title: String, subtitle: String, state: State, showsConnector: Bool) {
        self.title = title; self.subtitle = subtitle; self.state = state; self.showsConnector = showsConnector
    }

    private var isWaiting: Bool { state == .waiting || state == .skipped }
    private var isActive: Bool { if case .active = state { true } else { false } }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                StepIndicator(state: state).frame(width: 28, height: 28)
                if showsConnector {
                    Capsule()
                        .fill(state == .done ? DS.Colour.accent.opacity(0.35) : DS.Colour.ink.opacity(0.10))
                        .frame(width: 2)
                        .frame(minHeight: 14, maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(isWaiting ? .medium : .semibold))
                    .foregroundStyle(isWaiting ? DS.Colour.secondary : DS.Colour.ink)
                Text(subtitle)
                    .font(.footnote.weight(isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? DS.Colour.accentText : DS.Colour.secondary)
            }
            .padding(.top, 3)
            .padding(.bottom, showsConnector ? 16 : 0)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(stateLabel)")
        .accessibilityValue(subtitle)
    }

    private var stateLabel: String {
        switch state { case .done: "done"; case .active: "in progress"; case .waiting: "waiting"; case .skipped: "skipped" }
    }
}

private struct StepIndicator: View {
    let state: StepRow.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        switch state {
        case .done:
            Circle().fill(DS.Colour.accent)
                .overlay { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                .shadow(color: DS.Colour.accent.opacity(0.28), radius: 5, x: 0, y: 3)
        case .active:
            ZStack {
                Circle().stroke(DS.Colour.accent.opacity(0.16), lineWidth: 2.4)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(DS.Colour.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            }
            .padding(2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
            }
        case .waiting:
            Circle().strokeBorder(DS.Colour.tertiary, lineWidth: 2).padding(2)
        case .skipped:
            Circle().strokeBorder(DS.Colour.tertiary, lineWidth: 2).padding(2)
                .overlay { Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Colour.tertiary) }
        }
    }
}

#Preview("Step rows") {
    VStack(alignment: .leading, spacing: 0) {
        StepRow(title: "Transcribed", subtitle: "Parakeet, on device", state: .done, showsConnector: true)
        StepRow(title: "Separating speakers", subtitle: "Listening for different voices · 60%", state: .active(0.6), showsConnector: true)
        StepRow(title: "Matching saved voices", subtitle: "Compared with Liam and Karan", state: .waiting, showsConnector: false)
    }
    .padding(22)
    .floatingGlass(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenBackground()
}
