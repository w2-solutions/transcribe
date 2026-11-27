import AppKit
import SwiftUI
import TranscribeKit

/// The menu bar item's icon: the app icon's seven bars as a template image (`MenuBarIcon`), with a record dot beside
/// them while a meeting records (`MenuBarIconRecording`), as the Dock badge shows. The user hides the item in System
/// Settings → Menu Bar.
struct MacMenuBarLabel: View {
    let env: AppEnvironment
    let dictation: DictationController

    var body: some View {
        let state = MenuBarState.resolve(recorder: env.recorder.state, dictationBusy: dictation.isBusy,
                                         launched: env.isLaunched)
        Image(state.icon == .recording ? "MenuBarIconRecording" : "MenuBarIcon")
            .accessibilityLabel(state.label)
            .accessibilityIdentifier(AX.Mac.menuBarItem)
    }
}

/// The menu bar item's menu. New Recording and Stop Recording do what the "Start or stop a recording" shortcut does
/// (`MeetingShortcut`): with another app in front no window opens and the HUD says what happened; with Transcribe in
/// front the Recording window shows. Its items carry no accessibility identifiers: SwiftUI gives every item of this
/// menu the identifier `menuAction:` whatever the view sets (read through Accessibility on macOS 27), so a UI test
/// finds them by title, as for the app's other menus.
struct MacMenuBarMenu: View {
    let env: AppEnvironment
    let shortcuts: MacShortcuts
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = MenuBarState.resolve(recorder: env.recorder.state, dictationBusy: shortcuts.dictation.isBusy,
                                         launched: env.isLaunched)
        Button(state.recordTitle) { shortcuts.toggleMeeting() }
            .disabled(!state.recordEnabled)
        Button(MenuBarCopy.openApp) {
            NSApplication.shared.activate()
            openWindow(id: "main")
        }
        Divider()
        // A menu bar item's menu never activates the app, so Settings would open behind the app in front.
        Button(MenuBarCopy.settings) {
            NSApplication.shared.activate()
            openSettings()
        }
        Divider()
        Button(MenuBarCopy.quit) { NSApplication.shared.terminate(nil) }
    }
}
