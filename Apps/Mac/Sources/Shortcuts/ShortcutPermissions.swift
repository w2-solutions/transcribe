import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Observation
import os
import TranscribeKit

/// What macOS lets the shortcuts and dictation do (the only file that asks TCC, reads the system's own shortcuts and
/// opens System Settings' privacy panes).
///
/// - PostEvent ("Accessibility" in System Settings): posting ⌘V to paste, and an active event tap for fn shortcuts
///   when they do not go through Carbon. Asked for only by the Allow… button in Settings, never from a shortcut, so a
///   system alert never lands in the middle of the user's typing.
/// - ListenEvent ("Input Monitoring"): only looked at when an event tap cannot be created although PostEvent is
///   granted.
/// - The clipboard: whether macOS lets Transcribe read the general pasteboard without asking
///   (`accessBehavior == .alwaysAllow`); only then is the user's clipboard snapshotted and put back after a paste.
///
/// Grants do not reach a running process reliably: `CGPreflightPostEventAccess()` often keeps saying no until
/// Transcribe is quit and reopened, while `AXIsProcessTrusted()` reads the same Accessibility grant live, so both are
/// read (`postEventGranted`). The guided setup (`pasteSetup`) watches for the grant once a second while the user is in
/// System Settings and offers Relaunch Transcribe if it still has not shown after they come back. A UI-test,
/// fake-engine or simulated run (`fixed`) makes no system calls at all and reports nothing allowed.
@MainActor @Observable
final class ShortcutPermissions {
    private(set) var postEventAllowed = false
    /// The guided setup for pasting (Settings → Shortcuts).
    private(set) var pasteSetup = PasteSetup()
    /// Moves on with each poll and return, so `pasteSetupStage` (which depends on time) is read again.
    private(set) var now = Date()
    var pasteSetupStage: PasteSetup.Stage { pasteSetup.stage(allowed: postEventAllowed, now: now) }
    private(set) var listenAllowed = false
    private(set) var clipboardReadable = false
    /// The system's own enabled shortcuts (`CopySymbolicHotKeys`), which the recorder refuses. Empty if the sandbox
    /// refuses the call; the fixed list in `ShortcutValidator` still applies.
    private(set) var systemCombos: Set<ComboKey> = []

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case microphone = "Privacy_Microphone"

        var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
    }

    @ObservationIgnored private let fixed: Bool
    @ObservationIgnored private var loggedSymbolicFailure = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init(fixed: Bool) {
        self.fixed = fixed
        refresh()
        guard !fixed else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            }
    }

    /// Whether Transcribe may post events (paste with ⌘V). `AXIsProcessTrusted()` sees a grant made while Transcribe
    /// runs; `CGPreflightPostEventAccess()` often does not until a relaunch. Both read the Accessibility grant.
    nonisolated static func postEventGranted() -> Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    /// Reads everything again. Values are assigned only when they change, so observers (the shortcut center
    /// re-registers on a change) are not woken for nothing.
    func refresh() {
        guard !fixed else { return }
        let post = Self.postEventGranted()
        let listen = CGPreflightListenEventAccess()
        let readable = NSPasteboard.general.accessBehavior == .alwaysAllow
        let combos = Self.symbolicHotKeys(logFailure: !loggedSymbolicFailure) { self.loggedSymbolicFailure = true }
        if post != postEventAllowed { postEventAllowed = post }
        if listen != listenAllowed { listenAllowed = listen }
        if readable != clipboardReadable { clipboardReadable = readable }
        if combos != systemCombos { systemCombos = combos }
    }

    // MARK: Guided setup for pasting

    /// The guide's Open Accessibility Settings button. The first time, it also asks macOS
    /// (`CGRequestPostEventAccess`), which is what puts Transcribe in the Accessibility list; macOS asks only once, so
    /// later clicks just open the pane. Either way the pane opens straight away and the guide starts watching.
    func openAccessibilityForPasting(firstTime: Bool) {
        guard !fixed else { return }
        if firstTime {
            let granted = CGRequestPostEventAccess()
            shortcutsLog.info("Accessibility requested: \(granted ? "allowed" : "not allowed", privacy: .public)")
        }
        refreshPostEvent()
        guard !postEventAllowed else { return }
        openPane(.accessibility)
        pasteSetup.openedSettings(now: Date())
        now = Date()
        startPolling()
    }

    /// Shows Transcribe.app in Finder, so it can be dragged into the Accessibility list when it is not there.
    func revealAppInFinder() {
        guard !fixed else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func appBecameActive() {
        pasteSetup.appBecameActive(now: Date())
        refreshPostEvent()
        now = Date()
    }

    /// Reads only the Accessibility grant (cheap enough for the guide's once-a-second poll).
    private func refreshPostEvent() {
        let post = Self.postEventGranted()
        guard post != postEventAllowed else { return }
        postEventAllowed = post
        shortcutsLog.info("Accessibility now \(post ? "allowed" : "not allowed", privacy: .public)")
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPostEvent()
                self.now = Date()
                guard self.pasteSetup.shouldPoll(allowed: self.postEventAllowed, now: self.now) else { return }
                try? await Task.sleep(for: PasteSetup.pollInterval)
            }
        }
    }

    /// The Allow… button for Input Monitoring.
    func requestListen() {
        guard !fixed else { return }
        let granted = CGRequestListenEventAccess()
        shortcutsLog.info("Input Monitoring requested: \(granted ? "allowed" : "not allowed", privacy: .public)")
        if !granted { openPane(.inputMonitoring) }
        refresh()
    }

    /// "Keep my clipboard…": one read of the general pasteboard that the user asked for, so macOS shows its
    /// pasteboard prompt now (where the user can choose Always Allow) rather than in the middle of a dictation.
    func askToReadClipboard() {
        guard !fixed else { return }
        _ = NSPasteboard.general.string(forType: .string)
        refresh()
    }

    func openPane(_ pane: Pane) {
        guard !fixed else { return }
        NSWorkspace.shared.open(pane.url)
    }

    /// The enabled entries of the system's symbolic hot keys, as our combos.
    private static func symbolicHotKeys(logFailure: Bool, onFailureLogged: () -> Void) -> Set<ComboKey> {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else {
            if logFailure {
                shortcutsLog.error("CopySymbolicHotKeys failed: \(status, privacy: .public)")
                onFailureLogged()
            }
            return []
        }
        var combos: Set<ComboKey> = []
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, (0..<128).contains(code),
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            combos.insert(ComboKey(keyCode: UInt16(code), modifiers: ShortcutModifiers(carbonMask: UInt32(truncatingIfNeeded: mods))))
        }
        return combos
    }
}

/// Category `shortcuts`, public fields only: action names, backend, status, OSStatus. Never key codes or typed keys.
nonisolated let shortcutsLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "shortcuts")
