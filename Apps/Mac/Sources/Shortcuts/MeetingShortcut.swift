import AppKit
import TranscribeCore
import TranscribeKit

/// "Start or stop a recording" from any app: what the record button does, without a view. It never brings
/// Transcribe forward or opens a window while another app is in front; a short notice (the HUD) and the Dock badge
/// show instead. With Transcribe in front it presents the Recording window as the toolbar button does.
@MainActor final class MeetingShortcut {
    private let env: AppEnvironment
    private let router: Router
    private let selection: MacSelection
    private let opener: MacWindowOpener
    private let dictation: DictationController
    private let hud: HUDPresenter
    private let settings: ShortcutSettings
    /// A start is on its way: the recorder only reports `.starting` once its task runs, so a second press in between
    /// must not start another.
    private var isStarting = false

    init(env: AppEnvironment, router: Router, selection: MacSelection, opener: MacWindowOpener,
         dictation: DictationController, hud: HUDPresenter, settings: ShortcutSettings) {
        self.env = env; self.router = router; self.selection = selection; self.opener = opener
        self.dictation = dictation; self.hud = hud; self.settings = settings
    }

    /// `fromMenuBar`: the menu bar's New Recording, whose HUD names no shortcut.
    func toggle(fromMenuBar: Bool = false) {
        if dictation.isBusy {
            hud.show(DictationHUD.meetingRefusedBusy)
            return
        }
        guard !isStarting else { return }
        switch env.recorder.state {
        case .starting, .stopping:
            return
        case .recording, .paused:
            stop()
        case .idle:
            start(fromMenuBar: fromMenuBar)
        }
    }

    private func start(fromMenuBar: Bool) {
        isStarting = true
        env.player.stop()
        Task {
            defer { isStarting = false }
            do {
                try await env.recorder.start()
                if NSApplication.shared.isActive {
                    router.presentRecording()
                    // The main window may be closed, and it is what turns `isRecordingPresented` into a window.
                    opener.open("recording")
                } else {
                    hud.show(fromMenuBar ? MenuBarCopy.recordingStarted
                                         : DictationHUD.meetingStarted(bindings: settings.bindings))
                }
            } catch EngineError.microphoneDenied {
                hud.show(DictationHUD.micDenied)
            } catch {
                hud.show(DictationHUD.meetingFailed(LibraryErrors.message(for: error)))
            }
        }
    }

    private func stop() {
        Task {
            guard let id = try? await env.recorder.stop() else { return }
            router.isRecordingPresented = false
            // The main window's `onChange` closes the Recording window, but only while the main window is open.
            opener.dismiss("recording")
            if selection.sidebar == .voices { selection.sidebar = .all }
            selection.recording = id
            if !NSApplication.shared.isActive { hud.show(DictationHUD.meetingSaved) }
        }
    }
}
