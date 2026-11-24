import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// A synced transcript whose audio is on the device that recorded it (§8.5): shown instead of the player bar.
struct AudioElsewhereBanner: View {
    let channel: String?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let text = env.copy.audioElsewhere(channel: channel)
        HStack(alignment: .top, spacing: 12) {
            BannerIcon(systemImage: Self.symbol(channel), tint: DS.Colour.secondary, fill: DS.Colour.neutralFill)
            Text(text)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .lineSpacing(2)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .cardSurface(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(text)
        .accessibilityIdentifier(AX.Transcript.audioElsewhere)
    }

    static func symbol(_ channel: String?) -> String {
        switch DevicePlatform(channel: channel) {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case nil: "waveform.slash"
        }
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
