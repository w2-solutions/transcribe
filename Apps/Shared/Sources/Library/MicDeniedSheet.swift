import SwiftUI
import TranscribeDesign
import TranscribeKit

/// Shown when recording is attempted with the microphone permission denied (§6.1).
struct MicDeniedSheet: View {
    /// Called after the sheet dismisses itself because the user chose "Import an audio file instead".
    let onImportInstead: () -> Void
    @Environment(AppEnvironment.self) private var env
    /// Mac, Both mode: called after the sheet dismisses itself because the user chose "Record Mac audio only". Nil
    /// hides that choice (the iPhone, and the Mac recording the microphone only).
    var onMacAudioOnly: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DS.Colour.record)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(DS.Colour.record.opacity(0.12)))
                    .accessibilityHidden(true)
                Spacer()
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
                    .accessibilityIdentifier(AX.Library.MicDenied.close)
            }
            Text("Microphone access is off")
                .font(DS.Typo.panelTitle)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            // Sync-aware: with Sync audio on, audio does not stay on this device, so the sheet does not say it does.
            Text(env.copy.micDeniedBody)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 20)
            PrimaryButton("Open Settings") {
                openURL(Platform.micSettingsURL)
            }
            .accessibilityIdentifier(AX.Library.MicDenied.openSettings)
            if let onMacAudioOnly {
                LinkButton(RecordingSourceCopy.macAudioOnlyInstead, font: .subheadline.weight(.semibold)) {
                    dismiss()
                    onMacAudioOnly()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityIdentifier(AX.Library.MicDenied.macAudioOnly)
            }
            LinkButton("Import an audio file instead", font: .subheadline.weight(.semibold)) {
                dismiss()
                onImportInstead()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .accessibilityIdentifier(AX.Library.MicDenied.importInstead)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.MicDenied.sheet)
    }
}
