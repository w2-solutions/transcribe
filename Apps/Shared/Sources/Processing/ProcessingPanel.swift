import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The "Working out who said what" panel (§6.3): a floating glass panel at the bottom of the processing
/// transcript. `TranscriptView` (WP6) places it, collapses it on "Show transcript now" and removes it once the
/// recording is ready (the panel shows three ticks when the stage reaches `.ready`).
///
/// The panel never grows past `maxHeight` (the space under the navigation bar): at large text sizes the
/// heading, steps and progress scroll inside it while the buttons stay pinned at its foot.
struct ProcessingPanel: View {
    let recordingID: UUID
    var maxHeight: CGFloat = .infinity
    let onContinueInBackground: () -> Void
    let onShowTranscriptNow: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Query private var matches: [Recording]
    @Query(sort: \VoiceProfile.namedAt) private var profiles: [VoiceProfile]
    @State private var infoHeight: CGFloat = 0
    @State private var buttonsHeight: CGFloat = 0

    /// Padding (26 + 14) and the grabber (5 + 16 − 14) around the scrolling part and the buttons.
    private static let chrome: CGFloat = 47

    init(recordingID: UUID, maxHeight: CGFloat = .infinity,
         onContinueInBackground: @escaping () -> Void, onShowTranscriptNow: @escaping () -> Void) {
        self.recordingID = recordingID
        self.maxHeight = maxHeight
        self.onContinueInBackground = onContinueInBackground
        self.onShowTranscriptNow = onShowTranscriptNow
        _matches = Query(filter: #Predicate<Recording> { $0.id == recordingID })
    }

    var body: some View {
        let state = ProcessingPanelData.state(for: recordingID, recording: matches.first, profiles: profiles, env: env)
        let scrollLimit = Swift.max(120, maxHeight - Self.chrome - buttonsHeight)
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(DS.Colour.ink.opacity(0.16))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, -14)
                .padding(.bottom, 16)
                .accessibilityHidden(true)

            ScrollView {
                info(state)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { infoHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(infoHeight > scrollLimit ? .automatic : .hidden)
            .frame(height: infoHeight > 0 ? Swift.min(infoHeight, scrollLimit) : nil)

            buttons
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
        }
        .padding(EdgeInsets(top: 26, leading: 22, bottom: 14, trailing: 22))
        .floatingGlass(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Processing.panel)
    }

    private func info(_ state: ProcessingViewState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.heading)
                .font(DS.Typo.panelTitle)
                .tracking(-0.4)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AX.Processing.heading)
            Text(state.message)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.steps.enumerated()), id: \.element.id) { i, status in
                    StepRow(title: ProcessingViewState.rowTitle(status), subtitle: status.subtitle,
                            state: Self.rowState(status.state), showsConnector: i < state.steps.count - 1)
                        .accessibilityValue(status.axValue)
                        .accessibilityHint(status.subtitle)
                        .accessibilityIdentifier(AX.Processing.step(ProcessingViewState.slug(status.step)))
                }
            }
            .padding(.top, 22)
            .animation(.snappy, value: state.steps)

            VStack(alignment: .leading, spacing: 8) {
                AccentProgressBar(fraction: state.overall)
                    .accessibilityElement()
                    .accessibilityLabel("Processing progress")
                    .accessibilityValue(state.progressValueText)
                    .accessibilityIdentifier(AX.Processing.progressBar)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        stepCounter(state)
                        Spacer(minLength: 8)
                        privacyLine
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        stepCounter(state)
                        privacyLine
                    }
                }
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepCounter(_ state: ProcessingViewState) -> some View {
        Text(state.stepCounterText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AX.Processing.stepCounter)
    }

    private var privacyLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock").font(.system(size: 11, weight: .semibold))
            Text(env.copy.nothingLeaves).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        VStack(spacing: 4) {
            GlassCapsuleButton("Continue in background", height: 50, action: onContinueInBackground)
                .glassCapsuleFullWidth()
                .accessibilityIdentifier(AX.Processing.continueInBackground)
            LinkButton("Show transcript now", font: .subheadline.weight(.semibold), action: onShowTranscriptNow)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AX.Processing.showTranscriptNow)
        }
        .padding(.top, 22)
    }

    static func rowState(_ state: StepState) -> StepRow.State {
        switch state {
        case .waiting: .waiting
        case .active(let f): .active(f)
        case .done: .done
        case .skipped: .skipped
        }
    }
}

/// Builds the panel's view state from the persisted row, the live monitor snapshot and the saved voices.
@MainActor
enum ProcessingPanelData {
    static func state(for id: UUID, recording: Recording?, profiles: [VoiceProfile], env: AppEnvironment) -> ProcessingViewState {
        let modelKey = env.engine.info.embeddingModel.key
        let names = profiles
            .filter { $0.embeddingModelKey == modelKey && !$0.needsResample && !$0.samples.isEmpty }
            .sorted { ($0.isMe ? 0 : 1, $0.namedAt) < ($1.isMe ? 0 : 1, $1.namedAt) }
            .map(\.name)
        return ProcessingViewState(stage: recording?.stage ?? .queued, queueReason: recording?.queueReason,
                                   snapshot: env.monitor.snapshot(for: id), savedVoiceNames: names,
                                   identifySpeakers: env.settings.identifySpeakers,
                                   recogniseVoices: env.settings.recogniseVoices)
    }
}
