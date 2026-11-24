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
        #expect(c.processingModels == "Processing starts once the speech models are ready on this iPhone.")
        #expect(c.preparingModels == "Preparing for this iPhone… (after installing or updating, about a minute)")
        #expect(c.needsSample == "Needs a new sample on this iPhone")
        #expect(c.capturingPreview == "Tap to go back to the recording.")
        #expect(c.libraryEmptyHint.hasPrefix("Tap the red button"))
        #expect(c.emptyFolder("Work") == "Nothing in Work yet. Touch and hold a recording to move it here.")
    }

    @Test func macWording() {
        let c = DeviceCopy(platform: .mac)
        #expect(c.processingDefault == "This happens on your Mac. You can keep working.")
        #expect(c.processingModels == "Processing starts once the speech models are ready on this Mac.")
        #expect(c.preparingModels == "Preparing for this Mac… (after installing or updating, about a minute)")
        #expect(c.rememberHelp(who: "Karan") == "Saved on this Mac only. Used to label Karan automatically next time.")
        #expect(c.needsSample == "Needs a new sample on this Mac")
        #expect(c.voicesFooter == "Voice profiles are stored on this Mac only.")
        #expect(c.sidebarFooter == "On-device. Nothing is uploaded.")
        #expect(c.capturingPreview == "Click to go back to the recording.")
        #expect(c.emptyFolder("Work") == "Nothing in Work yet. Control-click a recording to move it here.")
        #expect(c.askFromOtherDevice(name: "Karan", other: .iPhone)
                == "Karan was named on your iPhone. Each microphone hears a voice a little differently, so Transcribe asks once here. Is this Karan?")
        #expect(c.audioElsewhere(other: .iPhone)
                == "Audio is on your iPhone. The transcript and names are synced; audio stays on the device that recorded it.")
    }

    @Test func syncOnWording() {
        let c = DeviceCopy(platform: .mac, syncOn: true)
        #expect(c.rememberHelp(who: "Karan") == "Saved to your voices and synced with iCloud. Used to label Karan automatically next time.")
        #expect(c.voicesFooter == "Voice profiles sync with iCloud. Each device learns how a voice sounds through its own microphone.")
        #expect(c.sidebarFooter == "Transcribed on-device · synced with iCloud")
        #expect(c.processingDefault == DeviceCopy(platform: .mac).processingDefault)
        // Nothing that sync makes untrue survives with the switch on.
        #expect(!c.privacyDetail.contains("never synced"))
        #expect(c.privacyDetail.contains("Audio stays on this Mac"))
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
    }

    @Test func audioElsewhereByChannel() {
        let mac = DeviceCopy(platform: .mac, syncOn: true)
        #expect(mac.audioElsewhere(channel: "iphone") == mac.audioElsewhere(other: .iPhone))
        #expect(mac.audioElsewhere(channel: "mac").hasPrefix("Audio is on your other Mac."))
        #expect(mac.audioElsewhere(channel: nil).hasPrefix("Audio is on the device that recorded it."))
    }
}

@Suite struct SyncCopyTests {
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

    @Test func explanationSaysWhatSyncsAndWhatStays() {
        let e = SyncCopy.explanation
        for part in ["Transcripts", "speaker labels", "folders", "voice profiles", "Audio stays on the device that recorded it",
                     "asked about first"] {
            #expect(e.contains(part), "explanation is missing “\(part)”")
        }
    }

    @Test func footer() {
        let off = DeviceCopy(platform: .mac), on = DeviceCopy(platform: .mac, syncOn: true)
        #expect(SyncCopy.footer(.off, copy: off) == "On-device. Nothing is uploaded.")
        #expect(SyncCopy.footer(.idle(lastSync: nil), copy: on) == "Transcribed on-device · synced with iCloud")
        #expect(SyncCopy.footer(.paused(.noAccount), copy: on) == "Not signed in to iCloud")
        #expect(SyncCopy.footer(.paused(.zoneRemoved), copy: on) == "iCloud sync paused")
    }
}
