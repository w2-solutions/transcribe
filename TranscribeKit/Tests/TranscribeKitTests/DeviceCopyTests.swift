import Foundation
import Testing
@testable import TranscribeKit

@Suite struct DeviceCopyTests {
    @Test func platformFromChannel() {
        #expect(DevicePlatform(channel: "iphone") == .iPhone)
        #expect(DevicePlatform(channel: "ipad") == .iPad)
        #expect(DevicePlatform(channel: "mac") == .mac)
        #expect(DevicePlatform(channel: nil) == nil)
        #expect(DevicePlatform(channel: "watch") == nil)
        #expect(DevicePlatform.mac.noun == "Mac")
    }

    @Test func iPhoneWordingIsUnchanged() {
        let c = DeviceCopy(platform: .iPhone)
        #expect(c.processingDefault == "This happens on your iPhone. You can leave and come back.")
        #expect(c.processingModels
                == "Transcribe is getting ready on this iPhone. This recording is processed as soon as setup finishes.")
        #expect(c.setupHeadline == "Getting ready on this iPhone")
        #expect(c.setupReadyHeadline == "Ready on this iPhone")
        #expect(c.setupOnce == "This happens once after installing or updating.")
        #expect(c.setupRecordNow == "You can record now. Recordings are processed when setup finishes.")
        // No number (only the iPhone 15 is measured, about 20 s), and true with and without Background Inference.
        #expect(c.setupTypicalTime == "This can take a little while.")
        #expect(c.setupKeepOpen == "If you leave Transcribe, setup may pause after a short while. It finishes when you come back.")
        #expect(c.processingModelsFailed
                == "Transcribe couldn't get ready on this iPhone, so this recording is still waiting. Tap Try again to finish setup.")
        #expect(c.processingLeaveButton(waitingForSetup: true) == "Back to Recordings")
        #expect(c.processingLeaveButton(waitingForSetup: false) == "Continue in background")
        #expect(c.setupWaiting(count: 1) == "1 recording will be processed when setup finishes.")
        #expect(c.setupWaiting(count: 3) == "3 recordings will be processed when setup finishes.")
        #expect(c.setupPaused == "Paused while Transcribe is in the background. It carries on when you open it.")
        #expect(c.setupResumed == "Carrying on where it left off.")
        #expect(c.needsSample == "Needs a new sample on this iPhone")
        #expect(c.capturingPreview == "Tap to go back to the recording.")
        #expect(c.libraryEmptyHint.hasPrefix("Tap the red button"))
        #expect(c.emptyFolder("Work") == "Nothing in Work yet. Touch and hold a recording to move it here.")
    }

    @Test func macWording() {
        let c = DeviceCopy(platform: .mac)
        #expect(c.processingDefault == "This happens on your Mac. You can keep working.")
        #expect(c.processingModels
                == "Transcribe is getting ready on this Mac. This recording is processed as soon as setup finishes.")
        #expect(c.setupHeadline == "Getting ready on this Mac")
        #expect(c.setupReadyHeadline == "Ready on this Mac")
        #expect(c.setupKeepOpen == nil, "the Mac never pauses setup")
        #expect(c.setupTypicalTime == "This can take a little while.")
        #expect(c.processingModelsFailed.hasSuffix("Click Try again to finish setup."))
        #expect(c.processingLeaveButton(waitingForSetup: true) == "Continue in background", "the Mac folds the panel")
        #expect(c.rememberHelp(who: "Karan") == "Saved on this Mac only. Used to label Karan automatically next time.")
        #expect(c.needsSample == "Needs a new sample on this Mac")
        #expect(c.voicesFooter == "Voice profiles are stored on this Mac only.")
        #expect(c.sidebarFooter == "On-device. Nothing is uploaded.")
        #expect(c.capturingPreview == "Click to go back to the recording.")
        #expect(c.emptyFolder("Work") == "Nothing in Work yet. Control-click a recording to move it here.")
        #expect(c.askFromOtherDevice(name: "Karan", other: .iPhone)
                == "Karan was named on your iPhone. Each microphone hears a voice a little differently, so Transcribe asks once here. Is this Karan?")
    }

    @Test func syncOnWording() {
        let c = DeviceCopy(platform: .mac, syncOn: true)
        #expect(c.rememberHelp(who: "Karan") == "Saved to your voices and synced with iCloud. Used to label Karan automatically next time.")
        #expect(c.voicesFooter == "Voice profiles sync with iCloud. Each device learns how a voice sounds through its own microphone.")
        #expect(c.sidebarFooter == "Transcribed on-device · synced with iCloud")
        #expect(c.processingDefault == DeviceCopy(platform: .mac).processingDefault)
        // Nothing that sync makes untrue survives with the switch on.
        #expect(!c.privacyDetail.contains("never synced"))
        // Sync audio off (or no audio sync in this run): new audio stays here, audio synced earlier stays in iCloud.
        #expect(c.privacyDetail.contains("any audio synced earlier stays in your private iCloud"))
        #expect(!c.privacyDetail.contains("Audio stays on this"))
        #expect(c.voicesIntro.contains("iCloud") && !c.voicesIntro.contains("only on this device"))
        #expect(c.deleteRecordingTitle == "Delete from all your devices?")
        #expect(c.deleteTranscriptTitle == "Delete from all your devices?")
        #expect(c.deleteTranscriptMessage.contains("all your devices"))
        #expect(c.forgetVoiceMessage("Karan").hasPrefix("Karan is forgotten on all your devices"))
        #expect(c.nothingLeaves == "Processed on this Mac")
    }

    @Test func syncOffWordingIsUnchanged() {
        let c = DeviceCopy(platform: .iPhone)
        #expect(c.deleteTranscriptTitle == "Delete this recording?")
        #expect(c.deleteRecordingTitle == "Delete recording?")
        #expect(c.deleteTranscriptMessage == "The audio and transcript are removed from this iPhone. Saved voices are kept.")
        #expect(c.forgetVoiceMessage("Karan") == "Past transcripts keep the name.")
        #expect(c.voicesIntro == "People Transcribe can recognise. Stored only on this device.")
        #expect(c.privacyValue == "On this iPhone only")
        #expect(c.nothingLeaves == "Nothing leaves this iPhone")
        #expect(c.deleteRecordingMessage == "The audio and transcript are removed from this iPhone.")
        #expect(c.micDeniedBody == "Transcribe needs the microphone to record. Audio stays on this iPhone.")
        #expect(c.privacyDetail
                == "Audio, transcripts and voice profiles are stored only on this iPhone. Voice profiles are never synced or shared.")
    }

    @Test func sampleAudioElsewhereByChannel() {
        let iPhone = DeviceCopy(platform: .iPhone), mac = DeviceCopy(platform: .mac, syncOn: true)
        #expect(iPhone.sampleAudioElsewhere(channel: "ipad") == "Audio is on your iPad")
        #expect(iPhone.sampleAudioElsewhere(channel: "mac") == "Audio is on your Mac")
        #expect(iPhone.sampleAudioElsewhere(channel: "iphone") == "Audio is on your other iPhone")
        #expect(mac.sampleAudioElsewhere(channel: "iphone") == "Audio is on your iPhone")
        #expect(mac.sampleAudioElsewhere(channel: "mac") == "Audio is on your other Mac")
        #expect(mac.sampleAudioElsewhere(channel: nil) == "Audio is on another device")
        #expect(iPhone.sampleAudioElsewhere(channel: "watch") == "Audio is on another device")
    }
}

