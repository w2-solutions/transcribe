import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 9 (§6.9): speakers, transcription, general and about settings.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Query private var profiles: [VoiceProfile]
    @State private var privacyExpanded = false
    @State private var toastText: String?
    @State private var toastIcon = "checkmark"

    var body: some View {
        @Bindable var settings = env.settings
        let saved = VoicesListModel.sortedProfiles(profiles)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // SPEAKERS
                SectionHeader("Speakers", badge: "New").padding(.top, 12).padding(.bottom, 6)
                SettingsCard {
                    ToggleRow(systemImage: "person.2.wave.2", tint: .accent, title: "Identify speakers",
                              isOn: $settings.identifySpeakers)
                        .accessibilityIdentifier(AX.Settings.identifySpeakers)
                    ToggleRow(systemImage: "person.crop.circle.badge.checkmark", tint: .accent, title: "Recognise saved voices",
                              isOn: Binding(get: { settings.identifySpeakers && settings.recogniseVoices },
                                            set: { settings.recogniseVoices = $0 }),
                              isEnabled: settings.identifySpeakers)
                        .accessibilityIdentifier(AX.Settings.recogniseVoices)
                    Button { openVoices() } label: {
                        ValueRow(systemImage: "person.2", tint: .accent, title: "Voices", value: "\(saved.count) saved",
                                 accessory: .dots(saved.prefix(2).map(\.colourSlot)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.voicesRow)
                    ValueRow(systemImage: "clock", tint: .accent, title: "Run", value: "After recording", accessory: .none)
                        .accessibilityIdentifier(AX.Settings.runRow)
                    Button { copyLog() } label: {
                        ValueRow(systemImage: "doc.on.clipboard", tint: .neutral, title: "Copy voice matching log", value: nil,
                                 accessory: .none)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Copies match scores for tuning. No voices, names or text.")
                    .accessibilityIdentifier(AX.Settings.copyMatchLogRow)
                }
                footnote("Speaker separation runs on-device once a recording ends.")

                // TRANSCRIPTION
                SectionHeader("Transcription").padding(.top, 14).padding(.bottom, 6)
                SettingsCard {
                    Button { router.path.append(.modelSettings) } label: {
                        ValueRow(systemImage: "waveform", tint: .neutral, title: "Model", value: env.models.settingsValue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.modelRow)
                    Button { router.path.append(.language) } label: {
                        ValueRow(systemImage: "globe", tint: .neutral, title: "Language", value: Languages.displayName(settings.language))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.languageRow)
                    ToggleRow(systemImage: "text.badge.minus", tint: .neutral, title: "Remove filler words", isOn: $settings.removeFillers)
                        .accessibilityIdentifier(AX.Settings.removeFillers)
                }

                // GENERAL
                SectionHeader("General").padding(.top, 14).padding(.bottom, 6)
                SettingsCard {
                    Menu {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        ValueRow(systemImage: "circle.lefthalf.filled", tint: .neutral, title: "Appearance",
                                 value: settings.appearance.title, accessory: .menu)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.appearanceRow)
                    Menu {
                        Picker("Auto copy", selection: $settings.autoCopy) {
                            ForEach(CopyFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        ValueRow(systemImage: "doc.on.doc", tint: .neutral, title: "Auto copy", value: settings.autoCopy.title,
                                 accessory: .none)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.autoCopyRow)
                }

                // ICLOUD (§8.6): off by default.
                SyncSettingsSection()

                // ABOUT
                SectionHeader("About").padding(.top, 14).padding(.bottom, 6)
                SettingsCard {
                    Button { router.path.append(.attributions) } label: {
                        ValueRow(systemImage: "heart.text.square", tint: .neutral, title: "Acknowledgements", value: nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AX.Settings.acknowledgementsRow)
                    VStack(alignment: .leading, spacing: 0) {
                        Button { withAnimation(.snappy) { privacyExpanded.toggle() } } label: {
                            ValueRow(systemImage: "lock.shield", tint: .neutral, title: "Privacy", value: env.copy.privacyValue,
                                     accessory: .none)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(privacyExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Shows how your data is stored")
                        .accessibilityIdentifier(AX.Settings.privacyRow)
                        if privacyExpanded {
                            Text(env.copy.privacyDetail)
                                .font(DS.Typo.meta)
                                .lineSpacing(3)
                                .foregroundStyle(DS.Colour.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 58)
                                .padding(.trailing, 16)
                                .padding(.bottom, 14)
                                .transition(.opacity)
                                .accessibilityIdentifier(AX.Settings.privacyDetail)
                        }
                    }
                    ValueRow(systemImage: "info.circle", tint: .neutral, title: "Version", value: Self.versionText, accessory: .none)
                        .accessibilityIdentifier(AX.Settings.versionRow)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 12, weight: .semibold))
                    Text("All audio is processed on this device.")
                }
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AX.Settings.footer)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Settings.screen)
        .navigationTitle("Settings")
        .largeNavigationTitle()
        .screenBackground()
        .toast(toastText, systemImage: toastIcon, id: AX.Settings.copiedToast)
        .task { await env.models.refresh() }
    }

    /// Match scores and settings for tuning thresholds (no vectors, names, titles or text), on this device's clipboard only.
    private func copyLog() {
        do {
            Pasteboard.copyPrivate(try env.store.matchingLog())
            showToast("Log copied", systemImage: "checkmark")
        } catch {
            showToast("Couldn't copy the log", systemImage: "exclamationmark.triangle")
        }
    }

    private func showToast(_ text: String, systemImage: String) {
        toastText = nil
        toastIcon = systemImage
        Task {
            await Task.yield()
            toastText = text
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.meta)
            .lineSpacing(2)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 6)
    }

    /// Back to Voices when the user came from there; otherwise push it.
    private func openVoices() {
        if let i = router.path.lastIndex(of: .voices) {
            router.path.removeSubrange((i + 1)...)
        } else {
            router.path.append(.voices)
        }
    }

    /// "1.0 (1)"
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
