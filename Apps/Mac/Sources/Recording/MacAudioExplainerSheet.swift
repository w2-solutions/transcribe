import SwiftUI
import TranscribeDesign
import TranscribeKit

/// Shown once, before the first recording that captures Mac audio (`settings.macAudioExplained`): macOS is about to
/// ask for "Screen & System Audio Recording", and Transcribe records sound only. macOS has no API that says whether
/// that access was given, so this sheet is the explanation and the recording window's silent note is the follow-up.
struct MacAudioExplainerSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: RecordingSourceCopy.heardThroughMacAudioSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Colour.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.Colour.accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(RecordingSourceCopy.explainerTitle)
                .font(DS.Typo.panelTitle)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text(RecordingSourceCopy.explainerBody)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 20)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(RecordingSourceCopy.explainerCancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AX.MacAudioExplainer.cancel)
                Button(RecordingSourceCopy.explainerContinue, action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AX.MacAudioExplainer.continueButton)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .frame(minHeight: 280)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.MacAudioExplainer.sheet)
    }
}
