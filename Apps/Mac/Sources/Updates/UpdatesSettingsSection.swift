import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Settings → Updates (Mac only, §2): "Check for updates automatically" (Sparkle's own setting, which it asks about
/// once, on the second launch), Check for Updates…, the version, and what an update check sends. With updates off
/// (Debug, test runs, an unconfigured build) the controls are disabled and the note says why.
struct UpdatesSettingsSection: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Updates").padding(.top, 14).padding(.bottom, 6)
            SettingsCard {
                ToggleRow(systemImage: "arrow.triangle.2.circlepath", tint: .neutral, title: "Check for updates automatically",
                          isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }),
                          isEnabled: updater.availability == .on)
                    .accessibilityIdentifier(AX.Updates.automatic)
                Button { updater.checkForUpdates() } label: {
                    ValueRow(systemImage: "arrow.down.circle", tint: .neutral, title: "Check for Updates…", value: nil)
                }
                .buttonStyle(.plain)
                .disabled(!updater.controlsEnabled)
                .accessibilityIdentifier(AX.Updates.checkNow)
                ValueRow(systemImage: "info.circle", tint: .neutral, title: "Version", value: SettingsView.versionText, accessory: .none)
                    .accessibilityIdentifier(AX.Settings.versionRow)
            }
            Text(UpdateCopy.note(for: updater.availability))
                .font(DS.Typo.meta)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityIdentifier(AX.Updates.note)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Updates.section)
    }
}
