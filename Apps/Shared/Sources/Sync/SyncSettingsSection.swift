import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

extension AppEnvironment {
    /// Device wording with the sync and Sync audio switches (and, on the Mac, the Claude switch, the updater and Mac
    /// audio) applied ("Saved to your voices and synced with iCloud", "Delete from all your devices?", "This iPhone and
    /// your iCloud"). Shared views read their copy here so it follows them.
    var copy: DeviceCopy {
        DeviceCopy(syncOn: sync != nil && settings.syncEnabled, cloudCopyKept: sync?.keepsCloudCopy ?? false, claudeOn: claudeAccessOn,
                   updatesAvailable: updatesAvailable, audioSyncOn: sync != nil && settings.syncEnabled && settings.syncAudio,
                   macAudio: engine.systemAudioAvailable)
    }

    /// This engine can record Mac audio (the Mac with a capture that supports it; never the iPhone). While false no
    /// source control shows and every recording captures the microphone.
    var macAudioAvailable: Bool { engine.systemAudioAvailable }

    /// What New Recording captures now: the chosen source, or the microphone where Mac audio is not available.
    var recordingSource: CaptureSources { settings.effectiveRecordingSource(systemAudioAvailable: macAudioAvailable) }
}

/// Settings → iCloud (§8.6): the "Sync with iCloud" switch (off by default), the "Sync audio" switch under it (on by
/// default, acting only while sync is on), what syncs, the status lines, Sync Now, Sync Audio Now and Remove iCloud
/// Copy…. Turning the switch off asks whether to keep the iCloud copy (`LeaveSyncDialog`); that dialog and Remove iCloud
/// Copy… first say how many recordings' audio is only in iCloud, and offer Download Audio First.
struct SyncSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isLeaving = false
    @State private var isConfirmingRemove = false
    @State private var didCopyLog = false
    @State private var question: SyncQuestion?
    @State private var errorText: String?

    var body: some View {
        if let sync = env.sync {
            content(sync)
        }
    }

    private func content(_ sync: SyncCoordinator) -> some View {
        let on = env.settings.syncEnabled && sync.status != .paused(.zoneRemoved)
        // Signed in to another account, or signed out: the iCloud copy is out of reach, and the zone of whoever is
        // signed in now is never this library's to remove.
        let canRemove = on && sync.status != .paused(.accountChanged) && sync.status != .paused(.noAccount)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("iCloud").padding(.top, 14).padding(.bottom, 6)
            SettingsCard {
                ToggleRow(systemImage: "icloud", tint: .accent, title: SyncCopy.toggleTitle,
                          isOn: Binding(get: { on }, set: { setOn($0, sync: sync) }))
                    .accessibilityIdentifier(AX.Sync.master)
                // Always shown, so the user sees audio will sync before turning sync on; it acts only while sync is on.
                ToggleRow(systemImage: "waveform", tint: .accent, title: SyncCopy.audioToggleTitle,
                          isOn: Binding(get: { env.settings.syncAudio }, set: { setAudio($0, sync: sync) }), isEnabled: on)
                    .accessibilityIdentifier(AX.Sync.audio)
                if env.settings.syncEnabled {
                    statusRow(sync)
                    if sync.status == .paused(.quotaFull), let audio = sync.audio,
                       let line = SyncCopy.quotaAudioLine(bytes: audio.bytesInICloud) {
                        detailLine(line, id: AX.Sync.quotaAudio)
                    }
                    if on, env.settings.syncAudio, let audio = sync.audio {
                        audioRows(audio)
                    }
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
                    }
                    Button {
                        Pasteboard.copy(SyncLogExport.text())
                        didCopyLog = true
                    } label: {
                        ValueRow(systemImage: "doc.on.clipboard", tint: .neutral, title: "Copy sync log",
                                 value: didCopyLog ? "Copied" : nil, accessory: .none)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sync.copyLog")
                    if canRemove {
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
                            downloadAudioFirstButton(sync)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(SyncCopy.removeMessage(cloudOnly: cloudOnlyCount(sync), platform: .current,
                                                        availability: downloadAvailability(sync)))
                        }
                    }
                }
            }
            // The leave dialog hangs off the card, so the iOS popover points at the switch.
            .confirmationDialog(SyncCopy.leaveTitle, isPresented: $isLeaving, titleVisibility: .visible) {
                Button(SyncCopy.leaveKeep) { disable(sync, removeCloudCopy: false) }
                    .accessibilityIdentifier(AX.Sync.Leave.keep)
                if canRemove {
                    Button(SyncCopy.leaveRemove, role: .destructive) { disable(sync, removeCloudCopy: true) }
                        .accessibilityIdentifier(AX.Sync.Leave.remove)
                }
                downloadAudioFirstButton(sync)
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier(AX.Sync.Leave.cancel)
            } message: {
                Text(SyncCopy.leaveMessage(cloudOnly: cloudOnlyCount(sync), platform: .current,
                                           availability: downloadAvailability(sync)))
            }
            Text(SyncCopy.explanation(audio: env.settings.syncAudio, platform: .current))
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
            let line = SyncCopy.statusLine(sync.status, now: env.clock.now, heldDeletes: sync.heldDeleteCount,
                                           problem: sync.lastError) ?? ""
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

    /// Audio sync's line ("Uploading audio · 2 recordings left", "Audio waits for Wi-Fi · 1 recording", "Audio up to
    /// date"), and Sync Audio Now while the audio waits for the network or Low Power Mode.
    @ViewBuilder
    private func audioRows(_ audio: AudioSync) -> some View {
        let summary = audio.summary
        if let line = SyncCopy.audioStatusLine(summary, platform: .current) {
            detailLine(line, id: AX.Sync.audioStatus)
        }
        if summary.wait == .network || summary.wait == .lowPower {
            Button { audio.syncAudioNow() } label: {
                ValueRow(systemImage: "icloud.and.arrow.up", tint: .neutral, title: SyncCopy.audioNow, value: nil,
                         accessory: .none)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AX.Sync.audioNow)
        }
    }

    /// A secondary line under the status row, read as one element (label = value = text).
    private func detailLine(_ text: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colour.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(text)
        .accessibilityIdentifier(id)
    }

    /// Ready recordings here whose audio is only in iCloud: what removing the iCloud copy would lose.
    private func cloudOnlyCount(_ sync: SyncCoordinator) -> Int { sync.audio?.cloudOnlyCount ?? 0 }

    /// Whether Download Audio First would download now (Sync audio on here, sync running and not paused).
    private func downloadAvailability(_ sync: SyncCoordinator) -> AudioDownloadAvailability {
        sync.audio?.downloadAvailability ?? .available
    }

    /// Download Audio First (remove and leave dialogs): fetches every cloud-only recording's audio on any network; the
    /// dialog closes and sync stays on, so the user removes the copy afterwards. Offered only while it can download;
    /// otherwise the message says why (Sync audio off, sync paused).
    @ViewBuilder
    private func downloadAudioFirstButton(_ sync: SyncCoordinator) -> some View {
        if let audio = sync.audio, audio.cloudOnlyCount > 0, audio.downloadAvailability == .available {
            Button(SyncCopy.downloadAudioFirst) { audio.downloadCloudOnlyAudio() }
                .accessibilityIdentifier(AX.Sync.downloadAudioFirst)
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

    /// Sync audio flipped: off cancels a transfer in flight (nothing is deleted anywhere); on resumes the backlog.
    private func setAudio(_ on: Bool, sync: SyncCoordinator) {
        env.settings.syncAudio = on
        sync.audio?.settingChanged()
    }

    private func disable(_ sync: SyncCoordinator, removeCloudCopy: Bool) {
        Task {
            do {
                try await sync.disable(removeCloudCopy: removeCloudCopy)
            } catch {
                errorText = removeCloudCopy
                    ? SyncCopy.removeFailed
                    : "Couldn't turn sync off: \(error.localizedDescription)"
            }
        }
    }
}