@Suite struct SyncCopyTests {
    static let voices = "Speech is still processed on each device. A voice learned on another device is asked about first (\"Is this Karan?\") until you confirm it here."

    let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func statusLines() {
        #expect(SyncCopy.statusLine(.off, now: now) == nil)
        #expect(SyncCopy.statusLine(.idle(lastSync: now.addingTimeInterval(-120)), now: now) == "Up to date · 2 min ago")
        #expect(SyncCopy.statusLine(.idle(lastSync: now.addingTimeInterval(-5)), now: now) == "Up to date · just now")
        #expect(SyncCopy.statusLine(.idle(lastSync: nil), now: now) == "Up to date")
        #expect(SyncCopy.statusLine(.syncing(pending: 12), now: now) == "Waiting to upload 12 items")
        #expect(SyncCopy.statusLine(.syncing(pending: 1), now: now) == "Waiting to upload 1 item")
        #expect(SyncCopy.statusLine(.joining("Adding 4 items to iCloud…"), now: now) == "Adding 4 items to iCloud…")
        #expect(SyncCopy.statusLine(.paused(.noAccount), now: now) == "Not signed in to iCloud")
        #expect(SyncCopy.statusLine(.paused(.quotaFull), now: now) == "iCloud storage is full")
        #expect(SyncCopy.statusLine(.paused(.needsUpdate), now: now) == "Paused: update Transcribe")
        #expect(SyncCopy.statusLine(.paused(.restricted), now: now) == "Sync paused")
        #expect(SyncCopy.statusLine(.paused(.massDelete), now: now, heldDeletes: 30) == "Paused: 30 items were deleted here")
        #expect(SyncCopy.statusLine(.paused(.zoneRemoved), now: now)?.hasPrefix("The iCloud copy was removed on another device") == true)
    }

