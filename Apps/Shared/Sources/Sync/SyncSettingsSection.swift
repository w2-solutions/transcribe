import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

extension AppEnvironment {
    /// Device wording with the sync switch applied ("Saved to your voices and synced with iCloud", "Delete from all
    /// your devices?"). Shared views read their copy here so it follows the switch.
    var copy: DeviceCopy { DeviceCopy(syncOn: sync != nil && settings.syncEnabled) }
}

/// Settings → iCloud (§8.6): the "Sync with iCloud" switch (off by default), what syncs, the status line, Sync Now and
/// Remove iCloud Copy…. Turning the switch off asks whether to keep the iCloud copy (`LeaveSyncDialog`).
struct SyncSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isLeaving = false
    @State private var isConfirmingRemove = false
    @State private var question: SyncQuestion?
    @State private var errorText: String?

    var body: some View {
        if let sync = env.sync {
            content(sync)
        }
    }

    private func content(_ sync: SyncCoordinator) -> some View {
        let on = env.settings.syncEnabled && sync.status != .paused(.zoneRemoved)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("iCloud").padding(.top, 14).padding(.bottom, 6)
            SettingsCard {
                ToggleRow(systemImage: "icloud", tint: .accent, title: SyncCopy.toggleTitle,
                          isOn: Binding(get: { on }, set: { setOn($0, sync: sync) }))
                    .accessibilityIdentifier(AX.Sync.master)
                if env.settings.syncEnabled {
                    statusRow(sync)
                    if let q = SyncQuestion(sync.status) {
                        Button { question = q } label: {
                            ValueRow(systemImage: "exclamationmark.icloud", tint: .accent, title: q.reviewTitle, value: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AX.Sync.review)
                    }
                    if on {
                        Button { Task { await sync.syncNow() } } label: {
                            ValueRow(systemImage: "arrow.triangle.2.circlepath", tint: .neutral, title: "Sync Now", value: nil,
                                     accessory: .none)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AX.Sync.now)
                        Button { isConfirmingRemove = true } label: {
                            ValueRow(systemImage: "trash", tint: .neutral, title: "Remove iCloud Copy…", value: nil,
                                     accessory: .none, titleColor: DS.Colour.destructive)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AX.Sync.removeCloud)
                        // Anchored to the row so the iOS popover points at it.
                        .confirmationDialog(SyncCopy.removeTitle, isPresented: $isConfirmingRemove, titleVisibility: .visible) {
                            Button(SyncCopy.removeConfirm, role: .destructive) { disable(sync, removeCloudCopy: true) }
                                .accessibilityIdentifier(AX.Sync.removeCloudConfirm)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(SyncCopy.removeMessage)
                        }
                    }
                }
            }
            // The leave dialog hangs off the card, so the iOS popover points at the switch.
            .confirmationDialog(SyncCopy.leaveTitle, isPresented: $isLeaving, titleVisibility: .visible) {
                Button(SyncCopy.leaveKeep) { disable(sync, removeCloudCopy: false) }
                    .accessibilityIdentifier(AX.Sync.Leave.keep)
                Button(SyncCopy.leaveRemove, role: .destructive) { disable(sync, removeCloudCopy: true) }
                    .accessibilityIdentifier(AX.Sync.Leave.remove)
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier(AX.Sync.Leave.cancel)
            } message: {
                Text(SyncCopy.leaveMessage)
            }
            Text(SyncCopy.explanation)
                .font(DS.Typo.meta)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityIdentifier(AX.Sync.explanation)
            if let errorText {
                Text(errorText)
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.destructive)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Sync.section)
        .sheet(item: $question) { q in SyncQuestionSheet(question: q) }
    }

    /// The status line, refreshed every 30 s so "2 min ago" moves on.
    private func statusRow(_ sync: SyncCoordinator) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let line = SyncCopy.statusLine(sync.status, now: env.clock.now, heldDeletes: sync.heldDeleteCount) ?? ""
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: Self.symbol(sync.status))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(sync.status.isPaused ? DS.Colour.unnamedText : DS.Colour.accentText)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text(line)
                    .font(.callout)
                    .foregroundStyle(DS.Colour.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .frame(minHeight: DS.Size.settingsRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .accessibilityValue(line)
            .accessibilityIdentifier(AX.Sync.status)
        }
    }

    static func symbol(_ status: SyncStatus) -> String {
        switch status {
        case .off: "icloud.slash"
        case .idle: "checkmark.icloud"
        case .joining, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .paused: "exclamationmark.icloud"
        }
    }

    // MARK: Switching

    private func setOn(_ on: Bool, sync: SyncCoordinator) {
        errorText = nil
        if on {
            Task { await sync.enable() }
        } else {
            isLeaving = true
        }
    }

    private func disable(_ sync: SyncCoordinator, removeCloudCopy: Bool) {
        Task {
            do {
                try await sync.disable(removeCloudCopy: removeCloudCopy)
            } catch {
                errorText = removeCloudCopy
                    ? "Couldn't remove the iCloud copy. Check your connection and try again."
                    : "Couldn't turn sync off: \(error.localizedDescription)"
            }
        }
    }
}
