import Foundation
import Testing
@testable import TranscribeKit

/// The words of audio sync (§1.3): the transcript's audio banner on each platform, sizes, and the iCloud settings'
/// audio lines, notice and dialogs.
@Suite struct AudioCopyTests {
    static let channels: [String?] = ["iphone", "ipad", "mac", nil]
    static let mb14: Int64 = 14_200_000

    /// One of every `RecordingAudioState`, every wait and every channel included.
    static var everyState: [RecordingAudioState] {
        var states: [RecordingAudioState] = [.local, .checking, .downloading(fraction: nil), .downloading(fraction: 0.4),
                                             .failed(bytes: mb14), .needsUpdate]
        for wait in [AudioDownloadWait.queued, .network, .lowPower, .lowStorage, .syncPaused] {
            states.append(.inICloud(bytes: mb14, wait: wait))
        }
        for channel in channels {
            states += [.notInICloud(channel: channel), .syncAudioOffHere(inICloud: true, channel: channel),
                       .syncAudioOffHere(inICloud: false, channel: channel), .syncOffHere(channel: channel)]
        }
        return states
    }

    // MARK: Banner, the same on every platform

    @Test func bannersThatDoNotNameADevice() {
        for platform in DevicePlatform.allCases {
            let c = DeviceCopy(platform: platform, syncOn: true, audioSyncOn: true)
            #expect(c.audioBanner(.local) == nil)
            #expect(c.audioBanner(.checking) == AudioBannerCopy(text: "Checking iCloud for the audio…", action: nil))
            #expect(c.audioBanner(.downloading(fraction: nil)) == AudioBannerCopy(text: "Downloading audio…"))
            #expect(c.audioBanner(.downloading(fraction: 0.4)) == AudioBannerCopy(text: "Downloading audio… 40%"))
            #expect(c.audioBanner(.downloading(fraction: 0))?.text == "Downloading audio… 0%")
            #expect(c.audioBanner(.downloading(fraction: 1))?.text == "Downloading audio… 100%")
            #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .queued))
                    == AudioBannerCopy(text: "Audio is in iCloud (14 MB) and downloads shortly.", action: .downloadNow))
            #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .lowPower))
                    == AudioBannerCopy(text: "Audio is in iCloud (14 MB). It downloads when Low Power Mode is off.",
                                       action: .downloadNow))
            #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .syncPaused))
                    == AudioBannerCopy(text: "Audio is in iCloud (14 MB). It downloads when iCloud sync resumes.", action: nil))
            #expect(c.audioBanner(.failed(bytes: Self.mb14))
                    == AudioBannerCopy(text: "Couldn't download the audio. Check your connection and try again.",
                                       action: .tryAgain))
            for channel in Self.channels {
                #expect(c.audioBanner(.syncAudioOffHere(inICloud: true, channel: channel))
                        == AudioBannerCopy(text: "Audio is in iCloud. Turn on Sync audio in Settings to play it here."))
            }
            #expect(c.audioBanner(.needsUpdate) == AudioBannerCopy(text: "Update Transcribe to play this audio."))
        }
    }

    @Test func bannerSizesFollowTheSizeRule() {
        let c = DeviceCopy(platform: .iPhone, syncOn: true, audioSyncOn: true)
        #expect(c.audioBanner(.inICloud(bytes: 400_000, wait: .queued))?.text == "Audio is in iCloud (under 1 MB) and downloads shortly.")
        #expect(c.audioBanner(.inICloud(bytes: 1_700_000_000, wait: .network))?.text
                == "Audio is in iCloud (1.7 GB). It downloads on Wi-Fi.")
    }

    @Test func actionTitles() {
        #expect(AudioBannerAction.downloadNow.title == "Download Now")
        #expect(AudioBannerAction.tryAgain.title == "Try Again")
    }

    // MARK: Banner, per platform

    @Test func iPhoneBanners() {
        let c = DeviceCopy(platform: .iPhone, syncOn: true, audioSyncOn: true)
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .network))
                == AudioBannerCopy(text: "Audio is in iCloud (14 MB). It downloads on Wi-Fi.", action: .downloadNow))
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .lowStorage))
                == AudioBannerCopy(text: "There isn't enough storage on this iPhone to download the audio (14 MB).",
                                   action: .tryAgain))
        expectChannelBanners(c, [
            "iphone": ("Audio is on your other iPhone and isn't in iCloud yet. It uploads when Transcribe is open there, on Wi-Fi, with Sync audio on.",
                       "Audio is on your other iPhone. Sync audio is off on this iPhone.",
                       "Audio is on your other iPhone. Sync is off on this iPhone."),
            "ipad": ("Audio is on your iPad and isn't in iCloud yet. It uploads when Transcribe is open on your iPad, on Wi-Fi, with Sync audio on.",
                     "Audio is on your iPad. Sync audio is off on this iPhone.",
                     "Audio is on your iPad. Sync is off on this iPhone."),
            "mac": ("Audio is on your Mac and isn't in iCloud yet. It uploads when Transcribe is open on your Mac with Sync audio on.",
                    "Audio is on your Mac. Sync audio is off on this iPhone.",
                    "Audio is on your Mac. Sync is off on this iPhone."),
            "": ("Audio is on the device that recorded it and isn't in iCloud yet.",
                 "Audio is on the device that recorded it. Sync audio is off on this iPhone.",
                 "Audio is on the device that recorded it. Sync is off on this iPhone."),
        ])
    }

    @Test func iPadBanners() {
        let c = DeviceCopy(platform: .iPad, syncOn: true, audioSyncOn: true)
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .network))?.text == "Audio is in iCloud (14 MB). It downloads on Wi-Fi.")
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .lowStorage))?.text
                == "There isn't enough storage on this iPad to download the audio (14 MB).")
        expectChannelBanners(c, [
            "iphone": ("Audio is on your iPhone and isn't in iCloud yet. It uploads when Transcribe is open on your iPhone, on Wi-Fi, with Sync audio on.",
                       "Audio is on your iPhone. Sync audio is off on this iPad.",
                       "Audio is on your iPhone. Sync is off on this iPad."),
            "ipad": ("Audio is on your other iPad and isn't in iCloud yet. It uploads when Transcribe is open there, on Wi-Fi, with Sync audio on.",
                     "Audio is on your other iPad. Sync audio is off on this iPad.",
                     "Audio is on your other iPad. Sync is off on this iPad."),
            "mac": ("Audio is on your Mac and isn't in iCloud yet. It uploads when Transcribe is open on your Mac with Sync audio on.",
                    "Audio is on your Mac. Sync audio is off on this iPad.",
                    "Audio is on your Mac. Sync is off on this iPad."),
            "": ("Audio is on the device that recorded it and isn't in iCloud yet.",
                 "Audio is on the device that recorded it. Sync audio is off on this iPad.",
                 "Audio is on the device that recorded it. Sync is off on this iPad."),
        ])
    }

    @Test func macBanners() {
        let c = DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true)
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .network))
                == AudioBannerCopy(text: "Audio is in iCloud (14 MB). It downloads on Wi-Fi or Ethernet.", action: .downloadNow))
        #expect(c.audioBanner(.inICloud(bytes: Self.mb14, wait: .lowStorage))
                == AudioBannerCopy(text: "There isn't enough storage on this Mac to download the audio (14 MB).", action: .tryAgain))
        expectChannelBanners(c, [
            "iphone": ("Audio is on your iPhone and isn't in iCloud yet. It uploads when Transcribe is open on your iPhone, on Wi-Fi, with Sync audio on.",
                       "Audio is on your iPhone. Sync audio is off on this Mac.",
                       "Audio is on your iPhone. Sync is off on this Mac."),
            "ipad": ("Audio is on your iPad and isn't in iCloud yet. It uploads when Transcribe is open on your iPad, on Wi-Fi, with Sync audio on.",
                     "Audio is on your iPad. Sync audio is off on this Mac.",
                     "Audio is on your iPad. Sync is off on this Mac."),
            "mac": ("Audio is on your other Mac and isn't in iCloud yet. It uploads when Transcribe is open there with Sync audio on.",
                    "Audio is on your other Mac. Sync audio is off on this Mac.",
                    "Audio is on your other Mac. Sync is off on this Mac."),
            "": ("Audio is on the device that recorded it and isn't in iCloud yet.",
                 "Audio is on the device that recorded it. Sync audio is off on this Mac.",
                 "Audio is on the device that recorded it. Sync is off on this Mac."),
        ])
    }

    /// The banner does not depend on the privacy flags, only on the platform and the state.
    @Test func bannersIgnoreTheOtherFlags() {
        for platform in DevicePlatform.allCases {
            let plain = DeviceCopy(platform: platform)
            for state in Self.everyState {
                for c in [DeviceCopy(platform: platform, syncOn: true, claudeOn: true, updatesAvailable: true, audioSyncOn: true),
                          DeviceCopy(platform: platform, cloudCopyKept: true)] {
                    #expect(c.audioBanner(state) == plain.audioBanner(state), "\(platform) \(state)")
                }
            }
        }
    }

    /// Only a state the user can do something about has a button, and only `.local` has no banner.
    @Test func everyStateHasTheRightAction() {
        let c = DeviceCopy(platform: .iPhone, syncOn: true, audioSyncOn: true)
        for state in Self.everyState {
            let banner = c.audioBanner(state)
            switch state {
            case .local: #expect(banner == nil)
            case .inICloud(_, .queued), .inICloud(_, .network), .inICloud(_, .lowPower): #expect(banner?.action == .downloadNow)
            case .inICloud(_, .lowStorage), .failed: #expect(banner?.action == .tryAgain)
            default: #expect(banner != nil && banner?.action == nil, "\(state)")
            }
        }
    }

    /// `rows`: by channel ("" = unknown), the texts for `.notInICloud`, `.syncAudioOffHere(inICloud: false)` and
    /// `.syncOffHere`, none with a button.
    private func expectChannelBanners(_ c: DeviceCopy, _ rows: [String: (String, String, String)],
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rows.count == Self.channels.count, sourceLocation: sourceLocation)
        for channel in Self.channels {
            guard let row = rows[channel ?? ""] else {
                Issue.record("no row for \(channel ?? "nil")", sourceLocation: sourceLocation)
                continue
            }
            #expect(c.audioBanner(.notInICloud(channel: channel)) == AudioBannerCopy(text: row.0),
                    sourceLocation: sourceLocation)
            #expect(c.audioBanner(.syncAudioOffHere(inICloud: false, channel: channel)) == AudioBannerCopy(text: row.1),
                    sourceLocation: sourceLocation)
            #expect(c.audioBanner(.syncOffHere(channel: channel)) == AudioBannerCopy(text: row.2),
                    sourceLocation: sourceLocation)
        }
        // A channel this build does not know reads as unknown.
        #expect(c.audioBanner(.notInICloud(channel: "watch")) == c.audioBanner(.notInICloud(channel: nil)),
                sourceLocation: sourceLocation)
    }

    // MARK: Sizes

    @Test func sizes() {
        let table: [(Int64, String)] = [
            (0, "under 1 MB"), (-5, "under 1 MB"), (1, "under 1 MB"), (999_999, "under 1 MB"),
            (1_000_000, "1 MB"), (1_499_999, "1 MB"), (1_500_000, "2 MB"), (14_200_000, "14 MB"), (14_500_000, "15 MB"),
            (610_000_000, "610 MB"), (999_400_000, "999 MB"),
            (1_000_000_000, "1.0 GB"), (1_700_000_000, "1.7 GB"), (2_149_000_000, "2.1 GB"), (12_345_000_000, "12.3 GB"),
        ]
        for (bytes, text) in table {
            #expect(AudioCopy.size(bytes) == text, "\(bytes)")
        }
    }

    // MARK: Settings: the audio status line

    @Test func statusLineWithNothingWaiting() {
        for platform in DevicePlatform.allCases {
            func line(_ s: AudioSyncSummary) -> String? { SyncCopy.audioStatusLine(s, platform: platform) }
            #expect(line(AudioSyncSummary()) == "Audio up to date")
            #expect(line(AudioSyncSummary(uploadsLeft: 1)) == "Uploading audio · 1 recording left")
            #expect(line(AudioSyncSummary(uploadsLeft: 3)) == "Uploading audio · 3 recordings left")
            #expect(line(AudioSyncSummary(downloadsLeft: 1)) == "Downloading audio · 1 recording left")
            #expect(line(AudioSyncSummary(downloadsLeft: 4)) == "Downloading audio · 4 recordings left")
            #expect(line(AudioSyncSummary(uploadsLeft: 1, downloadsLeft: 2)) == "Syncing audio · 3 recordings left")
            #expect(line(AudioSyncSummary(uploadsLeft: 1, downloadsLeft: 0, uploadBytesLeft: 9_000_000))
                    == "Uploading audio · 1 recording left")
        }
    }

    @Test func statusLineWaits() {
        let iPhone = { (s: AudioSyncSummary) in SyncCopy.audioStatusLine(s, platform: .iPhone) }
        let iPad = { (s: AudioSyncSummary) in SyncCopy.audioStatusLine(s, platform: .iPad) }
        let mac = { (s: AudioSyncSummary) in SyncCopy.audioStatusLine(s, platform: .mac) }
        for line in [iPhone, iPad, mac] {
            #expect(line(AudioSyncSummary(uploadsLeft: 2, wait: .removalFailed))
                    == "Audio uploads paused until the iCloud copy is removed")
            #expect(line(AudioSyncSummary(uploadsLeft: 2, wait: .iCloudFull)) == "Audio uploads paused: iCloud storage is full.")
            #expect(line(AudioSyncSummary(uploadsLeft: 1, downloadsLeft: 1, wait: .lowPower))
                    == "Audio waits while Low Power Mode is on · 2 recordings")
            #expect(line(AudioSyncSummary(downloadsLeft: 1, wait: .lowPower)) == "Audio waits while Low Power Mode is on · 1 recording")
            #expect(line(AudioSyncSummary(uploadsLeft: 1, wait: .busy)) == "Audio uploads wait until recording and processing finish")
        }
        #expect(iPhone(AudioSyncSummary(downloadsLeft: 1, wait: .lowStorage)) == "Audio downloads paused: iPhone storage is low")
        #expect(iPad(AudioSyncSummary(downloadsLeft: 1, wait: .lowStorage)) == "Audio downloads paused: iPad storage is low")
        #expect(mac(AudioSyncSummary(downloadsLeft: 1, wait: .lowStorage)) == "Audio downloads paused: Mac storage is low")
        #expect(iPhone(AudioSyncSummary(uploadsLeft: 1, wait: .network)) == "Audio waits for Wi-Fi · 1 recording")
        #expect(iPad(AudioSyncSummary(uploadsLeft: 2, downloadsLeft: 1, wait: .network)) == "Audio waits for Wi-Fi · 3 recordings")
        #expect(mac(AudioSyncSummary(uploadsLeft: 1, wait: .network)) == "Audio waits for Wi-Fi or Ethernet · 1 recording")
        #expect(mac(AudioSyncSummary(uploadsLeft: 2, downloadsLeft: 3, wait: .network))
                == "Audio waits for Wi-Fi or Ethernet · 5 recordings")
    }

    /// The summary carries one wait, already chosen by precedence; the line names that wait whatever work is left.
    @Test func statusLineWaitWinsOverProgress() {
        let busy = AudioSyncSummary(uploadsLeft: 2, downloadsLeft: 2, wait: .busy)
        #expect(SyncCopy.audioStatusLine(busy, platform: .iPhone) == "Audio uploads wait until recording and processing finish")
        let full = AudioSyncSummary(uploadsLeft: 2, downloadsLeft: 5, wait: .iCloudFull)
        #expect(SyncCopy.audioStatusLine(full, platform: .mac) == "Audio uploads paused: iCloud storage is full.")
        // A full iCloud may also stop transcripts, so the line never promises that they still sync (decision 7).
        for platform in DevicePlatform.allCases {
            for wait in [AudioWait.removalFailed, .iCloudFull, .lowStorage, .network, .lowPower, .busy] {
                let line = SyncCopy.audioStatusLine(AudioSyncSummary(uploadsLeft: 1, downloadsLeft: 1, wait: wait), platform: platform)
                #expect(line?.contains("Transcripts still sync") == false)
                #expect(line != nil)
            }
        }
    }

    @Test func statusLineTooLong() {
        #expect(SyncCopy.audioStatusLine(AudioSyncSummary(tooLong: 1), platform: .iPhone)
                == "Audio up to date\n1 recording is too long to sync its audio")
        #expect(SyncCopy.audioStatusLine(AudioSyncSummary(uploadsLeft: 1, tooLong: 2), platform: .mac)
                == "Uploading audio · 1 recording left\n2 recordings are too long to sync their audio")
        #expect(SyncCopy.audioStatusLine(AudioSyncSummary(uploadsLeft: 1, tooLong: 3, wait: .network), platform: .iPhone)
                == "Audio waits for Wi-Fi · 1 recording\n3 recordings are too long to sync their audio")
    }

    // MARK: Settings: quota line, notice, dialogs

    @Test func quotaAudioLine() {
        #expect(SyncCopy.quotaAudioLine(bytes: 0) == nil)
        #expect(SyncCopy.quotaAudioLine(bytes: 400_000) == "Synced audio uses about under 1 MB of your iCloud storage.")
        #expect(SyncCopy.quotaAudioLine(bytes: 14_200_000) == "Synced audio uses about 14 MB of your iCloud storage.")
        #expect(SyncCopy.quotaAudioLine(bytes: 2_100_000_000) == "Synced audio uses about 2.1 GB of your iCloud storage.")
    }

    @Test func introNotice() {
        #expect(SyncCopy.audioIntroTitle == "Audio now syncs with iCloud")
        #expect(SyncCopy.audioIntroTurnOff == "Turn Off")
        #expect(SyncCopy.audioIntroOK == "OK")
        for platform in [DevicePlatform.iPhone, .iPad] {
            #expect(SyncCopy.audioIntroBody(uploads: 42, bytes: 610_000_000, platform: platform)
                    == "Uploading the audio of 42 recordings (about 610 MB) on Wi-Fi while Transcribe is open. It counts towards your iCloud storage.")
            #expect(SyncCopy.audioIntroBody(uploads: 1, bytes: 14_400_000, platform: platform)
                    == "Uploading the audio of 1 recording (about 14 MB) on Wi-Fi while Transcribe is open. It counts towards your iCloud storage.")
            #expect(SyncCopy.audioIntroBody(uploads: 0, bytes: 0, platform: platform)
                    == "Audio from your other devices downloads on Wi-Fi. It counts towards your iCloud storage.")
        }
        #expect(SyncCopy.audioIntroBody(uploads: 42, bytes: 610_000_000, platform: .mac)
                == "Uploading the audio of 42 recordings (about 610 MB) on Wi-Fi or Ethernet. It counts towards your iCloud storage.")
        #expect(SyncCopy.audioIntroBody(uploads: 1, bytes: 1_700_000_000, platform: .mac)
                == "Uploading the audio of 1 recording (about 1.7 GB) on Wi-Fi or Ethernet. It counts towards your iCloud storage.")
        #expect(SyncCopy.audioIntroBody(uploads: 0, bytes: 0, platform: .mac)
                == "Audio from your other devices downloads on Wi-Fi or Ethernet. It counts towards your iCloud storage.")
    }

    @Test func removeMessage() {
        let start = "Transcripts, audio and voices are deleted from iCloud, and sync turns off on this device."
        let end = " Your other devices keep theirs but stop syncing until sync is turned on there again."
        for platform in DevicePlatform.allCases {
            #expect(SyncCopy.removeMessage(cloudOnly: 0, platform: platform)
                    == start + " This device keeps its library and its audio." + end)
        }
        #expect(SyncCopy.removeMessage(cloudOnly: 1, platform: .iPhone)
                == start + " This device keeps its library. The audio of 1 recording is only in iCloud and isn't on this iPhone: removing the iCloud copy deletes it." + end)
        #expect(SyncCopy.removeMessage(cloudOnly: 3, platform: .iPhone)
                == start + " This device keeps its library. The audio of 3 recordings is only in iCloud and isn't on this iPhone: removing the iCloud copy deletes it." + end)
        #expect(SyncCopy.removeMessage(cloudOnly: 3, platform: .mac)
                == start + " This device keeps its library. The audio of 3 recordings is only in iCloud and isn't on this Mac: removing the iCloud copy deletes it." + end)
        #expect(SyncCopy.removeMessage(cloudOnly: 1, platform: .iPad).contains("isn't on this iPad:"))
        #expect(SyncCopy.removeMessage(cloudOnly: 3, platform: .iPhone, availability: .available)
                == SyncCopy.removeMessage(cloudOnly: 3, platform: .iPhone))
        // Sync audio off here: the count is not known (and nothing would download), so it says audio may be only in
        // iCloud and how to fetch it, whatever the count.
        for cloudOnly in [0, 3] {
            #expect(SyncCopy.removeMessage(cloudOnly: cloudOnly, platform: .iPhone, availability: .syncAudioOff)
                    == start + " This device keeps its library and its audio. Sync audio is off on this iPhone, so audio from your other devices may be only in iCloud: removing the iCloud copy deletes it. Turn on Sync audio to download it first." + end)
        }
        #expect(SyncCopy.removeMessage(cloudOnly: 0, platform: .mac, availability: .syncAudioOff).contains("Sync audio is off on this Mac,"))
        // Sync paused: no Download Audio First, so it says when the audio can download.
        #expect(SyncCopy.removeMessage(cloudOnly: 3, platform: .iPhone, availability: .syncPaused)
                == start + " This device keeps its library. The audio of 3 recordings is only in iCloud and isn't on this iPhone: removing the iCloud copy deletes it. It can download once sync resumes." + end)
        #expect(SyncCopy.removeMessage(cloudOnly: 0, platform: .iPhone, availability: .syncPaused)
                == SyncCopy.removeMessage(cloudOnly: 0, platform: .iPhone))
    }

    @Test func leaveMessage() {
        let end = " Your other devices keep syncing with the iCloud copy unless you remove it."
        for platform in DevicePlatform.allCases {
            #expect(SyncCopy.leaveMessage(cloudOnly: 0, platform: platform) == "This device keeps its library and its audio either way." + end)
            #expect(SyncCopy.leaveMessage(cloudOnly: 1, platform: platform)
                    == "This device keeps its library either way. The audio of 1 recording is only in iCloud: removing the iCloud copy deletes it." + end)
            #expect(SyncCopy.leaveMessage(cloudOnly: 3, platform: platform)
                    == "This device keeps its library either way. The audio of 3 recordings is only in iCloud: removing the iCloud copy deletes it." + end)
            #expect(SyncCopy.leaveMessage(cloudOnly: 3, platform: platform, availability: .syncPaused)
                    == "This device keeps its library either way. The audio of 3 recordings is only in iCloud: removing the iCloud copy deletes it. It can download once sync resumes." + end)
            #expect(SyncCopy.leaveMessage(cloudOnly: 0, platform: platform, availability: .syncPaused)
                    == SyncCopy.leaveMessage(cloudOnly: 0, platform: platform))
            for cloudOnly in [0, 3] {
                #expect(SyncCopy.leaveMessage(cloudOnly: cloudOnly, platform: platform, availability: .syncAudioOff)
                        == "This device keeps its library and its audio either way. Sync audio is off on this \(platform.noun), so audio from your other devices may be only in iCloud: removing the iCloud copy deletes it. Turn on Sync audio to download it first." + end)
            }
        }
    }
}
