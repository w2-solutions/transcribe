import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Speech models card (§6.1): shown at the top of the Library only when the bundled models fail to load or are
/// missing from this copy of the app. Recording still works meanwhile; recordings wait for the models before
/// processing.
struct ModelsCard: View {
    @Environment(AppEnvironment.self) private var env

    private var models: ModelManager { env.models }

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.modelsCard)
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
