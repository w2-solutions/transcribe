import AppKit
import Observation
import SwiftUI
import TranscribeDesign
import TranscribeKit

/// The control that records one global shortcut (Settings → Shortcuts). Idle, it shows the binding ("fn Z", or "Off")
/// with a clear button. Clicked, it listens: the next key with its modifiers becomes the binding if
/// `ShortcutValidator` accepts it, else the section shows why and the old binding stays.
///
/// - While it listens, the global shortcuts are suspended (`ShortcutCenter.suspend`), so pressing the current
///   shortcut records it instead of starting a dictation, and every key goes to this field, menu shortcuts included
///   (⌘N is refused here, never starts a recording).
/// - Esc alone cancels; ⌫ alone turns the shortcut Off. Esc can never be a shortcut: it cancels dictation.
/// - Listening ends on a key, on a click anywhere, when the window stops being key, or after 15 s; every way out
///   resumes the shortcuts.
/// - Nothing typed here is stored or logged except the binding itself.
struct ShortcutRecorderField: View {
    let action: ShortcutAction
    /// The last recording's verdict: a problem to show, or nil after a good one.
    let onResult: (ShortcutProblem?) -> Void

    @Environment(ShortcutSettings.self) private var settings
    @Environment(ShortcutCenter.self) private var center
    @Environment(ShortcutPermissions.self) private var permissions
    @State private var listener = ShortcutKeyListener()

    var body: some View {
        let combo = settings.bindings[action]
        let listening = listener.isListening
        let title = ShortcutCopy.title(action)
        HStack(spacing: 4) {
            Button { toggleListening() } label: {
                Text(listening ? (listener.liveModifiers.isEmpty ? ShortcutCopy.typeShortcut : listener.liveModifiers)
                               : combo?.display ?? ShortcutCopy.off)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(listening ? DS.Colour.accentText : combo == nil ? DS.Colour.secondary : DS.Colour.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 92, minHeight: 26)
                    .background(Capsule(style: .continuous).fill(listening ? DS.Colour.accentFill : DS.Colour.neutralFill))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(listening ? DS.Colour.accent : Color.clear, lineWidth: 1.5)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(listening ? "Press the new shortcut. Esc cancels, ⌫ turns it off." : "Click to change")
            .accessibilityLabel(title)
            .accessibilityValue(listening ? ShortcutCopy.typeShortcut : combo?.spokenLabel ?? ShortcutCopy.off)
            .accessibilityHint(listening ? "Press the new shortcut. Escape cancels, Delete turns it off."
                                         : "Click, then press a new shortcut")
            .accessibilityIdentifier(AX.Shortcuts.recorder(action.rawValue))

            if combo != nil, !listening {
                Button { save(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colour.secondary)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Turn off this shortcut")
                .accessibilityLabel("Turn off \(title)")
                .accessibilityIdentifier(AX.Shortcuts.clear(action.rawValue))
            } else {
                // Keeps the capsule where it was when the clear button goes.
                Color.clear.frame(width: 22, height: 26).accessibilityHidden(true)
            }
        }
        .onDisappear { listener.stop() }
    }

    private func toggleListening() {
        if listener.isListening {
            listener.stop()
            return
        }
        // The click that ended listening (outside this field's own handling) also reaches this button: it must not
        // start listening again straight away.
        guard !listener.endedByClickJustNow else { return }
        center.suspend()
        listener.start(onKey: { keyCode, modifiers, characters in
            handle(keyCode: keyCode, modifiers: modifiers, characters: characters)
        }, onEnd: { [center] in
            center.resume()
        })
    }

    private func handle(keyCode: UInt16, modifiers: ShortcutModifiers, characters: String?) {
        if modifiers.isEmpty, keyCode == KeyCodes.escape { return }          // cancel: the old binding stays
        if modifiers.isEmpty, keyCode == KeyCodes.delete { save(nil); return }
        let label = KeyCodes.label(keyCode) ?? KeyboardLayout.label(for: keyCode)
            ?? characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
        if let problem = ShortcutValidator.validate(combo, for: action, in: settings.bindings,
                                                    systemCombos: permissions.systemCombos) {
            onResult(problem)
            return
        }
        save(combo)
    }

    private func save(_ combo: KeyCombo?) {
        settings.set(combo, for: action)
        shortcutsLog.info("\(action.rawValue, privacy: .public): \(combo == nil ? "turned off" : "changed", privacy: .public)")
        onResult(nil)
    }
}

/// Listens to this app's own key events while the recorder field records (an `NSEvent` local monitor: no permission,
/// and only events sent to Transcribe's windows). Every key event is consumed while it listens, so nothing typed
/// reaches a text field or a menu.
@MainActor @Observable
final class ShortcutKeyListener {
    private(set) var isListening = false
    /// The modifiers held right now, as the field shows them while waiting for the key ("fn ⇧", "⌃⌥").
    private(set) var liveModifiers = ""

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var onEnd: (() -> Void)?
    @ObservationIgnored private var endedByClickAt: ContinuousClock.Instant?

    static let listenLimit: Duration = .seconds(15)

    /// True for a moment after a click ended listening, so the same click does not start it again.
    var endedByClickJustNow: Bool {
        guard let endedByClickAt else { return false }
        return ContinuousClock.now - endedByClickAt < .milliseconds(600)
    }

    /// `onKey` gets each key press (key code, modifiers, the characters it typed); listening then ends, so the field
    /// shows the result. `onEnd` runs once, however listening ends.
    func start(onKey: @escaping (UInt16, ShortcutModifiers, String?) -> Void, onEnd: @escaping () -> Void) {
        stop()
        isListening = true
        liveModifiers = ""
        self.onEnd = onEnd
        endedByClickAt = nil

        // Local monitors run on the main thread. Only plain values cross into the main actor; the event itself is
        // returned (passed on) or nil (consumed) out here.
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isKey = event.type == .keyDown
            let keyCode = event.keyCode
            let flags = UInt64(event.modifierFlags.rawValue)
            let isRepeat = isKey && event.isARepeat
            let characters = isKey ? event.charactersIgnoringModifiers : nil
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isListening else { return false }
                if !isKey {
                    self.liveModifiers = ShortcutModifiers(eventFlags: flags, keyCode: nil).symbols
                } else if !isRepeat {
                    self.stop()
                    onKey(keyCode, ShortcutModifiers(eventFlags: flags, keyCode: keyCode), characters)
                }
                return true
            }
            return consumed ? nil : event
        }
        // A click anywhere ends listening; the click itself goes on as usual.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isListening else { return }
                self.stop()
                self.endedByClickAt = .now
            }
            return event
        }
        monitors = [keys, clicks].compactMap { $0 }
        if let window = NSApplication.shared.keyWindow {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.listenLimit)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        timeout?.cancel()
        timeout = nil
        let wasListening = isListening
        isListening = false
        liveModifiers = ""
        let end = onEnd
        onEnd = nil
        if wasListening { end?() }
    }
}
