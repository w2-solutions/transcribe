import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Speech models screen (§6.10): what is installed, download progress, download and remove.
struct ModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmCellular = false
    @State private var confirmRemove = false

    private var models: ModelManager { env.models }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Transcribe downloads these once. After that, speech and speakers are processed on this iPhone, even offline.")
                    .font(DS.Typo.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                SectionHeader("Models").padding(.top, 22).padding(.bottom, 6)
                SettingsCard {
                    modelRow(systemImage: "waveform", title: "Parakeet TDT v3 · Speech", size: models.speechSizeText, component: .speech)
                        .accessibilityIdentifier(AX.ModelSettings.speechRow)
                    modelRow(systemImage: "person.2.wave.2", title: "Speaker separation", size: models.speakersSizeText, component: .speakers)
                        .accessibilityIdentifier(AX.ModelSettings.speakersRow)
                }

                statusBlock.padding(.top, 14)

                VStack(spacing: 12) {
                    if showsDownload {
                        GlassCapsuleButton(downloadTitle, systemImage: "arrow.down.circle") { requestDownload() }
                            .glassCapsuleFullWidth()
                            .disabled(!models.canInstall)
                            .opacity(models.canInstall ? 1 : 0.5)
                            .accessibilityIdentifier(AX.ModelSettings.downloadButton)
                            .confirmationDialog("You're on mobile data. Download \(models.downloadSizeText) now?",
                                                isPresented: $confirmCellular, titleVisibility: .visible) {
                                Button("Download now") { startDownload() }
                                    .accessibilityIdentifier(AX.ModelSettings.cellularConfirm)
                                Button("Wait for Wi-Fi", role: .cancel) {}
                            }
                    }
                    if models.canRemove {
                        // GlassCapsuleButton in destructive colour (the component fixes its text to ink).
                        Button { confirmRemove = true } label: {
                            Label("Remove models", systemImage: "trash")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DS.Colour.destructive)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .floatingGlass(Capsule(), interactive: true)
                        .accessibilityIdentifier(AX.ModelSettings.removeButton)
                        .confirmationDialog("Remove \(models.downloadSizeText) of models?", isPresented: $confirmRemove,
                                            titleVisibility: .visible) {
                            Button("Remove", role: .destructive) { Task { await models.remove() } }
                                .accessibilityIdentifier(AX.ModelSettings.removeConfirm)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Recording still works; processing waits until you download again.")
                        }
                    }
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.ModelSettings.screen)
        .navigationTitle("Speech models")
        .navigationBarTitleDisplayMode(.inline)
        .screenBackground()
        .task { await models.refresh() }
    }

    // MARK: Status

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fraction = models.installFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.Colour.accent)
                    .scaleEffect(x: 1, y: 1.5, anchor: .center)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
                    .accessibilityIdentifier(AX.ModelSettings.progress)
            } else if models.status == .preparing || models.status == .installed {
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
            if showsDownload && models.isExpensiveNetwork && models.hasEnoughSpace {
                Text(ModelManager.Copy.wifiRecommended).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            }
            if showsDownload && !models.hasEnoughSpace {
                Text(ModelManager.Copy.lowSpace).font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var statusText: String {
        switch models.status {
        case .ready: "Ready. Everything runs on this iPhone, even offline."
        case .installing, .installed, .preparing: models.phaseText ?? ModelManager.Copy.preparing
        case .notInstalled: "Not downloaded. Recording still works; processing waits for the models."
        case .failed(let reason): reason
        }
    }

    private var statusSymbol: String {
        switch models.status {
        case .ready: "checkmark.circle.fill"
        case .installing: "arrow.down.circle"
        case .installed, .preparing: "gearshape.2"
        case .notInstalled: "icloud.and.arrow.down"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch models.status {
        case .ready: DS.Colour.accent
        case .failed: DS.Colour.destructive
        default: DS.Colour.secondary
        }
    }

    private func modelRow(systemImage: String, title: String, size: String, component: ModelComponent) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                Text(componentValue(size: size, component: component)).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
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

    private func componentValue(size: String, component: ModelComponent) -> String {
        switch models.status {
        case .ready: return "\(size) · Ready"
        case .installed, .preparing: return "\(size) · Preparing"
        case .installing(let p):
            switch (p.phase, component) {
            case (.downloading(.speakers, _, _), .speech), (.compiling, _): return "\(size) · Downloaded"
            case (.downloading(.speech, _, _), .speakers), (.checking, _): return "\(size) · Waiting"
            default: return "\(size) · Downloading"
            }
        case .notInstalled, .failed: return "\(size) · Not downloaded"
        }
    }

    // MARK: Download

    private var showsDownload: Bool {
        switch models.status {
        case .notInstalled, .failed: true
        default: false
        }
    }

    private var downloadTitle: String {
        if case .failed = models.status { return "Download again" }
        return "Download (\(models.downloadSizeText))"
    }

    private func requestDownload() {
        models.refreshFreeSpace()
        guard models.canInstall else { return }
        if models.isExpensiveNetwork { confirmCellular = true } else { startDownload() }
    }

    private func startDownload() {
        Task { await models.install() }
    }
}
