import Carbon
import TranscribeKit

/// Carbon hot keys (the only file that calls `RegisterEventHotKey` and `InstallEventHandler`). They need no
/// permission, work in the sandbox, swallow the key, and report both press and release, so hold-to-talk works too.
/// Every shortcut without fn uses them; fn shortcuts too while `ShortcutRouting.fnViaCarbon` is set (Carbon's fn mask,
/// `kEventKeyModifierFnMask`, registers on macOS 27; whether it fires is the owner's hardware check).
///
/// Registered with `kEventHotKeyExclusive`, so a combo another app holds fails with `eventHotKeyExistsErr` instead of
/// registering quietly and never firing. Esc is registered without it: it is held only while a dictation can be
/// cancelled, and if it fails the dictation simply cannot be cancelled by key.
///
/// Carbon delivers hot key events on the main thread's event loop, so the handler is main-actor code. It is a
/// `nonisolated` static function (a C function pointer cannot carry an actor) that asserts that with
/// `MainActor.assumeIsolated`. Lives for the life of the app (owned by `ShortcutCenter`), so the handler's unretained
/// reference never dangles.
@MainActor final class CarbonHotkeys {
    /// 'TRNS'
    nonisolated static let signature: OSType = 0x5452_4E53

    enum ID {
        static let escape: UInt32 = 9
        static func of(_ action: ShortcutAction) -> UInt32 {
            switch action {
            case .toggleRecording: 1
            case .dictateHold: 2
            case .dictateToggle: 3
            }
        }
        static func action(_ id: UInt32) -> ShortcutAction? {
            ShortcutAction.allCases.first { of($0) == id }
        }
    }

    /// (id, pressed): pressed is false for a release.
    private let onEvent: @MainActor (UInt32, Bool) -> Void
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init(onEvent: @escaping @MainActor (UInt32, Bool) -> Void) {
        self.onEvent = onEvent
    }

    /// Registers `combo` under `id`, replacing what that id held. noErr on success; anything else (most often
    /// `eventHotKeyExistsErr`, another app's exclusive hot key) leaves nothing registered under `id`.
    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        register(keyCode: combo.keyCode, modifiers: combo.modifiers.carbonMask, id: id,
                 options: OptionBits(kEventHotKeyExclusive))
    }

    /// Plain Esc, while a dictation can be cancelled and no event tap is running.
    func registerEscape() -> OSStatus {
        register(keyCode: KeyCodes.escape, modifiers: 0, id: ID.escape, options: OptionBits(kEventHotKeyNoOptions))
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    private func register(keyCode: UInt16, modifiers: UInt32, id: UInt32, options: OptionBits) -> OSStatus {
        unregister(id: id)
        let installed = installHandlerIfNeeded()
        guard installed == noErr else { return installed }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), options, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handler == nil else { return noErr }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.handle, specs.count, &specs,
                                         Unmanaged.passUnretained(self).toOpaque(), &installed)
        if status == noErr { handler = installed }
        return status
    }

    fileprivate func received(id: UInt32, pressed: Bool) {
        onEvent(id, pressed)
    }

    /// The Carbon event handler. Only our own signature is handled; anything else goes on to the next handler.
    private nonisolated static let handle: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard status == noErr, hotKey.signature == CarbonHotkeys.signature else { return OSStatus(eventNotHandledErr) }
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let id = hotKey.id
        let hotkeys = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { hotkeys.received(id: id, pressed: pressed) }
        return noErr
    }
}
