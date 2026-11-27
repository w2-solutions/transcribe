import SwiftUI
import TranscribeDesign
import TranscribeKit

/// Settings → Shortcuts' guided setup for pasting, shown under the Accessibility row while pasting is not allowed:
/// three numbered steps (open the pane, turn Transcribe on, come back), a live status line, and Relaunch Transcribe
/// once the user has come back and macOS still says no (`PasteSetup` has the rules). Once allowed it gives way to a
/// one-line "Pasting is on. Try it…".
struct PasteSetupGuide: View {
    @Environment(ShortcutPermissions.self) private var permissions
    @Environment(ShortcutSettings.self) private var settings
    @Environment(MacShortcuts.self) private var shortcuts

    var body: some View {
        let stage = permissions.pasteSetupStage
        VStack(alignment: .leading, spacing: 10) {
            if stage == .allowed {
                Label(PasteSetupCopy.done(holdShortcut: settings.bindings.dictateHold?.display),
                      systemImage: "checkmark.circle.fill")
                    .font(DS.Typo.meta).foregroundStyle(DS.Colour.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Shortcuts.pasteDone)
            } else {
                Text(PasteSetupCopy.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Colour.ink)
                Text(PasteSetupCopy.intro).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                step(1, PasteSetupCopy.step1) {
                    Button(stage == .notStarted ? PasteSetupCopy.openSettings : PasteSetupCopy.openSettingsAgain) {
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AX.Shortcuts.pasteOpenSettings)
                }
                step(2, PasteSetupCopy.step2) {
                    Button(PasteSetupCopy.showInFinder) { permissions.revealAppInFinder() }
                        .controlSize(.small)
                        .accessibilityIdentifier(AX.Shortcuts.pasteShowInFinder)
                }
                step(3, PasteSetupCopy.step3) { EmptyView() }
                status(stage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Shortcuts.pasteGuide)
    }

    @ViewBuilder private func status(_ stage: PasteSetup.Stage) -> some View {
        switch stage {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(PasteSetupCopy.waiting).font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.Shortcuts.pasteStatus)
        case .offerRelaunch:
            VStack(alignment: .leading, spacing: 6) {
                Text(shortcuts.isCapturing ? PasteSetupCopy.relaunchBusy : PasteSetupCopy.relaunchHint)
                    .font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Shortcuts.pasteStatus)
                Button(PasteSetupCopy.relaunch) { AppRelauncher.relaunch() }
                    .controlSize(.small)
                    .disabled(shortcuts.isCapturing)
                    .accessibilityIdentifier(AX.Shortcuts.pasteRelaunch)
            }
        case .notStarted, .allowed:
            EmptyView()
        }
    }

    private func step<Accessory: View>(_ number: Int, _ text: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(DS.Typo.meta.weight(.semibold)).foregroundStyle(DS.Colour.accentText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.Colour.accentFill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(DS.Typo.meta).foregroundStyle(DS.Colour.ink)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func openSettings() {
        let firstTime = !settings.askedPostEvent
        settings.askedPostEvent = true
        permissions.openAccessibilityForPasting(firstTime: firstTime)
    }
}
