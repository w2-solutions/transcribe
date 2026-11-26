import AppKit
import Carbon
import Observation
import TranscribeKit

/// Owns the global shortcuts: which backend registers each binding, each binding's status for Settings, the one Esc
/// source, and turning backend events into commands (`ShortcutDispatch`). It calls no system event API itself; that is
/// `CarbonHotkeys` and `EventTapHotkeys`.
///
/// Rules it keeps:
/// - A run that is not live registers nothing: UI-test and fake-engine runs are off, and a simulated run takes its
///   events from the DEBUG Shortcut Simulation menu (`simulate`).
/// - While another copy of Transcribe runs (a Debug build beside `/Applications/Transcribe.app`), nothing is
///   registered, so one key press never does two things. Checked again when the app becomes active, when any app quits,
///   and while Settings → Shortcuts is open.
/// - Commands are refused until the app has launched (`isLaunched`): before that a press shows "Transcribe is
///   starting…" (`onNotReady`), so no dictation runs before launch clears leftover dictation files.
/// - Esc has exactly one source: the event tap's tracker when the tap runs, otherwise a Carbon hot key registered only
///   while a dictation can be cancelled (`setEscapeArmed`). Two sources could report one press twice, which would
///   break the two-press Esc of a long dictation.
/// - A Carbon hold cannot see its modifiers let go before its key (Carbon reports the key's release only), so while one
///   is held the modifier state is polled every 50 ms (`NSEvent.modifierFlags`, no permission) and the hold ends when
///   a required modifier is released.
/// - While the shortcut recorder listens (`suspend`), nothing is registered and the tap passes every key.
@MainActor @Observable
final class ShortcutCenter {
    /// Each binding's state, for Settings → Shortcuts.
    private(set) var status: [ShortcutAction: ShortcutStatus] = [:]

    let availability: ShortcutAvailability

    @ObservationIgnored private let settings: ShortcutSettings
    @ObservationIgnored private let permissions: ShortcutPermissions
    @ObservationIgnored private let isLaunched: @MainActor () -> Bool
    @ObservationIgnored private let otherCopyRunning: @MainActor () -> Bool
    @ObservationIgnored private let onCommand: @MainActor (ShortcutCommand) -> Void
    @ObservationIgnored private let onNotReady: @MainActor () -> Void

    @ObservationIgnored private var dispatch = ShortcutDispatch()
    @ObservationIgnored private var carbon: CarbonHotkeys?
    @ObservationIgnored private var tap: EventTapHotkeys?
    /// What each Carbon id is registered with now, so a re-apply only touches what changed.
    @ObservationIgnored private var carbonCombos: [ShortcutAction: KeyCombo] = [:]
    @ObservationIgnored private var tapBindings: [ComboKey: ShortcutAction] = [:]
    @ObservationIgnored private var tapRunning = false
    @ObservationIgnored private var escapeArmed = false
    @ObservationIgnored private var carbonEscape = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var sawOtherCopy = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var holdPoll: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let holdPollInterval: Duration = .milliseconds(50)
    static let settingsPollInterval: Duration = .seconds(2)

    init(settings: ShortcutSettings, permissions: ShortcutPermissions, availability: ShortcutAvailability,
         isLaunched: @escaping @MainActor () -> Bool, otherCopyRunning: @escaping @MainActor () -> Bool,
         onCommand: @escaping @MainActor (ShortcutCommand) -> Void, onNotReady: @escaping @MainActor () -> Void) {
        self.settings = settings; self.permissions = permissions; self.availability = availability
        self.isLaunched = isLaunched; self.otherCopyRunning = otherCopyRunning
        self.onCommand = onCommand; self.onNotReady = onNotReady
    }

