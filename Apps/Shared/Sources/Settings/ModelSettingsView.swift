import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Speech models screen (§6.10): read-only. The models ship inside the app, so this only shows what is included
/// and whether it is ready on this iPhone.
struct ModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    private var models: ModelManager { env.models }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("These come with Transcribe. Speech and speakers are processed on this iPhone, even offline. Nothing is downloaded.")
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
        VStack(alignment: .leading, spacing: 10) {
            if isPreparing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.Colour.accent)
                    .accessibilityLabel("Preparing models")
                    .accessibilityIdentifier(AX.ModelSettings.progress)
            }
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

    private var isPreparing: Bool {
        switch models.status {
        case .installed, .preparing: true
        case .ready, .failed: false
        }
    }

    private var statusText: String {
        switch models.status {
        case .ready: "Ready. Everything runs on this iPhone, even offline."
        case .installed, .preparing: ModelManager.Copy.preparing
        case .failed(let reason): reason
        }
    }

    private var statusSymbol: String {
        switch models.status {
        case .ready: "checkmark.circle.fill"
        case .installed, .preparing: "gearshape.2"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch models.status {
        case .ready: DS.Colour.accent
        case .failed: DS.Colour.destructive
        case .installed, .preparing: DS.Colour.secondary
        }
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

    /// "Included · Ready", "Included · Preparing" or "Included · Not ready".
    private var componentValue: String {
        switch models.status {
        case .ready: "Included · Ready"
        case .installed, .preparing: "Included · Preparing"
        case .failed: "Included · Not ready"
        }
    }
}
