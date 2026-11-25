import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit
import TranscribeMCP
import TranscribeMCPHost

/// Settings → Claude (Mac only, §2.1): "Let Claude read transcripts" (off by default), its status, the setup rows for
/// Claude Code and Claude Desktop, any Claude app waiting for permission (with its code, Allow and Don't Allow), and
/// the Allowed apps, each with Remove. Read-only access; what Claude reads goes to Anthropic, and the text under the
/// card says so.
struct ClaudeSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ClaudeAccess.self) private var claude
    /// Shows a toast on the Settings screen's own overlay (text, SF Symbol).
    let showToast: (String, String) -> Void
    @State private var showDesktopHelp = false
    @State private var removing: AllowedClient?
    @State private var claudeInstalled = ClaudeDesktopInstaller.claudeURL != nil

    var body: some View {
        let on = claude.isEnabled
        let problem = HelperLocation.problem
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Claude").padding(.top, 14).padding(.bottom, 6)
            SettingsCard {
                ToggleRow(systemImage: "sparkle", tint: .accent, title: "Let Claude read transcripts",
                          isOn: Binding(get: { claude.isEnabled }, set: { on in Task { await claude.setEnabled(on) } }))
                    .accessibilityIdentifier(AX.Claude.master)
                if on {
                    ValueRow(systemImage: "dot.radiowaves.left.and.right", tint: .neutral, title: "Status",
                             value: Self.statusValue(claude.status), accessory: .none)
                        .accessibilityIdentifier(AX.Claude.status)
                    ForEach(claude.pendingRequests) { request in
                        requestRow(request)
                    }
                    setupRows(setupDisabled: Self.setupDisabled(problem))
                }
            }
            if on {
                allowedApps
            }
            note(explanation, id: AX.Claude.explanation)
            if on {
                note("Each Claude app must be allowed once: the first time it tries to read, Transcribe asks you, with a code to check against the one Claude shows. Allowed apps are listed above; remove one to stop it reading. Nothing secret is stored in Claude's settings, but other apps on this Mac that can read your files could use an allowed app's permission, so turn this off when you stop using it.",
                     id: AX.Claude.allowNote)
                if showDesktopHelp {
                    note("In Claude, open Settings → Developer → Edit Config. Inside the braces after \"mcpServers\", paste the copied text (add a comma if another server is listed there), save, then quit and reopen Claude.",
                         id: AX.Claude.desktopHelp)
                }
                if let text = Self.problemText(claude.status) {
                    note(text, id: AX.Claude.problem, colour: DS.Colour.destructive)
                }
                if let text = Self.locationText(problem) {
                    note(text, id: AX.Claude.moveWarning)
                }
            } else if claude.wasSetUp {
                note("Claude may still list Transcribe, but it can't read anything. To remove it: in Claude Desktop, open Settings → Extensions and uninstall Transcribe; in Claude Code, run claude mcp remove --scope user transcribe",
                     id: AX.Claude.removeHelp)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Claude.section)
        .onAppear { claudeInstalled = ClaudeDesktopInstaller.claudeURL != nil }
        .confirmationDialog(removing.map { "Remove “\($0.name)”?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { app in
            Button("Remove", role: .destructive) {
                claude.remove(app)
                showToast("Removed", "checkmark")
            }
            .accessibilityIdentifier(AX.Claude.removeConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { app in
            Text("\(app.name) won't be able to read your transcripts. If it asks again, Transcribe shows a new request.")
        }
    }

    /// A Claude app waiting for permission: its claimed name, the code, Allow and Don't Allow.
    private func requestRow(_ request: PendingRequest) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "questionmark.app", tint: .accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(request.name)” wants to read transcripts")
                    .font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink)
                Text("Code \(request.code)").font(.callout).monospacedDigit().foregroundStyle(DS.Colour.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.Claude.request(request.id))
            Spacer(minLength: 8)
            Button("Don't Allow") { claude.deny(request) }
                .accessibilityIdentifier(AX.Claude.requestDeny(request.id))
            Button("Allow") {
                if claude.allow(request) {
                    showToast("Allowed. Ask Claude again.", "checkmark")
                } else {
                    showToast("That request has expired. Ask Claude again.", "exclamationmark.triangle")
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AX.Claude.requestAllow(request.id))
        }
        .controlSize(.small)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(minHeight: DS.Size.settingsRow)
    }

    /// The Claude apps the user allowed, each with the date and Remove.
    private var allowedApps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Allowed apps").font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            SettingsCard {
                if claude.allowedApps.isEmpty {
                    ValueRow(systemImage: "checkmark.shield", tint: .neutral, title: "None yet", value: nil, accessory: .none)
                        .accessibilityIdentifier(AX.Claude.noAllowedApps)
                }
                ForEach(claude.allowedApps) { app in
                    HStack(spacing: 12) {
                        IconTile(systemImage: "checkmark.shield", tint: .accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(DS.Typo.rowTitle).tracking(-0.2).foregroundStyle(DS.Colour.ink).lineLimit(1)
                            Text("Allowed \(app.allowedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.callout).foregroundStyle(DS.Colour.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AX.Claude.allowedApp(app.id))
                        Spacer(minLength: 8)
                        Button("Remove…") { removing = app }
                            .controlSize(.small)
                            .accessibilityIdentifier(AX.Claude.removeApp(app.id))
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 14)
                    .padding(.vertical, 6)
                    .frame(minHeight: DS.Size.settingsRow)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Claude.allowedApps)
    }

    /// Add to Claude Code, Add to Claude Desktop… and Copy Claude Desktop Config.
    @ViewBuilder private func setupRows(setupDisabled: Bool) -> some View {
        Button { addToClaudeCode() } label: {
            ValueRow(systemImage: "terminal", tint: .accent, title: "Add to Claude Code", value: "Copy Command", accessory: .none)
        }
        .buttonStyle(.plain)
        .disabled(setupDisabled)
        .accessibilityIdentifier(AX.Claude.addCode)
        Button { addToClaudeDesktop() } label: {
            ValueRow(systemImage: "macwindow", tint: .accent, title: "Add to Claude Desktop…",
                     value: claudeInstalled ? "Install" : "Not installed", accessory: .none)
        }
        .buttonStyle(.plain)
        .disabled(setupDisabled || !claudeInstalled)
        .accessibilityIdentifier(AX.Claude.addDesktop)
        Button { copyDesktopConfig() } label: {
            ValueRow(systemImage: "doc.on.clipboard", tint: .neutral, title: "Copy Claude Desktop Config", value: nil,
                     accessory: .none)
        }
        .buttonStyle(.plain)
        .disabled(setupDisabled)
        .accessibilityIdentifier(AX.Claude.copyDesktopConfig)
    }

    private var explanation: String {
        let base = "Claude Code and Claude Desktop on this Mac can list your recordings and read their transcripts, with times and speaker names. They can't change anything or play audio. What Claude reads is sent to Anthropic, and Claude keeps it in its own chats and logs; deleting a recording here doesn't remove those copies."
        let syncOn = env.sync != nil && env.settings.syncEnabled
        return syncOn ? base + " This includes recordings synced from your other devices." : base
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

    // MARK: Actions

    /// nil while off.
    private var setup: ClientSetup? { claude.setup(helperPath: HelperLocation.path) }

    private func addToClaudeCode() {
        guard let setup else { return }
        Pasteboard.copyPrivate(setup.claudeCodeCommand)
        showToast("Command copied. Paste it into Terminal and press Return.", "checkmark")
    }

    private func addToClaudeDesktop() {
        guard let setup else { return }
        Task {
            do {
                if try await ClaudeDesktopInstaller.install(setup) {
                    showToast("In Claude, click Install. The first time Claude reads, allow it here.", "checkmark")
                }
            } catch {
                showDesktopHelp = true
                showToast("Couldn't open Claude. Use Copy Claude Desktop Config instead.", "exclamationmark.triangle")
            }
        }
    }

    private func copyDesktopConfig() {
        guard let setup else { return }
        Pasteboard.copyPrivate(setup.desktopConfigEntry)
        showDesktopHelp = true
        showToast("Config copied", "checkmark")
    }

    // MARK: Text

    static func statusValue(_ status: ClaudeAccess.Status) -> String {
        switch status {
        case .off: "Off"
        case .starting: "Starting…"
        case .ready: "On"
        case .otherCopy: "Another copy is sharing"
        case .portsInUse: "Ports in use"
        case .failed: "Couldn't start"
        }
    }

    static func problemText(_ status: ClaudeAccess.Status) -> String? {
        switch status {
        case .otherCopy:
            "Another copy of Transcribe on this Mac is already sharing with Claude. Quit it to share from this one."
        case .portsInUse(let ports):
            "Other apps are using the ports Transcribe needs for Claude (\(Self.list(ports))). Quit them, then turn this off and on."
        case .failed(let name):
            "Transcribe couldn't start the connection for Claude (\(name))."
        case .off, .starting, .ready:
            nil
        }
    }

    /// "41873, 44729 and 47461"
    static func list(_ ports: [UInt16]) -> String {
        let names = ports.map(String.init)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Setup rows are off without a helper, and (Release) while the app runs from outside Applications.
    static func setupDisabled(_ problem: HelperProblem?) -> Bool {
        #if DEBUG
        problem == .missing
        #else
        problem != nil
        #endif
    }

    static func locationText(_ problem: HelperProblem?) -> String? {
        if problem == .missing { return "This copy of Transcribe has no Claude helper. Reinstall Transcribe." }
        #if DEBUG
        return "Debug build: Claude can read this copy only while it's open, and the setup stops working if the build moves."
        #else
        return problem == .notInApplications
            ? "Move Transcribe to your Applications folder and open it from there, then add it to Claude." : nil
        #endif
    }
}
