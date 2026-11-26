import AppKit
import Observation
import SwiftUI
import TranscribeKit

/// The floating notice the shortcuts show over other apps: a borderless panel that never becomes key or main and
/// never activates Transcribe, so the app the user is typing in keeps its focus and its text cursor (dictation pastes
/// there).
///
/// `.nonactivatingPanel` must be in the style mask at init: set later, WindowServer's "prevents activation" tag is not
/// updated. The panel is left out of screen sharing and screenshots (`sharingType = .none`), because it shows the
/// words being dictated (whether ScreenCaptureKit honours it on macOS 27 is not yet verified).
final class HUDPanel: NSPanel {
    /// What a click on the panel does; nil lets clicks through to the app below.
    var onClick: (() -> Void)? {
        didSet { ignoresMouseEvents = onClick == nil }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        sharingType = .none
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The click is taken here, before any view sees it: the panel is never key, so a SwiftUI button inside it might
    /// need a first click just to take focus. The HUD has no buttons; the whole notice is the control.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let onClick {
            onClick()
            return
        }
        super.sendEvent(event)
    }
}

/// Shows the HUD: the live state of a dictation, or a notice (`HUDMessage`) that hides itself. Created once in
/// `App.init` and driven by the dictation (`followDictation`) and the shortcuts, so it works with every window closed.
/// It only ever orders the panel in front (`orderFrontRegardless`), never makes it key and never activates the app.
@MainActor @Observable
final class HUDPresenter {
    enum Mode: Equatable {
        case hidden
        case dictation
        case message(HUDMessage)
    }

    private(set) var mode: Mode = .hidden

    /// What a click on a notice with an action does (set by the app wiring).
    @ObservationIgnored var onAction: ((HUDMessage.Action) -> Void)?

    @ObservationIgnored private var panel: HUDPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var dictation: DictationController?
    @ObservationIgnored private var content: (() -> AnyView)?
    @ObservationIgnored private var contentSize = CGSize(width: 280, height: 56)
    @ObservationIgnored private var seenOutcome: UUID?
    @ObservationIgnored private var wasBusy = false

    /// The distance from the bottom of the screen's visible area.
    static let bottomInset: CGFloat = 72

    init() {}

    /// The view the panel hosts. Set once by the wiring, before anything is shown.
    func setContent(_ view: @escaping () -> AnyView) {
        content = view
    }

    /// Shows a notice for its `seconds`; a new one replaces the old one. During a dictation the live state comes back
    /// when it hides.
    func show(_ message: HUDMessage) {
        hideTask?.cancel()
        mode = .message(message)
        present(clickable: message.action != nil) { [weak self] in
            guard let self, let action = message.action else { return }
            self.hideNow()
            self.onAction?(action)
        }
        let seconds = message.seconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.messageExpired()
        }
    }

    /// Follows the dictation for the life of the app: its live state while it runs, and its outcome when it ends
    /// (`lastOutcomeID` is new for every finish, so the same outcome twice shows again). Refusals that never leave
    /// idle (busy, models failed) show too.
    func followDictation(_ dictation: DictationController) {
        self.dictation = dictation
        seenOutcome = dictation.lastOutcomeID
        observeDictation()
    }

    private func observeDictation() {
        guard let dictation else { return }
        let (busy, outcomeID) = withObservationTracking {
            (dictation.isBusy, dictation.lastOutcomeID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDictation() }
        }
        if outcomeID != seenOutcome {
            seenOutcome = outcomeID
            if let outcome = dictation.lastOutcome {
                show(DictationHUD.message(for: outcome, bindings: bindings()))
            }
        }
        if busy, !wasBusy {
            // A new dictation replaces whatever notice was showing.
            hideTask?.cancel()
            mode = .dictation
            present(clickable: false, onClick: nil)
        }
        wasBusy = busy
    }

    /// The bindings the notices name (set by the wiring).
    @ObservationIgnored var bindings: () -> ShortcutBindings = { .defaults }

    private func messageExpired() {
        if dictation?.isBusy == true {
            mode = .dictation
            present(clickable: false, onClick: nil)
        } else {
            hideNow()
        }
    }

    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        mode = .hidden
        panel?.onClick = nil
        panel?.orderOut(nil)
    }

    // MARK: - The panel

    private func present(clickable: Bool, onClick: (() -> Void)?) {
        let panel = self.panel ?? makePanel()
        panel.onClick = clickable ? onClick : nil
        place(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel()
        let root = HUDSizeReader(content: content ?? { AnyView(EmptyView()) }) { [weak self] size in
            self?.contentSizeChanged(size)
        }
        let host = NSHostingView(rootView: root)
        // The panel's frame follows the content (`contentSizeChanged`); the hosting view must not size the window.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if let panel, panel.isVisible { place(panel) }
    }

    /// On the screen with the pointer (`NSScreen.main` follows the key window, which is another app's while
    /// Transcribe is in the background), centred, near the bottom of the visible area.
    private func place(_ panel: HUDPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: (visible.midX - contentSize.width / 2).rounded(),
                           y: visible.minY + Self.bottomInset,
                           width: contentSize.width, height: contentSize.height)
        panel.setFrame(frame, display: true)
    }
}

/// Reports the HUD content's own size, so the panel can be exactly as big as the notice (a transparent margin would
/// still catch clicks meant for the app below while a notice is clickable).
private struct HUDSizeReader: View {
    let content: () -> AnyView
    let onSize: (CGSize) -> Void

    var body: some View {
        content()
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
