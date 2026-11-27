import Foundation
import SwiftData
import TranscribeCore

@MainActor
public protocol LibraryStoring: AnyObject, Sendable {
    var context: ModelContext { get }

    // MARK: Capture channels
    /// Idempotent launch backfill (§6.4): recordings with no capture channel get this device's channel; samples and
    /// negatives with none take their source recording's channel when it still exists, else this device's; group labels
    /// with text and an empty channel (seeded) take this device's. One save, only when something changed. Never deletes
    /// anything. Returns the number of rows stamped.
    func stampCaptureChannels() throws -> Int

    // MARK: Local audio (§8.5)
    /// Whether this device has the recording's audio (the file `audioFileName` names). A recording synced from another
    /// device has it once its copy is downloaded; until then the audio is not on this device (not in iCloud, not
    /// downloaded yet, or not syncing here), and neither is the audio of a recording whose file was lost.
    func hasLocalAudio(_ recording: Recording) -> Bool
    /// Launch sweep: deletes `Audio/*.wav` and `Audio/*.m4a` files that no recording row names, when older than
    /// `minimumAge` (so a capture that has not saved its row yet is never touched). Returns the number of files deleted.
    @discardableResult func sweepOrphanAudio(minimumAge: TimeInterval, now: Date) throws -> Int
    /// Launch, before the sweep: a ready row whose named file is missing but a downloaded copy `Audio/<id>.m4a`
    /// exists is pointed at it. Returns the rows fixed. Stores that keep no audio (test doubles) return 0.
    @discardableResult func adoptStrayDownloads() throws -> Int

    // MARK: Recording lifecycle
    /// Stage .capturing. `captureSources` other than the microphone are saved at once as a provisional capture
    /// detail (sources and input only), so a capture salvaged after a crash or a failed stop is still processed as
    /// what it captured; `finishCapture` replaces it with the full detail.
    func createRecording(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource,
                         captureSources: CaptureSources) throws
    func finishCapture(id: UUID, audio: CapturedAudio, language: LanguageHint) throws                         // → .queued
    func discardRecording(id: UUID) throws                                                                   // deletes row + file
    func snapshot(of id: UUID) throws -> RecordingSnapshot
    func setStage(_ stage: RecordingStage, queueReason: QueueReason?, for id: UUID) throws
    /// → .transcribed; sets previewText, searchText, asrModelID, transcriptData (paragraph turns).
    func checkpointTranscript(id: UUID, document: TranscriptDocument) throws
    /// → .separated; replaces speakers with drafts (provisional slots via ColourAssigner without profiles).
    func checkpointSeparation(id: UUID, document: TranscriptDocument, speakers: [SpeakerDraft]) throws
    func probes(for id: UUID) throws -> [SpeakerProbe]
    func matchCandidates(modelKey: String) throws -> [ProfileCandidate]
    /// Unnamed (or snapshot-named) voices from past ready recordings on this model, for the auto-label margin (§1.5).
    func matchCohort(modelKey: String, excludingRecording: UUID) throws -> [VoiceVector]
    /// → .ready; applies labels, colour slots, automatic samples, hasUnseenResult and each speaker's match trace;
    /// returns counts.
    func applyMatches(id: UUID, decisions: [SpeakerKey: MatchDecision], traces: [SpeakerKey: MatchTrace],
                      policy: MatchPolicy) throws -> ProcessingOutcome
    /// → .ready with speaker-less transcript (no speech, identify-off, or recognise-off without matching).
    func finishWithoutMatching(id: UUID, document: TranscriptDocument?, noSpeech: Bool) throws -> ProcessingOutcome
    func markFailed(id: UUID, message: String) throws
    /// Counts one processing attempt, persisted before the run starts so a run the OS kills still counts.
    func incrementAttempt(id: UUID) throws -> Int
    /// Gives back an attempt whose run was pre-empted (capture, background expiry, models missing, cancelled).
    func releaseAttempt(id: UUID) throws
    func resetForRetry(id: UUID) throws                       // attemptCount = 0, failure cleared, → .queued
    func recoveryCandidates() throws -> [RecoverySnapshot]    // stage < .ready (including .capturing)
    func repairCaptured(id: UUID, duration: TimeInterval, peaks: [Float]) throws   // after WAVRepair → .queued

