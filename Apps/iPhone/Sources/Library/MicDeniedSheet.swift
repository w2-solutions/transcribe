import SwiftUI
import TranscribeDesign
import UIKit

/// Shown when recording is attempted with the microphone permission denied (§6.1).
struct MicDeniedSheet: View {
    /// Called after the sheet dismisses itself because the user chose "Import an audio file instead".
    let onImportInstead: () -> Void
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
            Text("Transcribe needs the microphone to record. Audio stays on this iPhone.")
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 20)
            PrimaryButton("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier(AX.Library.MicDenied.openSettings)
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