    /// Registers the bindings, and again whenever they or a permission change. Called once, from `App.init`'s task.
    func start() {
        guard !started else { return }
        started = true
        shortcutsLog.info("Shortcuts: \(String(describing: self.availability), privacy: .public)")
        if availability == .live {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPermissions() }
                })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPermissions() }
                })
        }
        observeAndApply()
    }

    private func observeAndApply() {
        withObservationTracking {
            _ = settings.bindings
            _ = permissions.postEventAllowed
            _ = permissions.listenAllowed
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndApply() }
        }
        apply()
    }

    // MARK: - Registration

    private func apply() {
        let bindings = settings.bindings
        switch availability {
        case .offTestRun:
            setStatus(ShortcutAction.allCases.map { ($0, .offInTestRuns) })
            return
        case .simulated:
            setStatus(ShortcutAction.allCases.map { ($0, bindings[$0] == nil ? .off : .simulated) })
            return
        case .live:
            break
        }
        sawOtherCopy = otherCopyRunning()
        if sawOtherCopy || suspended {
            unregisterEverything()
            if sawOtherCopy {
                setStatus(ShortcutAction.allCases.map { ($0, bindings[$0] == nil ? .off : .otherCopyRunning) })
            }
            return
        }

        var next: [(ShortcutAction, ShortcutStatus)] = []
        var wantCarbon: [ShortcutAction: KeyCombo] = [:]
        var wantTap: [ComboKey: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let combo = bindings[action] else {
                next.append((action, .off))
                continue
            }
            switch ShortcutRouting.backend(for: combo) {
            case .carbon: wantCarbon[action] = combo
            case .eventTap: wantTap[combo.key] = action
            }
        }

        // Every old combo goes before any new one registers: macOS refuses a combo this process still holds under
        // another id, so a combo moving between actions (Reset to Defaults after a swap) would otherwise fail.
        let plan = CarbonPlan.make(registered: carbonCombos, wanted: wantCarbon)
        for action in plan.unregister { unregisterCarbon(action) }
        for action in ShortcutAction.allCases {
            guard let combo = wantCarbon[action] else { continue }
            next.append((action, plan.register.contains(action) ? registerCarbon(combo, for: action) : .active))
        }

        let tapStatus = applyTap(wantTap)
        for action in wantTap.values { next.append((action, tapStatus)) }
        setStatus(next)
        applyEscape()
    }

    /// Registers `combo` for `action`, whose id holds nothing now (`CarbonPlan` unregistered it).
    private func registerCarbon(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutStatus {
        let status = carbonBackend().register(combo, id: CarbonHotkeys.ID.of(action))
        guard status == noErr else {
            shortcutsLog.error("\(action.rawValue, privacy: .public) via Carbon: not registered (\(status, privacy: .public))")
            return .takenByAnotherApp
        }
        carbonCombos[action] = combo
        shortcutsLog.info("\(action.rawValue, privacy: .public) via Carbon: active")
        return .active
    }

    private func unregisterCarbon(_ action: ShortcutAction) {
        guard carbonCombos.removeValue(forKey: action) != nil else { return }
        carbon?.unregister(id: CarbonHotkeys.ID.of(action))
        // A hold or press in progress on the old combo ends now: its release will never come.
        release(action)
    }

    /// Starts, updates or stops the tap for `wanted`; the status the tap's bindings get.
    private func applyTap(_ wanted: [ComboKey: ShortcutAction]) -> ShortcutStatus {
        tapBindings = wanted
        guard !wanted.isEmpty else {
            stopTap()
            return .active
        }
        guard permissions.postEventAllowed else {
            stopTap()
            shortcutsLog.info("Event tap: needs Accessibility")
            return .needsAccessibility
        }
        let tap = tapBackend()
        if !tapRunning {
            guard tap.start() else {
                // PostEvent is granted, yet macOS refused the tap: either Input Monitoring is missing too, or the
                // grant has not reached this process.
                let status: ShortcutStatus = permissions.listenAllowed ? .needsRelaunch : .needsInputMonitoring
                shortcutsLog.error("Event tap: not created (\(String(describing: status), privacy: .public))")
                return status
            }
            tapRunning = true
            shortcutsLog.info("Event tap: running")
        }
        tap.update(bindings: wanted, escapeArmed: escapeArmed)
        return .active
    }

    private func stopTap() {
        guard tapRunning, let tap else { return }
        tap.stop()
        tapRunning = false
        shortcutsLog.info("Event tap: stopped")
    }

    private func unregisterEverything() {
        for action in ShortcutAction.allCases { unregisterCarbon(action) }
        if carbonEscape { carbon?.unregister(id: CarbonHotkeys.ID.escape); carbonEscape = false }
        tapBindings = [:]
        if tapRunning { tap?.update(bindings: [:], escapeArmed: false) }
        stopTap()
        endHoldPoll()
        for command in dispatch.reset() { deliver(command) }
    }

    private func setStatus(_ pairs: [(ShortcutAction, ShortcutStatus)]) {
        let next = Dictionary(pairs, uniquingKeysWith: { _, new in new })
        if next != status { status = next }
    }

    private func carbonBackend() -> CarbonHotkeys {
        if let carbon { return carbon }
        let made = CarbonHotkeys { [weak self] id, pressed in self?.carbonEvent(id: id, pressed: pressed) }
        carbon = made
        return made
    }

    private func tapBackend() -> EventTapHotkeys {
        if let tap { return tap }
        let made = EventTapHotkeys { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event, viaCarbon: false) }
        }
        tap = made
        return made
    }

    // MARK: - Esc

    /// Follows `DictationController.acceptsEscape`.
    func setEscapeArmed(_ on: Bool) {
        guard escapeArmed != on else { return }
        escapeArmed = on
        applyEscape()
    }

    private func applyEscape() {
        guard availability == .live else { return }
        let source = EscapeSource.resolve(armed: escapeArmed, suspended: suspended, otherCopyRunning: sawOtherCopy,
                                          tapRunning: tapRunning)
        if tapRunning { tap?.update(bindings: tapBindings, escapeArmed: source == .tap) }
        let wantCarbon = source == .carbon
        if wantCarbon, !carbonEscape {
            let status = carbonBackend().registerEscape()
            carbonEscape = status == noErr
            if status != noErr {
                shortcutsLog.error("Esc via Carbon: not registered (\(status, privacy: .public)); dictation cannot be cancelled by key")
            }
        } else if !wantCarbon, carbonEscape {
            carbon?.unregister(id: CarbonHotkeys.ID.escape)
            carbonEscape = false
        }
    }

    // MARK: - Suspending (the shortcut recorder)

    /// While the recorder field listens: nothing registered, the tap passes every key, a hold in progress ends.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        if availability == .live { unregisterEverything() } else { for command in dispatch.reset() { deliver(command) } }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        apply()
    }

    // MARK: - Permissions and the other copy

    /// Reads the permissions again, and re-registers if another copy of Transcribe started or quit.
    func refreshPermissions() {
        guard availability == .live else { return }
        permissions.refresh()
        if otherCopyRunning() != sawOtherCopy { apply() }
    }

    /// Settings → Shortcuts runs this in its `.task`: a refresh every 2 s while the section shows, so a grant made in
    /// System Settings shows up without a relaunch where macOS allows it.
    func refreshWhileVisible() async {
        while !Task.isCancelled {
            refreshPermissions()
            try? await Task.sleep(for: Self.settingsPollInterval)
        }
    }

    /// The Mac is going to sleep, the screen locked, or the user switched away: keys held now will never report their
    /// release, so the tap and the dispatch forget them (a hold in progress ends).
    func systemWillSleep() {
        tap?.reset()
        endHoldPoll()
        for command in dispatch.reset() { deliver(command) }
    }

    // MARK: - Events

    private func carbonEvent(id: UInt32, pressed: Bool) {
        if id == CarbonHotkeys.ID.escape {
            if pressed { receive(.escape, viaCarbon: true) }
            return
        }
        guard let action = CarbonHotkeys.ID.action(id) else { return }
        receive(pressed ? .pressed(action) : .released(action), viaCarbon: true)
    }

    private func receive(_ event: BackendEvent, viaCarbon: Bool) {
        guard let command = dispatch.receive(event) else { return }
        if command == .holdBegan, viaCarbon { beginHoldPoll() }
        if command == .holdEnded { endHoldPoll() }
        deliver(command)
    }

    private func release(_ action: ShortcutAction) {
        if let command = dispatch.receive(.released(action)) {
            if command == .holdEnded { endHoldPoll() }
            deliver(command)
        }
    }

    private func deliver(_ command: ShortcutCommand) {
        guard isLaunched() else {
            switch command {
            case .toggleMeeting, .holdBegan, .toggleDictation: onNotReady()
            case .holdEnded, .cancelDictation: break
            }
            return
        }
        shortcutsLog.info("Command: \(String(describing: command), privacy: .public)")
        onCommand(command)
    }

    /// A Carbon hold ends when one of its modifiers is let go, even though the key is still down (`HoldModifierWatch`
    /// has the rule).
    private func beginHoldPoll() {
        endHoldPoll()
        guard let required = carbonCombos[.dictateHold]?.modifiers else { return }
        holdPoll = Task { [weak self] in
            var watch = HoldModifierWatch(required: required)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.holdPollInterval)
                guard !Task.isCancelled, let self else { return }
                let now = ShortcutModifiers(eventFlags: UInt64(NSEvent.modifierFlags.rawValue), keyCode: nil)
                if watch.observe(now) {
                    self.holdPoll = nil
                    self.release(.dictateHold)
                    return
                }
            }
        }
    }

    private func endHoldPoll() {
        holdPoll?.cancel()
        holdPoll = nil
    }

    #if DEBUG
    /// The Shortcut Simulation menu (a simulated run only): the same path as a real key press, launch gate included.
    func simulate(_ event: BackendEvent) {
        guard availability == .simulated else { return }
        receive(event, viaCarbon: false)
    }
    #endif
}
