import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

extension AppEnvironment {
    /// Where this recording's audio is (§3.5 "State for views"): audio sync's answer, which reads its `revision` so a
    /// view that asks redraws when a file lands; without audio sync (no transport), here or not.
    func audioState(_ recording: Recording) -> RecordingAudioState {
        sync?.audio?.state(of: recording)
            ?? .withoutAudioSync(hasLocalFile: store.hasLocalAudio(recording), channel: recording.captureChannel)
    }
}

/// A ready transcript whose audio is not on this device (not in iCloud, not downloaded yet, or not syncing here):
/// shown instead of the player bar, at the top of the transcript. It says where the audio is and what happens next
/// ("Audio is in iCloud (14 MB). It downloads on Wi-Fi."), shows a download's progress, and offers Download Now or Try
/// Again when audio sync can act (`DeviceCopy.audioBanner`). The player appears when the file lands.
struct AudioBanner: View {
    let state: RecordingAudioState
    let recordingID: UUID

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let copy = env.copy.audioBanner(state) {
            content(copy)
        }
    }

    private func content(_ copy: AudioBannerCopy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                BannerIcon(systemImage: symbol, tint: DS.Colour.secondary, fill: DS.Colour.neutralFill)
                Text(copy.text)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .lineSpacing(2)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy.text)
            .accessibilityValue(copy.text)
            .accessibilityIdentifier(AX.Transcript.audioElsewhere)
            if case .downloading(let fraction) = state {
                let percent = Int(((fraction ?? 0) * 100).rounded())
                AccentProgressBar(fraction: fraction ?? 0)
                    .padding(.leading, 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(percent)%")
                    .accessibilityIdentifier(AX.Transcript.audioBannerProgress)
            }
            if let action = copy.action {
                InkPillButton(action.title) { env.sync?.audio?.downloadNow(recordingID) }
                    .fixedSize()
                    .padding(.leading, 44)
                    .accessibilityIdentifier(AX.Transcript.audioBannerAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
    }

    /// iCloud while the audio is (or may be) there; the recording device's symbol while it is only there.
    private var symbol: String {
        switch state {
        case .local, .checking, .inICloud, .syncAudioOffHere(inICloud: true, _): "icloud"
        case .downloading: "icloud.and.arrow.down"
        case .failed: "exclamationmark.icloud"
        case .needsUpdate: "arrow.down.app"
        case .notInICloud(let channel), .syncAudioOffHere(inICloud: false, let channel), .syncOffHere(let channel):
            Self.symbol(channel)
        }
    }

    /// The symbol of the device a recording (or a voice sample) was heard on, from its capture channel.
    static func symbol(_ channel: String?) -> String {
        switch DevicePlatform(channel: channel) {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case nil: "waveform.slash"
        }
    }
}

/// "Audio now syncs with iCloud" (decision 24): shown once at the top of the Library to a device that already synced
/// before this version, while it has audio to upload or download. Turn Off turns Sync audio off on this device; OK
/// keeps it on. Content on a plain surface, not glass.
struct AudioIntroCard: View {
    let audio: AudioSync

    var body: some View {
        let summary = audio.summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BannerIcon(systemImage: "waveform", tint: DS.Colour.accentText, fill: DS.Colour.accentFill)
                Text(SyncCopy.audioIntroTitle)
                    .font(.headline)
                    .tracking(-0.2)
                    .foregroundStyle(DS.Colour.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(SyncCopy.audioIntroBody(uploads: summary.uploadsLeft, bytes: summary.uploadBytesLeft, platform: .current))
                .scaledFont(size: 14, relativeTo: .subheadline)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                InkPillButton(SyncCopy.audioIntroTurnOff) { audio.dismissIntro(turnOff: true) }
                    .fixedSize()
                    .accessibilityLabel("Turn off Sync audio")
                    .accessibilityIdentifier(AX.Sync.audioIntroTurnOff)
                InkPillButton(SyncCopy.audioIntroOK) { audio.dismissIntro(turnOff: false) }
                    .fixedSize()
                    .accessibilityIdentifier(AX.Sync.audioIntroOK)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SyncCopy.audioIntroTitle)
        .accessibilityIdentifier(AX.Sync.audioIntro)
    }
}

/// "Karan appears twice. Merge?" (D13): two saved voices share a name after sync. Never merged automatically; Merge
/// opens the existing merge sheet for the newer one.
struct DuplicateVoiceBanner: View {
    let name: String
    let onMerge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BannerIcon(systemImage: "person.2.badge.gearshape", tint: DS.Colour.unnamedText, fill: DS.Colour.neutralFill)
                Text(SyncCopy.duplicateTitle(name))
                    .font(.headline)
                    .tracking(-0.2)
                    .foregroundStyle(DS.Colour.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(SyncCopy.duplicateMessage)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
            InkPillButton("Merge…", action: onMerge)
                .fixedSize()
                .accessibilityLabel("Merge the two voices called \(name)")
                .accessibilityIdentifier(AX.Voices.duplicateBannerMerge)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SyncCopy.duplicateTitle(name))
        .accessibilityIdentifier(AX.Voices.duplicateBanner)
    }

    /// Names shared by more than one saved voice (case-insensitive), with the voice to merge away: the newer one.
    static func duplicates(_ profiles: [VoiceProfile]) -> [(name: String, newer: UUID)] {
        let groups = Dictionary(grouping: profiles) { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        return groups.values.filter { $0.count > 1 }.compactMap { group in
            let sorted = group.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            guard let newer = sorted.last else { return nil }
            return (sorted[0].name, newer.id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// "Update Transcribe on your other devices" (D17): a fetched record came from a build with another voice model or a
/// newer record format.
struct UpdateOtherDevicesBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BannerIcon(systemImage: "arrow.down.app", tint: DS.Colour.accentText, fill: DS.Colour.accentFill)
            Text(SyncCopy.updateOtherDevices)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardSurface(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Voices.updateBanner)
    }
}
