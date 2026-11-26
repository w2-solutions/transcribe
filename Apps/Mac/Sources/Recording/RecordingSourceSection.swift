import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Settings → Recording (Mac only, shown when this Mac can record Mac audio): what New Recording captures. The choice
/// is this Mac's (`settings.recordingSource`), never synced, and the toolbar menu and File → Record From change the
/// same setting. Disabled while a recording runs: a running recording keeps what it started with.
struct RecordingSourceSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.macAudioAvailable {
            @Bindable var settings = env.settings
            SectionHeader("Recording").padding(.top, 14).padding(.bottom, 6)
            SettingsCard {
                Menu {
                    Picker(RecordingSourceCopy.pickerTitle, selection: $settings.recordingSource) {
                        ForEach(CaptureSources.allCases, id: \.self) { source in
                            Label(RecordingSourceCopy.title(source), systemImage: RecordingSourceCopy.symbol(source))
                                .tag(source)
                                .accessibilityIdentifier(AX.RecordingSource.option(source.rawValue))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ValueRow(systemImage: RecordingSourceCopy.symbol(settings.recordingSource), tint: .accent,
                             title: RecordingSourceCopy.pickerTitle, value: RecordingSourceCopy.title(settings.recordingSource),
                             accessory: .menu)
                }
                .buttonStyle(.plain)
                .disabled(env.recorder.isActive)
                .accessibilityValue(RecordingSourceCopy.title(settings.recordingSource))
                .accessibilityIdentifier(AX.RecordingSource.picker)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AX.RecordingSource.section)
            Text(RecordingSourceCopy.footnote)
                .font(DS.Typo.meta)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityIdentifier(AX.RecordingSource.footnote)
        }
    }
}
