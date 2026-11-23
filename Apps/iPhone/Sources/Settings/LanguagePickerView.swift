import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Language hint picker (§6.10): Automatic plus the 25 Parakeet v3 languages.
struct LanguagePickerView: View {
    @Environment(AppEnvironment.self) private var env

    private struct Option: Identifiable {
        let id: String          // "auto" or ISO 639-1
        let name: String
        let hint: LanguageHint
    }

    private var options: [Option] {
        [Option(id: "auto", name: "Automatic", hint: .automatic)]
            + Languages.parakeetV3.map { Option(id: $0.code, name: $0.name, hint: .language($0.code)) }
    }

    var body: some View {
        let selected = env.settings.language
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DividedCard(dividerInset: 16) {
                    ForEach(options) { option in
                        Button { env.settings.language = option.hint } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                                    if option.hint == .automatic {
                                        Text("Parakeet detects the language").font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if option.hint == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(DS.Colour.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: DS.Size.settingsRow)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(option.hint == selected ? [.isSelected] : [])
                        .accessibilityIdentifier(AX.Language.option(option.id))
                    }
                }
                .padding(.top, 8)

                Text("A language hint helps Parakeet. Live text follows the same setting.")
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Language.screen)
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .screenBackground()
    }
}