    // MARK: Library edits
    func rename(id: UUID, title: String?) throws
    func setFavourite(id: UUID, _ isFavourite: Bool) throws
    func markSeen(id: UUID) throws
    func delete(id: UUID) throws                              // row, speakers, audio file; samples keep vectors
    func createFolder(name: String) throws -> UUID
    func renameFolder(id: UUID, name: String) throws
    func deleteFolder(id: UUID) throws
    func move(recordingID: UUID, toFolder folderID: UUID?) throws

    // MARK: Speakers and voices
    func nameSpeaker(recordingID: UUID, key: SpeakerKey, as target: NameTarget, remember: Bool) throws -> NameResult
    func confirmSuggestion(recordingID: UUID, key: SpeakerKey) throws -> NameResult
    func rejectSuggestion(recordingID: UUID, key: SpeakerKey) throws
    func reassignTurn(recordingID: UUID, turnID: UUID, to target: TurnTarget) throws
    /// Whole-speaker "Same as Speaker N": moves every turn, rolls back a wrong auto-label or name, removes the
    /// emptied speaker. One transaction.
    func moveAllTurns(recordingID: UUID, from source: SpeakerKey, to target: SpeakerKey) throws
    func setAutoLabel(profileID: UUID, _ on: Bool) throws
    func setIsMe(profileID: UUID?) throws                    // at most one profile is "me"
    func renameProfile(profileID: UUID, name: String) throws
    func mergeProfiles(source: UUID, into target: UUID) throws
    func forgetProfile(_ profileID: UUID) throws              // keeps nameSnapshot on every speaker
    func addSample(profileID: UUID, fromSpeaker recordingSpeakerID: UUID) throws -> NameResult
    func sampleCandidates(for profileID: UUID) throws -> [SampleCandidate]
    /// Deletes one voice sample. A profile left with no sample on its model needs a new one.
    func removeSample(id: UUID) throws

    // MARK: Sample group labels
    /// Saves `text` (trimmed, cut to `GroupLabelText.maxLength`) as the group's label: updates the label the group
    /// shows (text, `editedAt`, and the anchor, to the group's members now) or inserts one. Empty text removes the
    /// shown label (nothing when there is none). Never touches another label, contenders included. Returns the saved
    /// label's id, nil when nothing is saved. Throws `StoreError.groupChanged` unless a group with `ref.key` exists
    /// now on `ref.channel` with the same members and the same shown label.
    @discardableResult func setGroupLabel(_ ref: SampleGroupRef, text: String) throws -> UUID?
    /// Deletes the label the group shows, and only that one. Same `StoreError.groupChanged` check.
    func removeGroupLabel(_ ref: SampleGroupRef) throws

    // MARK: Diagnostics
    /// JSON of match scores and decisions for tuning: no names, titles, text or vectors.
    func matchingLog() throws -> String
}

public extension LibraryStoring {
    /// A microphone recording (or an import).
    func createRecording(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) throws {
        try createRecording(id: id, createdAt: createdAt, audioFileName: audioFileName, source: source,
                            captureSources: .microphone)
    }

    /// Applies decisions without traces.
    func applyMatches(id: UUID, decisions: [SpeakerKey: MatchDecision], policy: MatchPolicy) throws -> ProcessingOutcome {
        try applyMatches(id: id, decisions: decisions, traces: [:], policy: policy)
    }

    /// Stores that keep no downloaded audio (test doubles) have nothing to adopt.
    @discardableResult func adoptStrayDownloads() throws -> Int { 0 }

    /// Stores that do not keep labels (test doubles) throw.
    @discardableResult func setGroupLabel(_ ref: SampleGroupRef, text: String) throws -> UUID? {
        throw StoreError.notImplemented("setGroupLabel")
    }
    func removeGroupLabel(_ ref: SampleGroupRef) throws {
        throw StoreError.notImplemented("removeGroupLabel")
    }
}