    @Test func explanationWithSyncAudioOn() {
        for (platform, noun) in [(DevicePlatform.iPhone, "iPhone"), (.iPad, "iPad")] {
            #expect(SyncCopy.explanation(audio: true, platform: platform)
                    == "Transcripts, audio, speaker labels, folders and voice profiles sync through your private iCloud. Audio moves on Wi-Fi as a compressed copy, about 15 MB an hour, and counts towards your iCloud storage. This \(noun) downloads the last 30 days of audio by itself, and older audio when you open a recording. " + Self.voices)
        }
        #expect(SyncCopy.explanation(audio: true, platform: .mac)
                == "Transcripts, audio, speaker labels, folders and voice profiles sync through your private iCloud. Audio moves on Wi-Fi or Ethernet as a compressed copy, about 15 MB an hour, and counts towards your iCloud storage. " + Self.voices)
    }

    @Test func explanationWithSyncAudioOff() {
        for platform in DevicePlatform.allCases {
            #expect(SyncCopy.explanation(audio: false, platform: platform)
                    == "Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. With Sync audio off, this \(platform.noun) doesn't upload or download audio, and audio already in iCloud stays there. " + Self.voices)
        }
    }

    @Test func noExplanationSaysAudioNeverMoves() {
        for platform in DevicePlatform.allCases {
            for audio in [false, true] {
                let e = SyncCopy.explanation(audio: audio, platform: platform)
                for phrase in ["Audio stays", "never syncs", "never leaves", "audio from the device that recorded it", "end-to-end"] {
                    #expect(!e.contains(phrase), "\(platform) audio \(audio): “\(e)” says “\(phrase)”")
                }
            }
        }
    }

    @Test func removeFailedSaysSomeAudioMayBeGone() {
        #expect(SyncCopy.removeFailed
                == "Couldn't remove the iCloud copy. Some audio may already have been removed. Check your connection and try again.")
        #expect(SyncCopy.downloadAudioFirst == "Download Audio First")
        #expect(SyncCopy.audioToggleTitle == "Sync audio")
        #expect(SyncCopy.audioNow == "Sync Audio Now")
    }

    @Test func footer() {
        let off = DeviceCopy(platform: .mac), on = DeviceCopy(platform: .mac, syncOn: true)
        #expect(SyncCopy.footer(.off, copy: off) == "On-device. Nothing is uploaded.")
        #expect(SyncCopy.footer(.idle(lastSync: nil), copy: on) == "Transcribed on-device · synced with iCloud")
        #expect(SyncCopy.footer(.paused(.noAccount), copy: on) == "Not signed in to iCloud")
        #expect(SyncCopy.footer(.paused(.zoneRemoved), copy: on) == "iCloud sync paused")
    }
}

extension DeviceCopyTests {
    /// Sync turned off with "Keep the iCloud Copy": transcripts and voices are still in iCloud and on the other devices,
    /// so the privacy wording must not say they are stored only here or never synced.
    @Test func offWithAKeptICloudCopyDoesNotClaimEverythingStaysHere() {
        for platform in [DevicePlatform.iPhone, .mac] {
            let c = DeviceCopy(platform: platform, syncOn: false, cloudCopyKept: true)
            for text in [c.privacyDetail, c.voicesFooter, c.voicesIntro, c.sidebarFooter] {
                #expect(!text.contains("only"), "\(platform): \(text)")
                #expect(!text.contains("never"), "\(platform): \(text)")
                #expect(!text.contains("Nothing is uploaded"), "\(platform): \(text)")
                #expect(text.contains("iCloud"), "\(platform): \(text)")
            }
            #expect(c.privacyDetail
                    == "Sync is off. Transcripts, speaker labels, folders, voice profiles and any audio synced earlier remain in your private iCloud and on your other devices until you remove them.")
            #expect(c.privacyValue == "This \(platform.noun) and your iCloud")
            #expect(c.micDeniedBody == "Transcribe needs the microphone to record. Speech is processed on this \(platform.noun).")
        }
        // Never synced (or the copy removed): the plain wording stays.
        #expect(DeviceCopy(platform: .mac, syncOn: false, cloudCopyKept: false).sidebarFooter == "On-device. Nothing is uploaded.")
        // Sync on: the kept flag changes nothing.
        #expect(DeviceCopy(platform: .mac, syncOn: true, cloudCopyKept: true) == DeviceCopy(platform: .mac, syncOn: true))
    }
}

