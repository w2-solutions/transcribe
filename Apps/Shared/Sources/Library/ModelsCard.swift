import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Speech models card (§6.1), at the top of the Library (and the Mac recording list):
/// - while the models get ready after an install or update, the setup progress (`SetupStatusView`), revealed only
///   when setup takes longer than a moment (`ModelManager.setupCard`), then "Ready" briefly;
/// - when the bundled models fail to load or are missing from this copy of the app, the failure and "Try again".
/// Recording works meanwhile; recordings wait for the models before processing.
struct ModelsCard: View {
    /// Recordings waiting for setup (from the list's own query).
    var waitingCount = 0
    @Environment(AppEnvironment.self) private var env

    private var models: ModelManager { env.models }

    /// The card shows while setup runs (once revealed) or after a failure.
    static func isShown(_ models: ModelManager) -> Bool {
        if case .failed = models.status { return true }
        return models.setupCard != .hidden
    }

    /// Recordings stored as waiting for the speech models.
    static func waitingCount(_ recordings: [Recording]) -> Int {
        recordings.filter { $0.stage.isProcessing && $0.queueReason == .modelsNotReady }.count
    }

    var body: some View {
        Group {
            if case .failed = models.status {
                failure
            } else {
                SetupStatusView(style: .card, prefix: AX.Setup.library, waitingCount: waitingCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.modelsCard)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speech models couldn't load")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Colour.ink)
                .accessibilityAddTraits(.isHeader)
            Text(models.failureText ?? ModelManager.Copy.loadFailed)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GlassCapsuleButton("Try again", systemImage: "arrow.clockwise", height: 44) { retry() }
                .padding(.top, 4)
                .accessibilityIdentifier(AX.Library.modelsRetryButton)
        }
    }

    private func retry() {
        let models = self.models
        Task { await models.retry() }
    }
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
