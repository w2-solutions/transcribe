import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Collapsed processing progress (§6.3): a glass capsule reading "Separating speakers · 60%" with a tiny progress
/// ring. `TranscriptView` (WP6) places it in `safeAreaBar(edge: .top)` and expands the panel when it is tapped.
struct CollapsedProgressPill: View {
    let recordingID: UUID
    @Environment(AppEnvironment.self) private var env
    @Query private var matches: [Recording]
    @Query(sort: \VoiceProfile.namedAt) private var profiles: [VoiceProfile]

    init(recordingID: UUID) {
        self.recordingID = recordingID
        _matches = Query(filter: #Predicate<Recording> { $0.id == recordingID })
    }

    var body: some View {
        let state = ProcessingPanelData.state(for: recordingID, recording: matches.first, profiles: profiles, env: env)
        HStack(spacing: 8) {
            ProgressRing(fraction: state.overall, isWaiting: state.isWaitingForModels)
                .frame(width: 14, height: 14)
            Text(state.collapsedText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colour.ink)
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(minHeight: 36)
        .contentShape(Capsule())
        .floatingGlass(Capsule(), interactive: true)
        .frame(minHeight: DS.Space.hit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.collapsedText)
        .accessibilityHint("Shows processing details")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AX.Processing.collapsedPill)
    }
}

/// Tiny accent ring (accent 16% track); dashed while waiting for models.
private struct ProgressRing: View {
    let fraction: Double
    let isWaiting: Bool

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colour.accent.opacity(0.16), lineWidth: 2)
            if !isWaiting {
                Circle()
                    .trim(from: 0, to: Swift.max(0.04, Swift.min(1, fraction)))
                    .stroke(DS.Colour.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: fraction)
            }
        }
        .accessibilityHidden(true)
    }
}