/// "Let Claude read transcripts" (Mac, D20, §2.2): with the switch on, no privacy line may say that nothing is shared.
@Suite struct DeviceCopyClaudeTests {
    static let claudeLine = " Claude on this Mac can read your transcripts and speaker names, and what it reads is sent to Anthropic."

    @Test func claudeOnSidebarFooterAllRows() {
        let rows: [(sync: Bool, kept: Bool, claude: Bool, text: String)] = [
            (true, false, true, "On-device · synced with iCloud · Claude can read"),
            (true, false, false, "Transcribed on-device · synced with iCloud"),
            (false, true, true, "Not syncing · a copy remains in iCloud · Claude can read"),
            (false, true, false, "Not syncing. A copy remains in your iCloud."),
            (false, false, true, "On-device. Claude can read transcripts."),
            (false, false, false, "On-device. Nothing is uploaded."),
        ]
        for row in rows {
            let c = DeviceCopy(platform: .mac, syncOn: row.sync, cloudCopyKept: row.kept, claudeOn: row.claude)
            #expect(c.sidebarFooter == row.text, "sync \(row.sync) kept \(row.kept) claude \(row.claude)")
        }
        // The kept flag means nothing while sync is on, with or without Claude.
        #expect(DeviceCopy(platform: .mac, syncOn: true, cloudCopyKept: true, claudeOn: true).sidebarFooter
                == "On-device · synced with iCloud · Claude can read")
    }

    @Test func claudeOnPrivacyValue() {
        #expect(DeviceCopy(platform: .mac, claudeOn: true).privacyValue == "Audio on this Mac only")
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true).privacyValue == "Audio on this Mac only")
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true, audioSyncOn: true).privacyValue
                == "This Mac and your iCloud")
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true, claudeOn: true).privacyValue == "This Mac and your iCloud")
        #expect(DeviceCopy(platform: .mac).privacyValue == "On this Mac only")
    }

    @Test func claudeOnPrivacyDetailEachBranch() {
        let base = DeviceCopyAudioTests.audioOffBase("Mac")
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true).privacyDetail
                == base + Self.claudeLine + " Transcribe shares nothing else.")
        #expect(DeviceCopy(platform: .mac, syncOn: true).privacyDetail == base + " Nothing is shared with anyone else.")
        let audio = DeviceCopyAudioTests.audioOnBase
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true, audioSyncOn: true).privacyDetail
                == audio + Self.claudeLine + " Transcribe shares nothing else.")
        #expect(DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true).privacyDetail
                == audio + " Nothing is shared with anyone else.")
        let kept = DeviceCopy(platform: .mac, cloudCopyKept: true)
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true, claudeOn: true).privacyDetail == kept.privacyDetail + Self.claudeLine)
        #expect(DeviceCopy(platform: .mac, claudeOn: true).privacyDetail
                == "Audio, transcripts and voice profiles are stored only on this Mac." + Self.claudeLine
                    + " Audio and voice samples are never shared.")
    }

    @Test func claudeOnNothingLeaves() {
        #expect(DeviceCopy(platform: .mac, claudeOn: true).nothingLeaves == "Processed on this Mac")
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true).nothingLeaves == "Processed on this Mac")
        #expect(DeviceCopy(platform: .mac).nothingLeaves == "Nothing leaves this Mac")
    }

    /// With the switch off, every string is what it was before Claude access; the strings Claude does not touch stay
    /// the same with it on.
    @Test func claudeOffUnchanged() {
        let mac = DeviceCopy(platform: .mac)
        #expect(mac.sidebarFooter == "On-device. Nothing is uploaded.")
        #expect(mac.privacyValue == "On this Mac only")
        #expect(mac.privacyDetail == "Audio, transcripts and voice profiles are stored only on this Mac. Voice profiles are never synced or shared.")
        #expect(mac.nothingLeaves == "Nothing leaves this Mac")
        #expect(DeviceCopy(platform: .mac, syncOn: true).privacyDetail.hasSuffix(" Nothing is shared with anyone else."))
        #expect(DeviceCopy(platform: .mac, claudeOn: false) == mac)
        for platform in DevicePlatform.allCases {
            for (sync, kept) in [(false, false), (true, false), (false, true)] {
                let off = DeviceCopy(platform: platform, syncOn: sync, cloudCopyKept: kept)
                let on = DeviceCopy(platform: platform, syncOn: sync, cloudCopyKept: kept, claudeOn: true)
                #expect(on.voicesFooter == off.voicesFooter && on.voicesIntro == off.voicesIntro)
                #expect(on.modelsIntro == off.modelsIntro && on.modelsReady == off.modelsReady)
                #expect(on.micDeniedBody == off.micDeniedBody)
            }
        }
    }

    @Test func iPhoneSyncOnMentionsClaudeOnMacAndNotNothingShared() {
        let c = DeviceCopy(platform: .iPhone, syncOn: true)
        #expect(c.privacyDetail.hasSuffix(" If you let Claude read transcripts on your Mac, synced transcripts can be read there too."))
        #expect(!c.privacyDetail.lowercased().contains("nothing is shared"))
    }

    @Test func noClaudeOnStringClaimsNothingShared() {
        let forbidden = ["nothing is shared", "Nothing is shared", "Nothing is uploaded", "Nothing leaves", "never synced or shared"]
        for platform in DevicePlatform.allCases {
            for (sync, kept) in [(false, false), (true, false), (false, true), (true, true)] {
                let c = DeviceCopy(platform: platform, syncOn: sync, cloudCopyKept: kept, claudeOn: true)
                for text in [c.sidebarFooter, c.privacyValue, c.privacyDetail, c.nothingLeaves] {
                    for phrase in forbidden {
                        #expect(!text.contains(phrase), "\(platform) sync \(sync) kept \(kept): “\(text)” says “\(phrase)”")
                    }
                }
            }
        }
    }
}

