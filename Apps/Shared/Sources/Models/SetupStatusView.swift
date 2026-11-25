import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// What the speech-model setup is doing (§ setup progress): after an install or update the device prepares the
/// bundled models for itself (about 20 s on an iPhone 15). Rendered from `ModelManager.setupSnapshot(at:)` on a
/// timer of its own (the manager never ticks). Content, not floating controls: it sits on plain card surfaces (or
/// inside the processing panel), never glass. All device wording comes from `DeviceCopy`.
///
/// - `.card`: the Library card (and the Mac recording list).
/// - `.settings`: the Speech models screen.
/// - `.compact`: the processing panel of a recording waiting for setup (bar, step and time only).
struct SetupStatusView: View {
    enum Style { case card, settings, compact }

    let style: Style
    /// `AX.Setup.library`, `.modelSettings` or `.processing`.
    let prefix: String
    /// Recordings waiting for setup before they can be processed.
    var waitingCount = 0

    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One update a second and no bar animation under Reduce Motion and in UI tests.
    private var steady: Bool { reduceMotion || env.config.uiTesting }
    private var copy: DeviceCopy { DeviceCopy() }

    var body: some View {
        let models = env.models
        TimelineView(.periodic(from: .now, by: steady ? 1 : 0.25)) { _ in
            let snapshot = models.setupSnapshot(at: models.uptime())
            switch style {
            case .card, .settings: full(snapshot)
            case .compact: compact(snapshot)
            }
        }
    }

    // MARK: Styles

    /// When Ready is held (`.finishing`) the working lines fade out and the card closes up to the headline and the
    /// full bar, animated (none under Reduce Motion or in UI tests), so the list below glides up instead of
    /// jumping; the card's own removal is animated by the list.
    private func full(_ s: SetupSnapshot) -> some View {
        let finishing = s.phase == .finishing
        return VStack(alignment: .leading, spacing: 10) {
            headline(finishing: finishing)
            if !finishing {
                Text(s.stepLine)
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Setup.id(prefix, .step))
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 6) {
                bar(s)
                if !finishing { underBar(s).transition(.opacity) }
            }
            .padding(.vertical, 2)
            if !finishing { notes(s).transition(.opacity) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(steady ? nil : .snappy(duration: 0.35), value: finishing)
        .accessibilityElement(children: .contain)
    }

    /// Inside a recording's panel: the bar, a line labelled as setup ("Setup in progress", never read as the
    /// recording's own steps), the time, and on iPhone the keep-open note.
    private func compact(_ s: SetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            bar(s)
            Text(s.compactLine)
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.Setup.id(prefix, .step))
            timeLines(s)
            if s.phase != .paused, s.phase != .finishing, let keepOpen = copy.setupKeepOpen {
                metaLine(keepOpen, .keepOpenNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    private func headline(finishing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if finishing {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Colour.accent)
                    .accessibilityHidden(true)
            }
            Text(finishing ? copy.setupReadyHeadline : copy.setupHeadline)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Typo.headline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(AX.Setup.id(prefix, .headline))
    }

    private func bar(_ s: SetupSnapshot) -> some View {
        SetupProgressBar(fraction: s.fraction, valueText: s.percentText, animated: !steady)
            .accessibilityIdentifier(AX.Setup.id(prefix, .progress))
    }

    @ViewBuilder
    private func underBar(_ s: SetupSnapshot) -> some View {
        timeLines(s)
        if s.showsResumed { metaLine(copy.setupResumed, .resumedNote) }
    }

    /// The time left (measured on this device), or the hedged first-install line; nothing when neither holds.
    @ViewBuilder
    private func timeLines(_ s: SetupSnapshot) -> some View {
        if let time = s.timeLeftText {
            metaLine(time, .timeLeft).monospacedDigit()
        } else if s.showsTypicalTime {
            metaLine(copy.setupTypicalTime, .typicalTime)
        }
    }

    private func metaLine(_ text: String, _ part: AX.Setup.Part) -> some View {
        Text(text)
            .font(DS.Typo.meta)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AX.Setup.id(prefix, part))
    }

    @ViewBuilder
    private func notes(_ s: SetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if s.phase == .paused {
                note(copy.setupPaused, .pausedNote)
            } else {
                // Only the once-after-an-update setup says so; a warm load that ran slow does not.
                if s.isColdSetup { note(copy.setupOnce, .onceNote) }
                if let keepOpen = copy.setupKeepOpen { note(keepOpen, .keepOpenNote) }
                if waitingCount > 0 {
                    note(copy.setupWaiting(count: waitingCount), .waitingNote)
                } else {
                    note(copy.setupRecordNow, .recordNote)
                }
            }
        }
    }

    private func note(_ text: String, _ part: AX.Setup.Part) -> some View {
        Text(text)
            .font(DS.Typo.subheadline)
            .foregroundStyle(DS.Colour.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AX.Setup.id(prefix, part))
    }
}

/// The setup bar: the 6 pt accent bar on an ink 8% track (like `AccentProgressBar`), as a `ProgressView` so
/// VoiceOver reads it as progress: "Setup progress, 34 percent".
struct SetupProgressBar: View {
    let fraction: Double
    /// "34%".
    let valueText: String
    /// A short linear animation between updates; none under Reduce Motion.
    let animated: Bool

    var body: some View {
        ProgressView(value: Swift.min(1, Swift.max(0, fraction)))
            .progressViewStyle(AccentBarStyle(animated: animated))
            .accessibilityRepresentation { ProgressView(value: Swift.min(1, Swift.max(0, fraction))) }
            .accessibilityLabel("Setup progress")
            .accessibilityValue(valueText)
    }
}

private struct AccentBarStyle: ProgressViewStyle {
    let animated: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        return Capsule()
            .fill(DS.Colour.ink.opacity(0.08))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(DS.Colour.accent)
                        .frame(width: Swift.max(6, geo.size.width * fraction))
                        .animation(animated ? .linear(duration: 0.25) : nil, value: fraction)
                }
            }
            .clipShape(Capsule())
    }
}
