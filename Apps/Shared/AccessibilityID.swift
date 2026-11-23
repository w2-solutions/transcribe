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
        static let levelMeter = "recording.levelMeter"
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
        static let noSpeechCard = "transcript.noSpeechCard"
        static let failedCard = "transcript.failedCard"
        static let retryButton = "transcript.failedCard.retry"
        static let metaLine = "transcript.metaLine"
        static func turn(_ i: Int) -> String { "transcript.turn.\(i)" }
        static func turnChip(_ i: Int) -> String { "transcript.turn.\(i).chip" }        // label = speaker display name
        static func turnTimestamp(_ i: Int) -> String { "transcript.turn.\(i).timestamp" }
        static func turnText(_ i: Int) -> String { "transcript.turn.\(i).text" }
        static func turnMark(_ i: Int) -> String { "transcript.turn.\(i).mark" }        // bookmark glyph
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
    }

    enum Voices {
        static let screen = "voices.screen"
        static func profile(_ slug: String) -> String { "voices.profile.\(slug)" }
        static func waiting(_ i: Int) -> String { "voices.waiting.\(i)" }
        static func waitingName(_ i: Int) -> String { "voices.waiting.\(i).nameButton" }
        static let privacyCard = "voices.privacyCard"
        static let speakerSettingsLink = "voices.speakerSettingsLink"
        static let emptyState = "voices.emptyState"
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
    }

    enum ModelSettings {
        static let screen = "modelSettings.screen"
        static let speechRow = "modelSettings.speechRow"
        static let speakersRow = "modelSettings.speakersRow"
        static let status = "modelSettings.status"
        static let progress = "modelSettings.progress"
        static let downloadButton = "modelSettings.downloadButton"
        static let removeButton = "modelSettings.removeButton"
        static let removeConfirm = "modelSettings.removeConfirm"
        static let cellularConfirm = "modelSettings.cellularConfirm"   // WP7 addition
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
        static let recordingList = "mac.list.recordings"
        static let voiceList = "mac.list.voices"
        static let detailEmpty = "mac.detail.empty"
        static let toolbarRecord = "mac.toolbar.record"
        static let toolbarImport = "mac.toolbar.import"
        static let toolbarRecordingPill = "mac.toolbar.recordingPill"
        static let recordingWindow = "mac.recordingWindow"
        static func sidebarFolder(_ i: Int) -> String { "mac.sidebar.folder.\(i)" }
    }

    enum Attributions {
        static let screen = "attributions.screen"
        static func entry(_ id: String) -> String { "attributions.entry.\(id)" }    // parakeet | community-1 | fluidaudio
        static func link(_ id: String) -> String { "attributions.entry.\(id).link" }                 // WP7 addition
        static func licenceToggle(_ id: String) -> String { "attributions.entry.\(id).licenceToggle" } // WP7 addition
    }
}