/// In-app updates (Mac, §2 "Privacy wording"): with the updater on, every privacy explanation says the app contacts
/// w2solutions.ai, before the branch's closing absolute; the iPhone and builds without the updater are unchanged.
@Suite struct DeviceCopyUpdatesTests {
    static let updateLine = " Transcribe contacts w2solutions.ai only to check for updates and download them, and sends no recordings, transcripts or names."
    static let states: [(sync: Bool, kept: Bool, claude: Bool)] = [
        (false, false, false), (false, false, true), (true, false, false), (true, false, true), (false, true, false), (false, true, true),
    ]

    @Test func everyMacPrivacyBranchCarriesTheUpdateLineBeforeItsClosingAbsolute() throws {
        let absolutes = ["nothing else", "Nothing is shared", "never shared", "never synced or shared"]
        for s in Self.states {
            for audio in [false, true] {
                let c = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude,
                                   updatesAvailable: true, audioSyncOn: audio)
                let detail = c.privacyDetail
                let range = try #require(detail.range(of: Self.updateLine),
                                         "sync \(s.sync) kept \(s.kept) claude \(s.claude) audio \(audio): \(detail)")
                let after = String(detail[range.upperBound...])
                let before = String(detail[..<range.lowerBound])
                for phrase in absolutes {
                    #expect(!before.contains(phrase), "“\(phrase)” comes before the update line: \(detail)")
                }
                // The same text without the updater, with the update line taken out.
                let off = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude, audioSyncOn: audio)
                #expect(before + after == off.privacyDetail, "sync \(s.sync) kept \(s.kept) claude \(s.claude) audio \(audio)")
            }
        }
    }

    @Test func exactMacPrivacyWithUpdates() {
        #expect(DeviceCopy(platform: .mac, updatesAvailable: true).privacyDetail
                == "Audio, transcripts and voice profiles are stored only on this Mac." + Self.updateLine
                    + " Voice profiles are never synced or shared.")
        let base = DeviceCopyAudioTests.audioOffBase("Mac")
        #expect(DeviceCopy(platform: .mac, syncOn: true, updatesAvailable: true, audioSyncOn: true).privacyDetail
                == DeviceCopyAudioTests.audioOnBase + Self.updateLine + " Nothing is shared with anyone else.")
        #expect(DeviceCopy(platform: .mac, syncOn: true, updatesAvailable: true).privacyDetail
                == base + Self.updateLine + " Nothing is shared with anyone else.")
        #expect(DeviceCopy(platform: .mac, syncOn: true, claudeOn: true, updatesAvailable: true).privacyDetail
                == base + DeviceCopyClaudeTests.claudeLine + Self.updateLine + " Transcribe shares nothing else.")
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true, updatesAvailable: true).privacyDetail
                == DeviceCopy(platform: .mac, cloudCopyKept: true).privacyDetail + Self.updateLine)
        #expect(DeviceCopy(platform: .mac, claudeOn: true, updatesAvailable: true).privacyDetail
                == "Audio, transcripts and voice profiles are stored only on this Mac." + DeviceCopyClaudeTests.claudeLine
                    + Self.updateLine + " Audio and voice samples are never shared.")
    }

    @Test func iPhoneIgnoresUpdates() {
        for platform in [DevicePlatform.iPhone, .iPad] {
            for s in Self.states {
                let off = DeviceCopy(platform: platform, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude)
                let on = DeviceCopy(platform: platform, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude, updatesAvailable: true)
                #expect(on.privacyDetail == off.privacyDetail)
                #expect(on.modelsIntro == off.modelsIntro)
                #expect(!on.privacyDetail.contains("w2solutions.ai"))
            }
        }
    }

    @Test func modelsIntroSaysUpdatesBringTheModelsOnTheMacOnly() {
        let plain = "These come with Transcribe. Speech and speakers are processed on this Mac, even offline. Nothing is downloaded."
        #expect(DeviceCopy(platform: .mac).modelsIntro == plain)
        #expect(DeviceCopy(platform: .iPhone).modelsIntro
                == "These come with Transcribe. Speech and speakers are processed on this iPhone, even offline. Nothing is downloaded.")
        let mac = DeviceCopy(platform: .mac, updatesAvailable: true).modelsIntro
        #expect(mac == "These come with Transcribe. Speech and speakers are processed on this Mac, even offline. They are never downloaded on their own; they change only with an app update.")
        #expect(mac.contains("never downloaded on their own"))
        #expect(!mac.contains("Nothing is downloaded"))
    }

    /// An update check uploads no user data, so the short absolutes stay; every other string is the same with the
    /// updater on.
    @Test func otherStringsAreUnchanged() {
        for s in Self.states {
            let off = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude)
            let on = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude, updatesAvailable: true)
            #expect(on.sidebarFooter == off.sidebarFooter)
            #expect(on.nothingLeaves == off.nothingLeaves)
            #expect(on.privacyValue == off.privacyValue)
            #expect(on.voicesFooter == off.voicesFooter && on.voicesIntro == off.voicesIntro)
            #expect(on.modelsReady == off.modelsReady && on.micDeniedBody == off.micDeniedBody)
        }
        #expect(DeviceCopy(platform: .mac, updatesAvailable: true).sidebarFooter == "On-device. Nothing is uploaded.")
        #expect(DeviceCopy(platform: .mac) == DeviceCopy(platform: .mac, updatesAvailable: false))
    }

    /// The Claude rule still holds with the updater on: no string claims that nothing is shared.
    @Test func claudeForbiddenPhrasesWithUpdates() {
        let forbidden = ["nothing is shared", "Nothing is shared", "Nothing is uploaded", "Nothing leaves", "never synced or shared"]
        for (sync, kept) in [(false, false), (true, false), (false, true)] {
            let c = DeviceCopy(platform: .mac, syncOn: sync, cloudCopyKept: kept, claudeOn: true, updatesAvailable: true)
            for text in [c.sidebarFooter, c.privacyValue, c.privacyDetail, c.nothingLeaves] {
                for phrase in forbidden {
                    #expect(!text.contains(phrase), "sync \(sync) kept \(kept): “\(text)” says “\(phrase)”")
                }
            }
        }
    }
}

