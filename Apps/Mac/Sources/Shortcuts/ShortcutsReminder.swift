import SwiftUI
import TranscribeDesign
import TranscribeKit

/// The sidebar's quiet note, below the update reminder: "Shortcuts need permission". Shown in a live run while a
/// shortcut cannot work, or dictation could only copy, until Settings → Shortcuts has been opened once
/// (`MacShortcuts.showsPermissionNote`). Clicking it opens Settings at Shortcuts. Never a window or a system prompt:
/// macOS's own Accessibility prompt only ever comes from the Allow… button there.
struct ShortcutsReminder: View {
    @Environment(MacShortcuts.self) private var shortcuts

    var body: some View {
        if shortcuts.showsPermissionNote {
            Button { shortcuts.showShortcutSettings() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard").font(.system(size: 10, weight: .bold))
                    Text(ShortcutCopy.sidebarNote)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(DS.Colour.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule(style: .continuous).fill(DS.Colour.neutralFill))
                .frame(minHeight: DS.Space.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("Open Settings → Shortcuts")
            .accessibilityLabel(ShortcutCopy.sidebarNote)
            .accessibilityHint("Opens Settings at Shortcuts")
            .accessibilityIdentifier(AX.Mac.sidebarShortcuts)
        }
    }
}
