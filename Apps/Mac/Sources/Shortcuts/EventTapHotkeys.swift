import CoreGraphics
import Foundation
import Synchronization
import TranscribeKit

/// The active session event tap for fn shortcuts when they do not go through Carbon (`ShortcutRouting.fnViaCarbon`
/// false); the only file that creates a `CGEventTap`.
///
/// - Active (`.defaultTap`), never listen-only: a listen-only tap cannot swallow the key, so fn Z would also type a
///   "z" into the app in front. It needs the PostEvent grant (Accessibility); without it `tapCreate` returns nil.
/// - It never swallows flagsChanged: other apps, and macOS's own 🌐 handling, must always see modifiers change.
/// - `HotkeyTracker` (pure, tested) decides what to swallow and what to report; the callback only converts the event,
///   runs the tracker under a lock and hands the results to the main queue. It must stay tiny: a slow callback gets the
///   tap disabled by the system (`tapDisabledByTimeout`), after which it re-enables itself and resets.
/// - Runs on a thread of its own with its own run loop, never the main thread: a busy main actor would delay every key
///   press on the Mac.
///
/// The Mac target's default isolation is the main actor, so this type is `nonisolated` throughout, and the callback is
/// a `nonisolated` C function: a closure inferred as main-actor code would trap ("Incorrect actor executor") when the
/// tap's thread calls it.
nonisolated final class EventTapHotkeys: Sendable {
    /// The tap and the run loop it runs on, while it runs.
    private struct Running: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource
        var runLoop: CFRunLoop?
    }

    private let tracker = Mutex(HotkeyTracker())
    private let running = Mutex<Running?>(nil)
    private let onEvent: @Sendable (BackendEvent) -> Void

    /// `onEvent` is called on the main queue, in order.
    init(onEvent: @escaping @Sendable (BackendEvent) -> Void) {
        self.onEvent = onEvent
    }

    var isRunning: Bool { running.withLock { $0 != nil } }

    /// Creates the tap and starts its thread. False when macOS refuses the tap (no PostEvent grant, or one that has
    /// not reached this process yet). Calling it while running does nothing and returns true.
    func start() -> Bool {
        if isRunning { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        // CF handles are not Sendable; `Running` carries them to the tap's thread (they are only touched there and,
        // after `stop()` takes them, on the caller's).
        let handles = Running(port: port, source: source, runLoop: nil)
        running.withLock { $0 = handles }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            running.withLock { $0?.runLoop = loop }
            CFRunLoopAddSource(loop, handles.source, .commonModes)
            CGEvent.tapEnable(tap: handles.port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Transcribe shortcuts"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    /// Disables and removes the tap and ends its thread. A hold in progress is released.
    func stop() {
        guard let current = running.withLock({ state -> Running? in defer { state = nil }; return state }) else { return }
        CGEvent.tapEnable(tap: current.port, enable: false)
        CFMachPortInvalidate(current.port)
        if let loop = current.runLoop {
            CFRunLoopRemoveSource(loop, current.source, .commonModes)
            CFRunLoopStop(loop)
        }
        reset()
    }

    /// The combos the tap handles, and whether a plain Esc is taken. Empty bindings pass every key.
    func update(bindings: [ComboKey: ShortcutAction], escapeArmed: Bool) {
        tracker.withLock {
            $0.bindings = bindings
            $0.escapeArmed = escapeArmed
        }
    }

    /// Forgets held keys (sleep, lock, a user switch, a re-registration); a hold in progress is released.
    func reset() {
        let events = tracker.withLock { $0.handle(.reset).1 }
        forward(events)
    }

    // MARK: - The callback (the tap's thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let input: HotkeyTracker.Input
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = running.withLock({ $0?.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            reset()
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = ShortcutModifiers(eventFlags: event.flags.rawValue, keyCode: keyCode)
            input = type == .keyDown
                ? .keyDown(keyCode, modifiers, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                : .keyUp(keyCode, modifiers)
        case .flagsChanged:
            input = .flagsChanged(ShortcutModifiers(eventFlags: event.flags.rawValue, keyCode: nil))
        default:
            return Unmanaged.passUnretained(event)
        }
        let (disposition, events) = tracker.withLock { $0.handle(input) }
        forward(events)
        return disposition == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func forward(_ events: [BackendEvent]) {
        guard !events.isEmpty else { return }
        let onEvent = self.onEvent
        DispatchQueue.main.async {
            for event in events { onEvent(event) }
        }
    }
}

/// The tap's C callback: no captures and no actor, so it can be a C function pointer and run on the tap's thread.
/// `refcon` is the `EventTapHotkeys` that created the tap (unretained; it lives for the life of the app).
private nonisolated func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                          refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapHotkeys>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
