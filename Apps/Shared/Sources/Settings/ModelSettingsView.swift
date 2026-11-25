import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Speech models screen (§6.10): read-only. The models ship inside the app, so this only shows what is included
/// and whether it is ready on this iPhone. While the models get ready it shows the setup progress at once (no
/// reveal delay: the user opened this screen to see it).
struct ModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var recordings: [Recording]

    private var models: ModelManager { env.models }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(DeviceCopy().modelsIntro)
                    .font(DS.Typo.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                SectionHeader("Models").padding(.top, 22).padding(.bottom, 6)
                SettingsCard {
                    modelRow(systemImage: "waveform", title: "Parakeet TDT v3 · Speech")
                        .accessibilityIdentifier(AX.ModelSettings.speechRow)
                    modelRow(systemImage: "person.2.wave.2", title: "Speaker separation")
                        .accessibilityIdentifier(AX.ModelSettings.speakersRow)
                }

                statusBlock.padding(.top, 14)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.ModelSettings.screen)
        .navigationTitle("Speech models")
        .inlineNavigationTitle()
        .screenBackground()
        .task { await models.refresh() }
    }

    // MARK: Status

    @ViewBuilder
    private var statusBlock: some View {
        if models.isSettingUp {
            SetupStatusView(style: .settings, prefix: AX.Setup.modelSettings,
                            waitingCount: ModelsCard.waitingCount(recordings))
                .cardSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AX.ModelSettings.status)
        } else {
            readyOrFailed
        }
    }

    /// Ready, or the failure (unchanged).
    private var readyOrFailed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(models.failureText == nil ? DS.Colour.secondary : DS.Colour.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.ModelSettings.status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var statusText: String {
        if case .failed(let reason) = models.status { return reason }
        return DeviceCopy().modelsReady
    }

    private var statusSymbol: String {
        if case .failed = models.status { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if case .failed = models.status { return DS.Colour.destructive }
        return DS.Colour.accent
    }

    private func modelRow(systemImage: String, title: String) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                Text(componentValue).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            }
            Spacer(minLength: 8)
            if models.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(DS.Colour.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(minHeight: DS.Size.settingsRow)
        .accessibilityElement(children: .combine)
    }

    /// "Included · Ready", "Included · Getting ready" or "Included · Not ready".
    private var componentValue: String {
        switch models.status {
        case .ready: "Included · Ready"
        case .installed, .preparing: "Included · Getting ready"
        case .failed: "Included · Not ready"
        }
    }
}
