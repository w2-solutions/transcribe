import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// "Get speech models" (§6.1): shown at the top of the Library while the models are not installed, installing or
/// failed. Recording still works meanwhile; recordings wait for the models before processing.
struct ModelsCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isConfirmingCellular = false

    private var models: ModelManager { env.models }
    private var info: EngineInfo { env.engine.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch models.status {
            case .notInstalled, .installed, .preparing, .ready:
                notInstalled
            case .installing(let progress):
                installing(progress)
            case .failed(let reason):
                failed(reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.modelsCard)
        .confirmationDialog("You're on mobile data. Download \(models.downloadSizeText) now?",
                            isPresented: $isConfirmingCellular, titleVisibility: .visible) {
            Button("Download now") { download() }
                .accessibilityIdentifier(AX.Library.cellularConfirm)
            Button("Wait for Wi-Fi", role: .cancel) {}
        }
    }

    // MARK: States

    private var lacksSpace: Bool {
        guard let free = models.freeBytes else { return false }
        return free < ModelManager.requiredFreeBytes
    }

    @ViewBuilder private var notInstalled: some View {
        Text("Get speech models")
            .font(DS.Typo.headline)
            .foregroundStyle(DS.Colour.ink)
            .accessibilityAddTraits(.isHeader)
        Text("Parakeet speech (\(Self.megabytes(info.speechDownloadBytes))) and voice separation (\(Self.megabytes(info.speakersDownloadBytes))) download once. After that everything runs on this iPhone, even offline.")
            .font(DS.Typo.subheadline)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if lacksSpace {
            Label("Free up about 1.5 GB to download the models.", systemImage: "externaldrive.badge.exclamationmark")
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.destructive)
        } else if models.isExpensiveNetwork {
            Label("Wi-Fi recommended", systemImage: "wifi")
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
        }
        PrimaryButton("Download (\(models.downloadSizeText))") {
            if models.isExpensiveNetwork { isConfirmingCellular = true } else { download() }
        }
        .disabled(lacksSpace)
        .padding(.top, 4)
        .accessibilityIdentifier(AX.Library.modelsDownloadButton)
    }

    @ViewBuilder private func installing(_ progress: ModelInstallProgress) -> some View {
        Text("Getting speech models")
            .font(DS.Typo.headline)
            .foregroundStyle(DS.Colour.ink)
            .accessibilityAddTraits(.isHeader)
        AccentProgressBar(fraction: progress.fraction)
            .padding(.top, 2)
            .accessibilityElement()
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int((progress.fraction * 100).rounded()))%")
            .accessibilityIdentifier(AX.Library.modelsProgress)
        Text(phaseText(progress))
            .font(DS.Typo.meta)
            .foregroundStyle(DS.Colour.secondary)
            .monospacedDigit()
        Text("You can record meanwhile. Recordings are processed once the models are ready.")
            .font(DS.Typo.meta)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func failed(_ reason: String) -> some View {
        Text("Couldn't get speech models")
            .font(DS.Typo.headline)
            .foregroundStyle(DS.Colour.ink)
            .accessibilityAddTraits(.isHeader)
        Text(reason)
            .font(DS.Typo.subheadline)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
        GlassCapsuleButton("Try again", systemImage: "arrow.clockwise", height: 44) { download() }
            .padding(.top, 4)
            .accessibilityIdentifier(AX.Library.modelsRetryButton)
    }

    // MARK: Helpers

    private func download() {
        let models = self.models
        Task { await models.install() }
    }

    /// "Downloading speech model · 212 of 483 MB", "Speaker models · 221 MB", "Preparing for this iPhone…".
    private func phaseText(_ progress: ModelInstallProgress) -> String {
        switch progress.phase {
        case .checking:
            return "Checking what's needed…"
        case .downloading(.speech, _, _):
            let total = Double(info.speechDownloadBytes)
            let share = Double(info.speechDownloadBytes) / Double(Swift.max(1, info.totalDownloadBytes))
            let done = Swift.min(1, Swift.max(0, progress.fraction / Swift.max(share, 0.01))) * total
            return "Downloading speech model · \(Int(done / 1_000_000)) of \(Self.megabytes(info.speechDownloadBytes))"
        case .downloading(.speakers, _, _):
            return "Speaker models · \(Self.megabytes(info.speakersDownloadBytes))"
        case .compiling:
            return "Preparing for this iPhone… (one time, about a minute)"
        }
    }

    static func megabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
}

/// 6 pt accent progress bar on an ink 8% track (models card, processing panel).
struct AccentProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(DS.Colour.ink.opacity(0.08))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(DS.Colour.accent)
                        .frame(width: Swift.max(6, geo.size.width * Swift.min(1, Swift.max(0, fraction))))
                        .animation(.snappy, value: fraction)
                }
            }
            .clipShape(Capsule())
    }
}
