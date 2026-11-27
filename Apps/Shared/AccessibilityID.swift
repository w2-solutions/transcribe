// Compiled into the app target AND TranscribeUITests. Never use raw strings elsewhere.
enum AX {
    static func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }

    enum Library {
        static let screen = "library.screen"
        static let searchButton = "library.searchButton"
        static let settingsButton = "library.settingsButton"
        static func filter(_ f: String) -> String { "library.filter.\(f)" }        // all | favourites | folders | unnamed
        static func card(_ i: Int) -> String { "library.card.\(i)" }
        static func cardStatus(_ i: Int) -> String { "library.card.\(i).status" } // "Voices recognised" / progress / failed
        static func cardChip(_ i: Int, _ ordinal: Int) -> String { "library.card.\(i).chip.\(ordinal)" }
        static func cardNameLink(_ i: Int) -> String { "library.card.\(i).nameLink" }
        static func cardFavourite(_ i: Int) -> String { "library.card.\(i).favourite" } // swipe action
        static func cardDelete(_ i: Int) -> String { "library.card.\(i).delete" }       // swipe action
        static let deleteConfirm = "library.deleteConfirm"
        static let importButton = "library.importButton"
        static let recordButton = "library.recordButton"
        static let voicesButton = "library.voicesButton"
        static let recordingPill = "library.recordingPill"
        static let modelsCard = "library.modelsCard"
        static let modelsDownloadButton = "library.modelsCard.downloadButton"
        static let modelsProgress = "library.modelsCard.progress"
        static let modelsRetryButton = "library.modelsCard.retryButton"
        static let cellularConfirm = "library.modelsCard.cellularConfirm"
        static let emptyState = "library.emptyState"
        static let noResults = "library.noResults"
        static let folderMenu = "library.folderMenu"
        enum Folders {
            static let sheet = "folders.sheet"
            static let newFolderButton = "folders.newFolderButton"
            static let nameField = "folders.nameField"
            static func folder(_ i: Int) -> String { "folders.folder.\(i)" }
            static let doneButton = "folders.doneButton"
        }
        enum MicDenied {
            static let sheet = "micDenied.sheet"
            static let openSettings = "micDenied.openSettings"
            static let importInstead = "micDenied.importInstead"
            static let close = "micDenied.close"
            /// Both mode on the Mac: record Mac audio alone instead.
            static let macAudioOnly = "micDenied.macAudioOnly"
        }
    }

    enum Recording {
        static let screen = "recording.screen"
        static let minimiseButton = "recording.minimiseButton"
        static let statusCapsule = "recording.statusCapsule"
        static let elapsed = "recording.elapsed"
        static let title = "recording.title"
        static let date = "recording.date"
        static let liveTranscript = "recording.liveTranscript"
        static let liveTextNote = "recording.liveTextNote"
        static let levelMeter = "recording.levelMeter"            // the one meter (microphone, or Mac audio only)
        // Mac audio (Mac only): what this recording captures, the Both mode's two meters and its notes.
        static let source = "recording.source"                    // "Recording the microphone and Mac audio"
        static let levelMeterMic = "recording.levelMeter.mic"
        static let levelMeterMacAudio = "recording.levelMeter.macAudio"
        static let macAudioNote = "recording.macAudioNote"        // silent / lost
        static let macAudioNoteOpenSettings = "recording.macAudioNote.openSettings"
        static let headphonesHint = "recording.headphonesHint"
        static let pauseButton = "recording.pauseButton"     // label "Pause recording" / "Resume recording"
        static let stopButton = "recording.stopButton"
        static let markButton = "recording.markButton"
        static let markToast = "recording.markToast"
    }

    enum Processing {
        static let panel = "processing.panel"
        static let heading = "processing.heading"
        static func step(_ s: String) -> String { "processing.step.\(s)" }   // transcribing | separating | matching
        static let progressBar = "processing.progressBar"
        static let stepCounter = "processing.stepCounter"
        static let continueInBackground = "processing.continueInBackground"
        static let showTranscriptNow = "processing.showTranscriptNow"
        static let collapsedPill = "processing.collapsedPill"
        /// "Try again" when the recording waits for a setup that failed.
        static let retrySetup = "processing.retrySetup"
    }

    enum Transcript {
        static let screen = "transcript.screen"
        static let searchButton = "transcript.searchButton"
        static let moreButton = "transcript.moreButton"
        static let searchField = "transcript.searchField"
        static let searchCount = "transcript.searchCount"
        static let searchPrevious = "transcript.searchPrevious"
        static let searchNext = "transcript.searchNext"
        static let speakersPendingPill = "transcript.speakersPendingPill"
        static let pendingPlaceholder = "transcript.pendingPlaceholder"
        static let newVoicesBanner = "transcript.newVoicesBanner"
        static let nameSpeakersButton = "transcript.nameSpeakersButton"
        static let recognisedBanner = "transcript.recognisedBanner"
        static let recognisedVoicesLink = "transcript.recognisedBanner.voicesLink"
        static let askBanner = "transcript.askBanner"
        static let askPlay = "transcript.askBanner.play"
        static let askYes = "transcript.askBanner.yes"
        static let askNo = "transcript.askBanner.no"
        static let askDetail = "transcript.askBanner.detail"   // "Speaker 2 sounds like Karan." or the other-device copy
        static let audioElsewhere = "transcript.audioElsewhere" // the audio banner: "Audio is in iCloud …" (no player bar then)
        static let audioBannerAction = "transcript.audioElsewhere.action"     // Download Now / Try Again
        static let audioBannerProgress = "transcript.audioElsewhere.progress" // download progress bar
        static let noSpeechCard = "transcript.noSpeechCard"
        static let failedCard = "transcript.failedCard"
        static let retryButton = "transcript.failedCard.retry"
        static let metaLine = "transcript.metaLine"
        static func turn(_ i: Int) -> String { "transcript.turn.\(i)" }
        static func turnChip(_ i: Int) -> String { "transcript.turn.\(i).chip" }        // label = speaker display name
        static func turnTimestamp(_ i: Int) -> String { "transcript.turn.\(i).timestamp" }
        static func turnText(_ i: Int) -> String { "transcript.turn.\(i).text" }
        static func turnMark(_ i: Int) -> String { "transcript.turn.\(i).mark" }        // bookmark glyph
        /// The Mac audio glyph beside a turn's chip, for a speaker heard through Mac audio (label "Heard through Mac audio").
        static func turnSource(_ i: Int) -> String { "transcript.turn.\(i).source" }
        static func changeSpeaker(_ i: Int) -> String { "transcript.turn.\(i).changeSpeaker" }
        static let copyButton = "transcript.copyButton"
        static let copiedToast = "transcript.copiedToast"
        enum Menu {
            static let rename = "transcript.menu.rename"
            static let favourite = "transcript.menu.favourite"
            static let moveToFolder = "transcript.menu.moveToFolder"
            static let shareText = "transcript.menu.shareText"
            static let shareAudio = "transcript.menu.shareAudio"
            static let delete = "transcript.menu.delete"
            static let renameField = "transcript.renameField"
            static let renameSave = "transcript.renameSave"
            static let deleteConfirm = "transcript.deleteConfirm"
        }
    }

    enum Player {   // hard-coded inside TranscribeDesign.PlayerBar — keep in sync
        static let bar = "player.bar"
        static let playButton = "player.playButton"        // label "Play" / "Pause"
        static let scrubber = "player.scrubber"            // value "0:12 of 0:20"
        static let time = "player.time"
        static let speedButton = "player.speedButton"      // label "1×" …
    }

    enum NameSpeaker {
        static let sheet = "nameSpeaker.sheet"
        static let subtitle = "nameSpeaker.subtitle"       // "Speaker 2 · spoke for 0:13"
        static let askPrompt = "nameSpeaker.askPrompt"     // "Karan was named on your iPhone. … Is this Karan?"
        static let title = "nameSpeaker.title"             // "Who is this?" / "Who said this?"
        static let closeButton = "nameSpeaker.closeButton"
        static func clip(_ i: Int) -> String { "nameSpeaker.clip.\(i)" }
        static let nameField = "nameSpeaker.nameField"
        static let clearName = "nameSpeaker.clearName"
        static func savedVoice(_ slug: String) -> String { "nameSpeaker.savedVoice.\(slug)" }
        static func sameAsSpeaker(_ ordinal: Int) -> String { "nameSpeaker.speaker.\(ordinal)" } // correct mode: other speakers here
        static let newPerson = "nameSpeaker.newPerson"
        static let scopePicker = "nameSpeaker.scopePicker"         // segments "All of X's turns here" / "Just this turn"
        static let rememberToggle = "nameSpeaker.rememberToggle"
        static let rememberHelp = "nameSpeaker.rememberHelp"
        static let saveButton = "nameSpeaker.saveButton"           // "Save and label 2 turns"
        static let notNowButton = "nameSpeaker.notNowButton"
        /// A speaker heard on both the microphone and Mac audio: not learned from this recording.
        static let notLearned = "nameSpeaker.notLearned"
    }

    enum Voices {
        static let screen = "voices.screen"
        static func profile(_ slug: String) -> String { "voices.profile.\(slug)" }
        static func waiting(_ i: Int) -> String { "voices.waiting.\(i)" }
        static func waitingName(_ i: Int) -> String { "voices.waiting.\(i).nameButton" }
        static let privacyCard = "voices.privacyCard"
        static let speakerSettingsLink = "voices.speakerSettingsLink"
        static let emptyState = "voices.emptyState"
        static let intro = "voices.intro"
        static func waitingAsk(_ i: Int) -> String { "voices.waiting.\(i).ask" }   // other-device ask copy
        static let duplicateBanner = "voices.duplicateBanner"
        static let duplicateBannerMerge = "voices.duplicateBanner.merge"
        static let updateBanner = "voices.updateBanner"
        /// Voice samples grouped by capture channel ("On this Mac · 2", "On your iPhone · 3").
        static func sampleGroup(_ channel: String) -> String { "voices.sampleGroup.\(channel)" }
    }

    enum VoiceDetail {
        static let screen = "voiceDetail.screen"
        static let editButton = "voiceDetail.editButton"
        static let name = "voiceDetail.name"
        static let status = "voiceDetail.status"
        static func sample(_ i: Int) -> String { "voiceDetail.sample.\(i)" }
        static func samplePlay(_ i: Int) -> String { "voiceDetail.sample.\(i).play" }
        static let addSample = "voiceDetail.addSample"
        static func appearance(_ i: Int) -> String { "voiceDetail.appearance.\(i)" }
        static let mergeButton = "voiceDetail.mergeButton"
        static let autoLabelToggle = "voiceDetail.autoLabelToggle"
        static let forgetButton = "voiceDetail.forgetButton"
        static let forgetConfirm = "voiceDetail.forgetConfirm"
        static let footnote = "voiceDetail.footnote"
        static let toast = "voiceDetail.toast"                    // WP7 addition: "Sample added" / skip reason
        static let showAllAppearances = "voiceDetail.showAllAppearances"   // WP7 addition
        static func sampleOrigin(_ i: Int) -> String { "voiceDetail.sample.\(i).origin" }      // "Named by you" …
        static func sampleRemove(_ i: Int) -> String { "voiceDetail.sample.\(i).remove" }      // context-menu item
        static let removeSampleConfirm = "voiceDetail.removeSampleConfirm"
        // Voice sample groups (§7). `n` is the group's 0-based position within its channel.
        static let samplesNote = "voiceDetail.samplesNote"                                      // grouping note / default note
        static func group(_ channel: String, _ n: Int) -> String { "voiceDetail.group.\(channel).\(n)" }   // "Close · 3"
        static func groupPlay(_ channel: String, _ n: Int) -> String { group(channel, n) + ".play" }
        static func groupSubtitle(_ channel: String, _ n: Int) -> String { group(channel, n) + ".subtitle" }
        static func groupLabelButton(_ channel: String, _ n: Int) -> String { group(channel, n) + ".label" }   // "Label" / "Edit"
        static func groupMacAudio(_ channel: String, _ n: Int) -> String { group(channel, n) + ".macAudio" }   // "Heard through Mac audio"
        static func ungrouped(_ channel: String) -> String { "voiceDetail.ungrouped.\(channel)" }             // "Not grouped · 2"
        enum GroupLabel { static let field = "voiceDetail.groupLabel.field"; static let save = "voiceDetail.groupLabel.save"; static let remove = "voiceDetail.groupLabel.remove"; static let cancel = "voiceDetail.groupLabel.cancel" }
        enum Edit { static let sheet = "voiceEdit.sheet"; static let nameField = "voiceEdit.nameField"; static let isMeToggle = "voiceEdit.isMeToggle"; static let saveButton = "voiceEdit.saveButton"; static let cancelButton = "voiceEdit.cancelButton" }
        enum Merge { static let sheet = "voiceMerge.sheet"; static func target(_ slug: String) -> String { "voiceMerge.target.\(slug)" }; static let confirm = "voiceMerge.confirm"; static let cancelButton = "voiceMerge.cancelButton" }
        enum AddSample { static let sheet = "voiceAddSample.sheet"; static func candidate(_ i: Int) -> String { "voiceAddSample.candidate.\(i)" }; static let cancelButton = "voiceAddSample.cancelButton"; static let emptyState = "voiceAddSample.emptyState" }
    }

    enum Settings {
        static let screen = "settings.screen"
        static let identifySpeakers = "settings.identifySpeakers"
        static let recogniseVoices = "settings.recogniseVoices"
        static let voicesRow = "settings.voicesRow"
        static let runRow = "settings.runRow"
        static let modelRow = "settings.modelRow"
        static let languageRow = "settings.languageRow"
        static let removeFillers = "settings.removeFillers"
        static let appearanceRow = "settings.appearanceRow"     // Menu picker
        static let autoCopyRow = "settings.autoCopyRow"         // Menu picker
        static let acknowledgementsRow = "settings.acknowledgementsRow"
        static let privacyRow = "settings.privacyRow"
        static let versionRow = "settings.versionRow"
        static let footer = "settings.footer"
        static let copyMatchLogRow = "settings.copyMatchLogRow"
        static let copiedToast = "settings.copiedToast"
        static let privacyDetail = "settings.privacyDetail"
    }

    /// Settings → Recording (Mac only): what New Recording captures.
    enum RecordingSource {
        static let section = "settings.recording.section"
        static let picker = "settings.recording.source"
        static func option(_ raw: String) -> String { "settings.recording.source.\(raw)" }   // microphone | both | macAudio
        static let footnote = "settings.recording.footnote"
    }

    /// The Mac audio explainer, shown once before the first recording of Mac audio.
    enum MacAudioExplainer {
        static let sheet = "macAudioExplainer.sheet"
        static let continueButton = "macAudioExplainer.continue"
        static let cancel = "macAudioExplainer.cancel"
    }

    /// "Sync with iCloud" (§8.6): the Settings section, the leave dialog, and the account and mass-delete sheets.
    enum Sync {
        static let section = "settings.sync.section"
        static let master = "settings.sync.master"
        static let explanation = "settings.sync.explanation"
        static let status = "settings.sync.status"
        static let now = "settings.sync.now"
        static let removeCloud = "settings.sync.removeCloud"
        static let removeCloudConfirm = "settings.sync.removeCloudConfirm"
        static let review = "settings.sync.review"          // reopens the account-change or mass-delete question
        static let audio = "settings.sync.audio"            // the Sync audio switch
        static let audioStatus = "settings.sync.audioStatus" // label = value = the audio status line
        static let audioNow = "settings.sync.audioNow"      // Sync Audio Now
        static let quotaAudio = "settings.sync.quotaAudio"  // "Synced audio uses about …" under the quota pause
        static let downloadAudioFirst = "settings.sync.downloadAudioFirst" // button in the remove and leave dialogs
        static let audioIntro = "library.audioIntro"        // the one-time "Audio now syncs with iCloud" card
        static let audioIntroTurnOff = "library.audioIntro.turnOff"
        static let audioIntroOK = "library.audioIntro.ok"
        enum Leave {
            static let keep = "sync.leave.keep"
            static let remove = "sync.leave.remove"
            static let cancel = "sync.leave.cancel"
        }
        enum Account {
            static let sheet = "sync.account.sheet"
            static let merge = "sync.account.merge"
            static let keepPaused = "sync.account.keepPaused"
        }
        enum MassDelete {
            static let sheet = "sync.massDelete.sheet"
            static let confirm = "sync.massDelete.confirm"
            static let restore = "sync.massDelete.restore"
        }
    }

    /// "Let Claude read transcripts" (Mac only): Settings → Claude.
    enum Claude {
        static let section = "settings.claude.section"
        static let master = "settings.claude.master"
        static let explanation = "settings.claude.explanation"
        static let allowNote = "settings.claude.allowNote"
        static let status = "settings.claude.status"
        static let addCode = "settings.claude.addCode"
        static let addDesktop = "settings.claude.addDesktop"
        static let copyDesktopConfig = "settings.claude.copyDesktopConfig"
        static let copiedToast = "settings.claude.copiedToast"
        static let desktopHelp = "settings.claude.desktopHelp"
        static let problem = "settings.claude.problem"
        static let moveWarning = "settings.claude.moveWarning"
        static let removeHelp = "settings.claude.removeHelp"
        /// The Allowed apps card, and its line when no app is allowed yet.
        static let allowedApps = "settings.claude.allowedApps"
        static let noAllowedApps = "settings.claude.noAllowedApps"
        static let removeConfirm = "settings.claude.removeConfirm"
        /// One allowed app (by client id) and its Remove button.
        static func allowedApp(_ clientID: String) -> String { "settings.claude.allowed.\(clientID)" }
        static func removeApp(_ clientID: String) -> String { "settings.claude.allowed.\(clientID).remove" }
        /// A request waiting in Settings (by client id): the row (its text holds the code), Allow and Don't Allow.
        static func request(_ clientID: String) -> String { "settings.claude.request.\(clientID)" }
        static func requestAllow(_ clientID: String) -> String { "settings.claude.request.\(clientID).allow" }
        static func requestDeny(_ clientID: String) -> String { "settings.claude.request.\(clientID).deny" }
        /// The same request as an alert on the main window.
        static let alertAllow = "claude.pairingAlert.allow"
        static let alertDeny = "claude.pairingAlert.deny"
    }

    /// Software updates (Mac only): Settings → Updates.
    enum Updates {
        static let section = "settings.updates.section"
        static let automatic = "settings.updates.automatic"
        static let checkNow = "settings.updates.checkNow"
        static let note = "settings.updates.note"
    }

    /// Settings → Shortcuts (Mac only). `a` is a `ShortcutAction` raw value.
    enum Shortcuts {
        static let section = "settings.shortcuts.section"
        static func recorder(_ a: String) -> String { "settings.shortcuts.\(a).recorder" }
        static func clear(_ a: String) -> String { "settings.shortcuts.\(a).clear" }
        static func status(_ a: String) -> String { "settings.shortcuts.\(a).status" }
        static let reset = "settings.shortcuts.reset"
        static let problem = "settings.shortcuts.problem"
        static let accessibility = "settings.shortcuts.accessibility"
        static let inputMonitoring = "settings.shortcuts.inputMonitoring"
        static let pasteGuide = "settings.shortcuts.pasteGuide"
        static let pasteOpenSettings = "settings.shortcuts.pasteGuide.openSettings"
        static let pasteShowInFinder = "settings.shortcuts.pasteGuide.showInFinder"
        static let pasteStatus = "settings.shortcuts.pasteGuide.status"
        static let pasteRelaunch = "settings.shortcuts.pasteGuide.relaunch"
        static let pasteDone = "settings.shortcuts.pasteGuide.done"
        static let clipboard = "settings.shortcuts.clipboard"
        static let clipboardNote = "settings.shortcuts.clipboardNote"
        static let note = "settings.shortcuts.note"
        static let keyboardNote = "settings.shortcuts.keyboardNote"
        static let privacy = "settings.shortcuts.privacy"
    }

    /// The dictation HUD (Mac only).
    enum Dictation {
        static let hud = "dictation.hud"
        static let hudTitle = "dictation.hud.title"
        static let hudDetail = "dictation.hud.detail"
        /// DEBUG, simulated shortcuts only: a hidden element whose value is the text the last dictation delivered.
        static let lastDelivered = "dictation.lastDelivered"
    }

    enum ModelSettings {
        static let screen = "modelSettings.screen"
        static let speechRow = "modelSettings.speechRow"
        static let speakersRow = "modelSettings.speakersRow"
        static let status = "modelSettings.status"
        static let downloadButton = "modelSettings.downloadButton"
        static let removeButton = "modelSettings.removeButton"
        static let removeConfirm = "modelSettings.removeConfirm"
        static let cellularConfirm = "modelSettings.cellularConfirm"   // WP7 addition
    }

    /// The setup status (`SetupStatusView`): one prefix per place it shows, so ids stay unique when the Mac's
    /// Settings and main windows are open together.
    enum Setup {
        static let library = "library.setup"
        static let modelSettings = "modelSettings.setup"
        static let processing = "processing.setup"

        static func id(_ prefix: String, _ part: Part) -> String { "\(prefix).\(part.rawValue)" }

        enum Part: String {
            case headline, step, progress, timeLeft, typicalTime, onceNote, keepOpenNote, recordNote, waitingNote,
                 resumedNote, pausedNote
        }
    }

    enum Language {
        static let screen = "language.screen"
        static func option(_ code: String) -> String { "language.option.\(code)" }  // "auto" for automatic
    }

    /// The Mac app's own screens. Recording rows on the Mac reuse `Library.card(i)`.
    enum Mac {
        static let main = "screen.mac.main"
        static let sidebarAll = "mac.sidebar.all"
        static let sidebarFavourites = "mac.sidebar.favourites"
        static let sidebarUnnamed = "mac.sidebar.unnamed"
        static let sidebarVoices = "mac.sidebar.voices"
        static let sidebarVoicesBadge = "mac.sidebar.voicesBadge"
        static let sidebarNewRecording = "mac.sidebar.newRecording"
        static let sidebarFooter = "mac.sidebar.footer"
        /// "Update available · 0.3.1" above the footer while an update waits (D23).
        static let sidebarUpdate = "mac.sidebar.update"
        /// "Shortcuts need permission", below the update reminder.
        static let sidebarShortcuts = "mac.sidebar.shortcuts"
        static let recordingList = "mac.list.recordings"
        static let voiceList = "mac.list.voices"
        static let detailEmpty = "mac.detail.empty"
        static let toolbarRecord = "mac.toolbar.record"
        /// The toolbar's New Recording when Mac audio is available: a menu whose click records with the current source.
        static let toolbarRecordSourceMenu = "mac.toolbar.record.sourceMenu"
        static func toolbarRecordSource(_ raw: String) -> String { "mac.toolbar.record.source.\(raw)" }
        /// The sidebar New Recording pill's second line naming the source.
        static let sidebarNewRecordingSource = "mac.sidebar.newRecording.source"
        static let toolbarImport = "mac.toolbar.import"
        /// The menu bar item (`MacMenuBarLabel`).
        static let menuBarItem = "mac.menuBar.item"
        static let toolbarRecordingPill = "mac.toolbar.recordingPill"
        static let recordingWindow = "mac.recordingWindow"
        static func sidebarFolder(_ i: Int) -> String { "mac.sidebar.folder.\(i)" }
        static func sidebarFolderRename(_ i: Int) -> String { "mac.sidebar.folder.\(i).rename" }
        static func sidebarFolderDelete(_ i: Int) -> String { "mac.sidebar.folder.\(i).delete" }
        static let sidebarFolders = "mac.sidebar.folders"
        static let sidebarNewFolder = "mac.sidebar.newFolder"
        static let folderDeleteConfirm = "mac.sidebar.folderDelete.confirm"
        static let folderDeleteCancel = "mac.sidebar.folderDelete.cancel"
        static let recordingSearch = "mac.list.recordings.search"
        static let recordingSearchClear = "mac.list.recordings.searchClear"
        static let voiceSearch = "mac.list.voices.search"
    }

    enum Attributions {
        static let screen = "attributions.screen"
        static func entry(_ id: String) -> String { "attributions.entry.\(id)" }    // parakeet | community-1 | fluidaudio
        static func link(_ id: String) -> String { "attributions.entry.\(id).link" }                 // WP7 addition
        static func licenceToggle(_ id: String) -> String { "attributions.entry.\(id).licenceToggle" } // WP7 addition
    }
}