/// Audio sync (§1.4): the strings that change once audio moves through iCloud, and a sweep that no string still says
/// audio stays where it was recorded.
@Suite struct DeviceCopyAudioTests {
    static let audioOnBase = "Audio, transcripts, speaker labels, folders and voice profiles sync through your private iCloud. Speech is processed on each device."
    static func audioOffBase(_ noun: String) -> String {
        "Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. With Sync audio off, new audio stays on this \(noun); any audio synced earlier stays in your private iCloud until you remove it. Speech is processed on each device."
    }
    static let iPhoneClaude = " If you let Claude read transcripts on your Mac, synced transcripts can be read there too."

    /// Every string `DeviceCopy` can show, with sample arguments, including every audio banner.
    static func allStrings(_ c: DeviceCopy) -> [String] {
        var texts = [
            c.processingDefault, c.processingModels, c.processingModelsFailed,
            c.processingLeaveButton(waitingForSetup: true), c.processingLeaveButton(waitingForSetup: false),
            c.setupHeadline, c.setupReadyHeadline, c.setupOnce, c.setupRecordNow, c.setupTypicalTime, c.setupKeepOpen ?? "",
            c.setupWaiting(count: 1), c.setupWaiting(count: 3), c.setupPaused, c.setupResumed,
            c.rememberHelp(who: "Karan"), c.needsSample, c.capturingPreview, c.voicesFooter, c.sidebarFooter,
            c.askFromOtherDevice(name: "Karan", other: .iPhone), c.attributionsIntro, c.privacyValue, c.privacyDetail,
            c.voicesIntro, c.modelsIntro, c.modelsReady, c.lowStorageStop, c.nothingLeaves, c.micDeniedBody,
            c.deleteTranscriptTitle, c.deleteTranscriptMessage, c.deleteRecordingTitle, c.deleteRecordingMessage,
            c.forgetVoiceMessage("Karan"), c.libraryEmptyHint, c.emptyFolder("Work"), c.notInAnyRecording,
        ]
        for channel in AudioCopyTests.channels {
            texts.append(c.sampleAudioElsewhere(channel: channel))
        }
        texts += AudioCopyTests.everyState.compactMap { c.audioBanner($0)?.text }
        return texts
    }

