import AppKit
import SwiftUI
import TranscribeDesign
import TranscribeKit

/// Settings → Shortcuts (Mac only): the three global shortcuts, each with its recorder field and, when it cannot work,
/// why (in red); Reset to Defaults; the permissions dictation and the event tap need (Accessibility, Input Monitoring
/// only when macOS asks for it, and the clipboard), each with its button; a note for keyboards without a usable fn
/// key; and what the shortcuts and dictation do with what you type and say.
///
/// Seeing it hides the sidebar's permission note for good (`introSeen`). While it is on screen, permissions are read
/// again every 2 s, so a grant made in System Settings shows here without a relaunch where macOS allows it. "On screen"
/// is scroll visibility, not `onAppear`: Settings is a plain (not lazy) stack in a scroll view, so every section
/// appears when the window opens, and this one sits below the fold.
struct ShortcutsSettingsSection: View {
    @Environment(MacShortcuts.self) private var shortcuts
    @Environment(ShortcutSettings.self) private var settings
    @Environment(ShortcutCenter.self) private var center
    @Environment(ShortcutPermissions.self) private var permissions
    @State private var problem: String?
    @State private var problemExpiry: Task<Void, Never>?
    @State private var isOnScreen = false

    /// The `ScrollViewReader` id the section scrolls to when something asks for it (`revealSettingsSection`).
    private static let anchor = "settings.shortcuts.anchor"
    static let problemLifetime: Duration = .seconds(6)
    /// How much of the section must be in the window to count as seen (it can be taller than the window).
    static let visibleThreshold = 0.25

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(ShortcutCopy.sectionTitle).padding(.top, 14).padding(.bottom, 6)
                    .id(Self.anchor)
                SettingsCard {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        row(action)
                    }
                    Button { resetToDefaults() } label: {
                        ValueRow(systemImage: "arrow.counterclockwise", tint: .neutral, title: ShortcutCopy.resetToDefaults,
                                 value: nil, accessory: .none)
                    }
                    .buttonStyle(.plain)
                    .disabled(settings.bindings == .defaults)
                    .accessibilityIdentifier(AX.Shortcuts.reset)
                }
                if let problem {
                    note(problem, id: AX.Shortcuts.problem, colour: DS.Colour.destructive)
                }
                if showsPermissions {
                    permissionsCard
                }
                note(ShortcutCopy.keyboardNote, id: AX.Shortcuts.keyboardNote)
                note(ShortcutCopy.privacy, id: AX.Shortcuts.privacy)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AX.Shortcuts.section)
            .onAppear { reveal(proxy) }
            .onChange(of: shortcuts.revealSettingsSection) { _, _ in reveal(proxy) }
            .onScrollVisibilityChange(threshold: Self.visibleThreshold) { visible in
                isOnScreen = visible
                if visible, !settings.introSeen { settings.introSeen = true }
            }
            .task(id: isOnScreen) {
                guard isOnScreen else { return }
                await center.refreshWhileVisible()
            }
        }
    }

    // MARK: Rows

    private func row(_ action: ShortcutAction) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: ShortcutCopy.symbol(action), tint: action == .toggleRecording ? .neutral : .accent)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShortcutCopy.title(action))
                        .font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                    Text(ShortcutCopy.subtitle(action))
                        .font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if let status = center.status[action], let message = ShortcutCopy.statusMessage(status) {
                    Text(message)
                        .font(DS.Typo.meta).foregroundStyle(DS.Colour.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AX.Shortcuts.status(action.rawValue))
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorderField(action: action) { show($0) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(minHeight: DS.Size.settingsRow)
    }

    // MARK: Permissions

    /// Only when something here needs one: a dictation shortcut (pasting needs Accessibility), or an fn shortcut that
    /// goes through the event tap.
    private var showsPermissions: Bool {
        let bindings = settings.bindings
        if bindings.dictateHold != nil || bindings.dictateToggle != nil { return true }
        return ShortcutRouting.usesEventTap(bindings)
    }

    private var needsInputMonitoring: Bool { center.status.values.contains(.needsInputMonitoring) }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions").font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            SettingsCard {
                accessibilityRow
                // The guided setup (steps, live status, Relaunch); once allowed, a one-line "Pasting is on".
                PasteSetupGuide()
                if needsInputMonitoring {
                    permissionRow(systemImage: "keyboard", title: ShortcutCopy.inputMonitoringTitle,
                                  allowed: permissions.listenAllowed, id: AX.Shortcuts.inputMonitoring) {
                        permissions.requestListen()
                    }
                }
                if !permissions.clipboardReadable {
                    HStack(spacing: 12) {
                        IconTile(systemImage: "doc.on.clipboard", tint: .neutral)
                        Text(ShortcutCopy.clipboardTitle).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                        Spacer(minLength: 8)
                        Button(ShortcutCopy.keepClipboard) { permissions.askToReadClipboard() }
                            .controlSize(.small)
                            .accessibilityIdentifier(AX.Shortcuts.clipboard)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 14)
                    .frame(minHeight: DS.Size.settingsRow)
                }
            }
            note(ShortcutCopy.accessibilityNote(eventTapInUse: ShortcutRouting.usesEventTap(settings.bindings)),
                 id: AX.Shortcuts.note)
            if !permissions.clipboardReadable {
                note(ShortcutCopy.clipboardNote, id: AX.Shortcuts.clipboardNote)
            }
        }
    }

    /// Accessibility's state only: the guide under it does the asking.
    private var accessibilityRow: some View {
        let allowed = permissions.postEventAllowed
        let value = allowed ? ShortcutCopy.allowed : ShortcutCopy.notAllowed
        return HStack(spacing: 12) {
            IconTile(systemImage: "accessibility", tint: allowed ? .accent : .neutral)
            Text(ShortcutCopy.accessibilityTitle).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
            Spacer(minLength: 8)
            Label(value, systemImage: allowed ? "checkmark" : "xmark")
                .font(.callout).foregroundStyle(DS.Colour.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutCopy.accessibilityTitle)
        .accessibilityValue(value)
        .accessibilityIdentifier(AX.Shortcuts.accessibility)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(minHeight: DS.Size.settingsRow)
    }

    /// "Allowed" once macOS says so, else an Allow… button.
    private func permissionRow(systemImage: String, title: String, allowed: Bool, id: String,
                               request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: allowed ? .accent : .neutral)
            Text(title).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
            Spacer(minLength: 8)
            if allowed {
                Label(ShortcutCopy.allowed, systemImage: "checkmark")
                    .font(.callout).foregroundStyle(DS.Colour.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(ShortcutCopy.allowed)
                    .accessibilityIdentifier(id)
            } else {
                Button(ShortcutCopy.allow, action: request)
                    .controlSize(.small)
                    .accessibilityLabel("Allow \(title)")
                    .accessibilityIdentifier(id)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(minHeight: DS.Size.settingsRow)
    }

    // MARK: Actions

    private func resetToDefaults() {
        settings.resetToDefaults()
        shortcutsLog.info("Shortcuts reset to defaults")
        show(nil)
    }

    /// A refused shortcut's reason, cleared by the next good edit or after 6 s.
    private func show(_ newProblem: ShortcutProblem?) {
        problemExpiry?.cancel()
        problem = newProblem.map(ShortcutCopy.problemMessage)
        guard problem != nil else { return }
        problemExpiry = Task {
            try? await Task.sleep(for: Self.problemLifetime)
            guard !Task.isCancelled else { return }
            problem = nil
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard shortcuts.revealSettingsSection else { return }
        shortcuts.revealSettingsSection = false
        Task {
            // After the window has laid out the screen it just opened.
            await Task.yield()
            withAnimation(.snappy) { proxy.scrollTo(Self.anchor, anchor: .top) }
        }
    }

    private func note(_ text: String, id: String, colour: Color = DS.Colour.secondary) -> some View {
        Text(text)
            .font(DS.Typo.meta)
            .lineSpacing(2)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .accessibilityIdentifier(id)
    }
}
