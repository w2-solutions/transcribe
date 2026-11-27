import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The HUD's glass capsule: a symbol, a title and a detail line, and during a dictation the input level and at most
/// two lines of live text (the most recent words; the panel is kept out of screen sharing). The wording is
/// `DictationHUD`'s. No buttons: a click anywhere on a notice with an action runs it (`HUDPanel`).
struct HUDView: View {
    let presenter: HUDPresenter
    let dictation: DictationController
    let models: ModelManager
    let settings: ShortcutSettings

    var body: some View {
        switch presenter.mode {
        case .hidden:
            EmptyView()
        case .dictation:
            if let live = DictationHUD.live(state: dictation.phase, escapeConfirmPending: dictation.escapeConfirmPending,
                                            modelsReady: models.isReady, bindings: settings.bindings) {
                capsule(symbol: "mic.fill", tint: DS.Colour.accent, title: live.title, detail: live.detail,
                        liveText: liveText, levels: isListening ? dictation.levels : nil)
            }
        case .message(let message):
            capsule(symbol: message.symbol, tint: tint(message.tone), title: message.title, detail: message.detail,
                    liveText: nil, levels: nil)
        }
    }

    private var isListening: Bool {
        if case .listening = dictation.phase { return true }
        return false
    }

    /// The live words while listening (shown only once live text runs, under the engine hold).
    private var liveText: String? {
        guard isListening else { return nil }
        let text = (dictation.liveText.confirmed + " " + dictation.liveText.volatile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func tint(_ tone: HUDMessage.Tone) -> Color {
        switch tone {
        case .neutral: DS.Colour.ink
        case .accent: DS.Colour.accent
        case .record, .problem: DS.Colour.record
        }
    }

    private func capsule(symbol: String, tint: Color, title: String, detail: String?, liveText: String?,
                         levels: [Float]?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.Colour.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(AX.Dictation.hudTitle)
                if let detail {
                    Text(detail)
                        .font(DS.Typo.meta)
                        .foregroundStyle(DS.Colour.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier(AX.Dictation.hudDetail)
                }
                if let liveText {
                    Text(liveText)
                        .font(DS.Typo.meta)
                        .foregroundStyle(DS.Colour.ink)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            .frame(minWidth: 180, maxWidth: 340, alignment: .leading)
            if let levels {
                LevelBars(levels: levels, tint: tint)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minWidth: 280, maxWidth: 440, minHeight: 56)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Dictation.hud)
    }
}

/// Twelve bars of the most recent input levels.
private struct LevelBars: View {
    let levels: [Float]
    let tint: Color

    static let count = 12

    var body: some View {
        let recent = Array(levels.suffix(Self.count))
        let padded = Array(repeating: Float(0), count: max(0, Self.count - recent.count)) + recent
        HStack(alignment: .center, spacing: 2) {
            ForEach(padded.indices, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 4 + 18 * CGFloat(min(max(padded[i], 0), 1)))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}