    static var everyCopy: [DeviceCopy] {
        var copies: [DeviceCopy] = []
        for platform in DevicePlatform.allCases {
            for sync in [false, true] {
                for kept in [false, true] {
                    for claude in [false, true] {
                        for updates in [false, true] {
                            for audio in [false, true] {
                                copies.append(DeviceCopy(platform: platform, syncOn: sync, cloudCopyKept: kept, claudeOn: claude,
                                                         updatesAvailable: updates, audioSyncOn: audio))
                            }
                        }
                    }
                }
            }
        }
        return copies
    }

    @Test func audioSyncOnNeedsSyncOn() {
        #expect(!DeviceCopy(platform: .iPhone, syncOn: false, audioSyncOn: true).audioSyncOn)
        #expect(!DeviceCopy(platform: .mac, syncOn: false, cloudCopyKept: true, audioSyncOn: true).audioSyncOn)
        #expect(DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true).audioSyncOn)
        #expect(!DeviceCopy(platform: .mac, syncOn: true).audioSyncOn)
        #expect(DeviceCopy(platform: .mac, syncOn: false, audioSyncOn: true) == DeviceCopy(platform: .mac))
        for c in Self.everyCopy where !c.syncOn {
            #expect(!c.audioSyncOn)
        }
    }

    @Test func privacyValue() {
        for (platform, noun) in [(DevicePlatform.iPhone, "iPhone"), (.iPad, "iPad"), (.mac, "Mac")] {
            #expect(DeviceCopy(platform: platform, syncOn: true, audioSyncOn: true).privacyValue == "This \(noun) and your iCloud")
            #expect(DeviceCopy(platform: platform, cloudCopyKept: true).privacyValue == "This \(noun) and your iCloud")
            #expect(DeviceCopy(platform: platform, syncOn: true).privacyValue == "Audio on this \(noun) only")
            #expect(DeviceCopy(platform: platform, claudeOn: true).privacyValue == "Audio on this \(noun) only")
            #expect(DeviceCopy(platform: platform).privacyValue == "On this \(noun) only")
        }
    }

