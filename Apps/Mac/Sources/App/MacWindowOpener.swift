import Observation
import SwiftUI

/// SwiftUI's window actions, for code that runs outside any view: the meeting shortcut, the HUD's click, and the Stop
/// Recording menu command. `openWindow`, `dismissWindow` and `openSettings` only exist in a view's environment, so the
/// main window and the Recording window hand theirs over when they appear. Until one of them has appeared (a launch
/// that restored no window) every action is nil, and callers carry on without it: the meeting shortcut still starts
/// and stops the recording and shows the HUD.
///
/// Closing a window through its own environment action matters because the main window may be closed: the Recording
/// window used to close only through the main window's `onChange` of `router.isRecordingPresented`, so with the main
/// window closed a recording stopped from the menu or a shortcut left an idle Recording window on screen.
@MainActor @Observable
final class MacWindowOpener {
    @ObservationIgnored private(set) var openWindow: OpenWindowAction?
    @ObservationIgnored private(set) var dismissWindow: DismissWindowAction?
    @ObservationIgnored private(set) var openSettings: OpenSettingsAction?

    /// Called from `onAppear` of the main window and the Recording window. The actions are the same for every
    /// window of the app, so the last one in wins.
    func fill(open: OpenWindowAction, dismiss: DismissWindowAction, settings: OpenSettingsAction? = nil) {
        openWindow = open
        dismissWindow = dismiss
        if let settings { openSettings = settings }
    }

    func open(_ id: String) { openWindow?(id: id) }
    func dismiss(_ id: String) { dismissWindow?(id: id) }

    /// Brings Transcribe to the front with its main window (the HUD's "Open Transcribe" click).
    func showApp() {
        NSApplication.shared.activate()
        open("main")
    }

    /// Brings Transcribe to the front with its Settings window. Without a window's action yet, the main window
    /// opens instead.
    func showSettings() {
        NSApplication.shared.activate()
        if let openSettings { openSettings() } else { open("main") }
    }
}