    @Test func privacyDetailWithSyncOn() {
        #expect(DeviceCopy(platform: .iPhone, syncOn: true, audioSyncOn: true).privacyDetail == Self.audioOnBase + Self.iPhoneClaude)
        #expect(DeviceCopy(platform: .iPhone, syncOn: true).privacyDetail == Self.audioOffBase("iPhone") + Self.iPhoneClaude)
        #expect(DeviceCopy(platform: .iPad, syncOn: true).privacyDetail == Self.audioOffBase("iPad") + Self.iPhoneClaude)
        #expect(DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true).privacyDetail
                == Self.audioOnBase + " Nothing is shared with anyone else.")
        #expect(DeviceCopy(platform: .mac, syncOn: true).privacyDetail
                == Self.audioOffBase("Mac") + " Nothing is shared with anyone else.")
    }

    @Test func privacyDetailWithAKeptCopy() {
        let kept = "Sync is off. Transcripts, speaker labels, folders, voice profiles and any audio synced earlier remain in your private iCloud and on your other devices until you remove them."
        #expect(DeviceCopy(platform: .iPhone, cloudCopyKept: true).privacyDetail == kept)
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true).privacyDetail == kept)
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true, claudeOn: true, updatesAvailable: true).privacyDetail
                == kept + DeviceCopyClaudeTests.claudeLine + DeviceCopyUpdatesTests.updateLine)
    }

    @Test func micDeniedBody() {
        #expect(DeviceCopy(platform: .iPhone, syncOn: true, audioSyncOn: true).micDeniedBody
                == "Transcribe needs the microphone to record. Speech is processed on this iPhone.")
        #expect(DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true).micDeniedBody
                == "Transcribe needs the microphone to record. Speech is processed on this Mac.")
        #expect(DeviceCopy(platform: .iPhone, syncOn: true).micDeniedBody
                == "Transcribe needs the microphone to record. Audio stays on this iPhone.")
        #expect(DeviceCopy(platform: .mac).micDeniedBody == "Transcribe needs the microphone to record. Audio stays on this Mac.")
    }

    @Test func deleteMessages() {
        for audio in [false, true] {
            for platform in DevicePlatform.allCases {
                let c = DeviceCopy(platform: platform, syncOn: true, audioSyncOn: audio)
                #expect(c.deleteTranscriptMessage
                        == "The transcript and its audio are removed from all your devices and from iCloud. Saved voices are kept.")
                #expect(c.deleteRecordingMessage == "The transcript and its audio are removed from all your devices and from iCloud.")
            }
        }
        let mac = DeviceCopy(platform: .mac)
        #expect(mac.deleteTranscriptMessage == "The audio and transcript are removed from this Mac. Saved voices are kept.")
        #expect(mac.deleteRecordingMessage == "The audio and transcript are removed from this Mac.")
    }

    /// The unchanged strings stay unchanged with audio sync on.
    @Test func otherStringsIgnoreAudioSync() {
        for platform in DevicePlatform.allCases {
            let off = DeviceCopy(platform: platform, syncOn: true, claudeOn: true)
            let on = DeviceCopy(platform: platform, syncOn: true, claudeOn: true, audioSyncOn: true)
            #expect(on.sidebarFooter == off.sidebarFooter && on.nothingLeaves == off.nothingLeaves)
            #expect(on.voicesFooter == off.voicesFooter && on.voicesIntro == off.voicesIntro)
            #expect(on.modelsIntro == off.modelsIntro && on.modelsReady == off.modelsReady)
            #expect(on.deleteTranscriptMessage == off.deleteTranscriptMessage)
            for channel in AudioCopyTests.channels {
                #expect(on.sampleAudioElsewhere(channel: channel) == off.sampleAudioElsewhere(channel: channel))
            }
        }
    }

    @Test func forbiddenPhrasesSweep() {
        let withAudio = ["Audio stays", "never syncs", "never leaves", "Audio on this", "audio from the device that recorded it"]
        for c in Self.everyCopy {
            let tag = "\(c.platform) sync \(c.syncOn) kept \(c.cloudCopyKept) claude \(c.claudeOn) updates \(c.updatesAvailable) audio \(c.audioSyncOn)"
            let texts = Self.allStrings(c)
            if c.audioSyncOn {
                for text in texts {
                    for phrase in withAudio {
                        #expect(!text.contains(phrase), "\(tag): “\(text)” says “\(phrase)”")
                    }
                }
            }
            if c.cloudCopyKept {
                for text in texts {
                    #expect(!text.contains("Audio stays on this"), "\(tag): “\(text)”")
                }
            }
            if c.syncOn && !c.audioSyncOn {
                #expect(c.privacyDetail.contains("any audio synced earlier stays in your private iCloud"), "\(tag)")
                #expect(!c.privacyDetail.contains("Audio stays on this"), "\(tag)")
            }
            // Nobody may read a promise of end-to-end encryption into the audio copy (decision 17).
            for text in texts {
                #expect(!text.contains("end-to-end"), "\(tag): “\(text)”")
            }
        }
    }
}
