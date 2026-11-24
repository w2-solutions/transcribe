import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screens 3, 4 and 6 (§6.3–§6.6): one view that changes with the recording's stage.
/// - processing (queued…matching) and capturing: speaker-less paragraphs under "Speakers pending" with WP5's
///   processing panel (or its collapsed pill); when the stage reaches ready the panel stays 0.8 s, then goes.
/// - ready: banner (failed > noSpeech > ask > newVoices > recognised), meta line, turn list, Copy and the player.
/// - failed: the failed card, plus paragraphs when a transcript exists.
struct TranscriptView: View {
    let recordingID: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var matches: [Recording]
    @Query private var profiles: [VoiceProfile]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var cache = DocumentCache()
    @State private var panelCollapsed = false
    @State private var panelHeight: CGFloat = 470
    @State private var completing = false
    @State private var isSearching = false
    @State private var query = ""
    @State private var hitIndex = 0
    @State private var lastTappedTurn: Int?
    @State private var toast: String?
    @State private var errorMessage: String?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    init(recordingID: UUID) {
        self.recordingID = recordingID
        _matches = Query(filter: #Predicate<Recording> { $0.id == recordingID })
    }

    var body: some View {
        Group {
            if let recording = matches.first {
                content(recording)
            } else {
                Color.clear.screenBackground()
            }
        }
        .toast(toast, systemImage: "checkmark", id: AX.Transcript.copiedToast)
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ recording: Recording) -> some View {
        let state = TranscriptViewState(recording: recording, document: cache.document(recording.transcriptData),
                                        profileNames: profileNames)
        let isProcessingLayout = state.phase == .processing || state.phase == .capturing || completing
        Group {
            if isProcessingLayout {
                processingShell(recording, state)
            } else {
                ready(recording, state)
            }
        }
        .onAppear {
            loadAudio(recording)
            markSeenIfNeeded(recording)
        }
        .onDisappear {
            if env.player.loadedURL == audioURL(recording) { env.player.pause() }
        }
        .onChange(of: recording.stage) { old, new in
            if old.isProcessing, new == .ready {
                completing = true
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { completing = false }
                }
            }
            if new == .ready { markSeenIfNeeded(recording) }
        }
    }

    // MARK: Processing (§6.3)

    private func processingShell(_ recording: Recording, _ state: TranscriptViewState) -> some View {
        let showsPanel = recording.stage.isProcessing || completing
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Transcript")
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(DS.Colour.ink)
                    Spacer()
                    StatusPill("Speakers pending")
                        .accessibilityIdentifier(AX.Transcript.speakersPendingPill)
                }
                if state.turns.isEmpty {
                    Text("Your transcript appears here in a moment.")
                        .font(DS.Typo.cardBody)
                        .foregroundStyle(DS.Colour.secondary)
                        .accessibilityIdentifier(AX.Transcript.pendingPlaceholder)
                } else {
                    ForEach(Array(state.turns.enumerated()), id: \.element.id) { i, _ in
                        PendingParagraph(timestamp: state.timestamp(i),
                                         text: state.displayText(i, removeFillers: env.settings.removeFillers))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(padding: EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.top, 8)
            .padding(.bottom, showsPanel && !panelCollapsed ? panelHeight + 16 : 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Transcript.screen)
        .overlay(alignment: .bottom) {
            if showsPanel && !panelCollapsed {
                // Capped below the navigation bar; the panel scrolls its content when it is taller.
                GeometryReader { geo in
                    ProcessingPanel(recordingID: recordingID, maxHeight: geo.size.height - 8,
                                    onContinueInBackground: { router.popToLibrary() },
                                    onShowTranscriptNow: { setPanelCollapsed(true) })
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaBar(edge: .top) {
            if showsPanel && panelCollapsed {
                CollapsedProgressPill(recordingID: recordingID)
                    .onTapGesture { setPanelCollapsed(false) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows processing progress")
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle(DisplayFormat.shortDate(recording.createdAt))
        .inlineNavigationTitle()
        .screenBackground()
    }

    private func setPanelCollapsed(_ collapsed: Bool) {
        withAnimation(reduceMotion ? nil : .snappy) { panelCollapsed = collapsed }
    }

    // MARK: Ready / failed (§6.4–§6.6)

    private func ready(_ recording: Recording, _ state: TranscriptViewState) -> some View {
        let removeFillers = env.settings.removeFillers
        let hits = isSearching ? state.searchHits(query, removeFillers: removeFillers) : []
        let current = hits.isEmpty ? nil : hits[Swift.min(hitIndex, hits.count - 1)]
        let url = audioURL(recording)
        // A recording synced from another device has no audio here (§8.5): no player, no clips, no audio to share.
        let hasAudio = env.store.hasLocalAudio(recording)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !hasAudio {
                        AudioElsewhereBanner(channel: recording.captureChannel)
                    }
                    banner(recording, state, hasAudio: hasAudio)
                    TranscriptMetaLine(date: recording.createdAt, duration: recording.duration)
                    if !state.turns.isEmpty {
                        TranscriptTurnList(state: state, removeFillers: removeFillers, audioURL: url, canPlay: hasAudio,
                                           hits: hits, currentHit: current, lastTappedTurn: $lastTappedTurn,
                                           actions: turnActions(recording, state))
                            .cardSurface(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                    }
                }
                .padding(.horizontal, DS.Space.screenInset)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .onChange(of: current) { _, hit in
                guard let hit, state.turns.indices.contains(hit.turnIndex) else { return }
                withAnimation(reduceMotion ? nil : .snappy) {
                    proxy.scrollTo(state.turns[hit.turnIndex].id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Transcript.screen)
        .safeAreaBar(edge: .top) {
            if isSearching {
                TranscriptSearchBar(query: $query,
                                    countText: TranscriptViewState.searchCountText(
                                        current: hits.isEmpty ? nil : Swift.min(hitIndex, hits.count - 1), total: hits.count),
                                    canStep: !hits.isEmpty,
                                    onPrevious: { stepHit(-1, total: hits.count) },
                                    onNext: { stepHit(1, total: hits.count) })
            }
        }
        .safeAreaBar(edge: .bottom) {
            // Copy shows in every ready state; the player hides while a recording runs (§6.4).
            TranscriptPlayer(audioURL: url, peaks: recording.peaks, duration: recording.duration, turns: state.turns,
                             marks: recording.marks, slotForKey: { state.speaker($0)?.slot },
                             showsCopy: !state.turns.isEmpty, showsPlayer: !env.recorder.isActive, hasAudio: hasAudio,
                             onCopy: { copyAll(state, document: cache.document(recording.transcriptData)) })
        }
        // The search field sits at the top; keep the player at the bottom behind the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: query) { hitIndex = 0 }
        .navigationTitle(recording.title ?? "Transcript")
        .navigationSubtitle(DisplayFormat.cardDate(recording.createdAt))
        .inlineNavigationTitle()
        .toolbar { toolbar(recording, state) }
        .alert("Rename recording", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
                .inputCapitalization(.sentences)
                .accessibilityIdentifier(AX.Transcript.Menu.renameField)
            Button("Save") { rename(recording) }
                .accessibilityIdentifier(AX.Transcript.Menu.renameSave)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the date.")
        }
        .confirmationDialog(env.copy.deleteTranscriptTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) { delete(recording) }
                .accessibilityIdentifier(AX.Transcript.Menu.deleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(env.copy.deleteTranscriptMessage)
        }
        .screenBackground()
    }

    @ToolbarContentBuilder
    private func toolbar(_ recording: Recording, _ state: TranscriptViewState) -> some ToolbarContent {
        ToolbarItemGroup(placement: .trailingBar) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    isSearching.toggle()
                    if !isSearching { query = "" }
                }
            } label: {
                Image(systemName: isSearching ? "xmark" : "magnifyingglass")
            }
            .tint(DS.Colour.ink)
            .accessibilityLabel(isSearching ? "Close search" : "Search transcript")
            .accessibilityIdentifier(AX.Transcript.searchButton)

            TranscriptMoreMenu(
                isFavourite: recording.isFavourite,
                folderID: recording.folder?.id,
                folders: folders,
                shareText: { shareText(recording, state) },
                audioURL: env.store.hasLocalAudio(recording) ? audioURL(recording) : nil,
                shareTitle: recording.displayTitle,
                onRename: {
                    renameText = recording.title ?? ""
                    isRenaming = true
                },
                onToggleFavourite: { perform { try env.store.setFavourite(id: recordingID, !recording.isFavourite) } },
                onMove: { folder in perform { try env.store.move(recordingID: recordingID, toFolder: folder) } },
                onDelete: { isConfirmingDelete = true })
            .tint(DS.Colour.ink)
        }
    }

    // MARK: Banner

    @ViewBuilder
    private func banner(_ recording: Recording, _ state: TranscriptViewState, hasAudio: Bool) -> some View {
        switch state.banner {
        case .failed(let message):
            FailedCard(message: message) {
                Task { await env.coordinator.retry(recordingID) }
            }
        case .noSpeech:
            NoSpeechCard()
        case .ask(let speaker):
            AskBanner(speaker: speaker, detail: askDetail(speaker, recording: recording), canPlay: hasAudio,
                      isPlaying: env.player.playingClipID == askClipID(speaker.key),
                      onPlay: { playAskClip(speaker, recording: recording, state: state) },
                      onYes: { perform { _ = try env.store.confirmSuggestion(recordingID: recordingID, key: speaker.key) } },
                      onNo: {
                          perform {
                              try env.store.rejectSuggestion(recordingID: recordingID, key: speaker.key)
                              router.nameSpeaker(NameSpeakerContext(recordingID: recordingID, key: speaker.key))
                          }
                      })
        case .newVoices(let speakers):
            NewVoicesBanner(count: speakers.count) {
                guard let first = speakers.first else { return }
                router.nameSpeaker(NameSpeakerContext(recordingID: recordingID, key: first.key, mode: .name,
                                                      followUps: speakers.dropFirst().map(\.key)))
            }
        case .recognised(let names):
            RecognisedBanner(names: names) { router.path.append(.voices) }
        case .none:
            EmptyView()
        }
    }

    private func askClipID(_ key: SpeakerKey) -> String { "ask-\(recordingID.uuidString)-\(key)" }

    /// Under "Is this Karan?": why it asks when Karan was learned on another device (§7), else nil (the banner then
    /// says "Speaker 2 sounds like Karan.").
    private func askDetail(_ speaker: TranscriptSpeaker, recording: Recording) -> String? {
        let suggested = speaker.suggestedProfileID.flatMap { id in profiles.first { $0.id == id } }
        return NameSpeakerModel.askPrompt(suggested: suggested, recordingChannel: recording.captureChannel, copy: env.copy)
    }

    private func playAskClip(_ speaker: TranscriptSpeaker, recording: Recording, state: TranscriptViewState) {
        let id = askClipID(speaker.key)
        if env.player.playingClipID == id { env.player.pause(); return }
        let clip = CleanSpeech.listenClips(for: speaker.key, turns: state.turns, max: 1).first?.range
            ?? state.turns.first { $0.effectiveSpeakerKey == speaker.key }.map {
                TimeRange(start: $0.range.start, end: Swift.min($0.range.end, $0.range.start + AlignmentConfig.default.listenClipMax))
            }
        guard let clip else { return }
        env.player.playClip(url: audioURL(recording), range: clip, id: id)
    }

    // MARK: Turn actions

    private func turnActions(_ recording: Recording, _ state: TranscriptViewState) -> TurnActions {
        TurnActions(
            chip: { i in
                guard let speaker = state.speaker(forTurn: i) else { return }
                switch speaker.chipStyle {
                case .unnamed, .suggested:
                    router.nameSpeaker(NameSpeakerContext(recordingID: recordingID, key: speaker.key))
                case .filled:
                    if let profileID = speaker.profileID {
                        router.path.append(.voice(profileID))
                    } else {
                        router.nameSpeaker(NameSpeakerContext(recordingID: recordingID, key: speaker.key,
                                                              mode: .correct(turnID: nil)))
                    }
                }
            },
            timestamp: { i in
                guard state.turns.indices.contains(i) else { return }
                loadAudio(recording)
                env.player.seek(to: state.turns[i].range.start)
                withAnimation(reduceMotion ? nil : .snappy) { lastTappedTurn = i }
            },
            changeSpeaker: { i in
                guard state.turns.indices.contains(i), let key = state.turns[i].effectiveSpeakerKey else { return }
                router.nameSpeaker(NameSpeakerContext(recordingID: recordingID, key: key,
                                                      mode: .correct(turnID: state.turns[i].id)))
            },
            copy: { i in
                Pasteboard.copy(state.displayText(i, removeFillers: env.settings.removeFillers))
                showToast("Copied")
            },
            tap: { i in
                withAnimation(reduceMotion ? nil : .snappy) { lastTappedTurn = i }
            })
    }

    // MARK: Copy, share, rename, delete

    private func speakerName(_ state: TranscriptViewState) -> (SpeakerKey) -> String {
        { key in state.speaker(key)?.name ?? "Speaker" }
    }

    private func copyAll(_ state: TranscriptViewState, document: TranscriptDocument?) {
        guard let document else { return }
        let format: CopyFormat = env.settings.autoCopy == .off ? .withSpeakers : env.settings.autoCopy
        Pasteboard.copy(TranscriptFormatter.plainText(document, format: format, removeFillers: env.settings.removeFillers,
                                                      speakerName: speakerName(state)))
        showToast("Copied")
    }

    private func shareText(_ recording: Recording, _ state: TranscriptViewState) -> String {
        guard let document = cache.document(recording.transcriptData) else { return recording.displayTitle }
        let body = TranscriptFormatter.plainText(document, format: .withSpeakers, removeFillers: env.settings.removeFillers,
                                                 speakerName: speakerName(state))
        return recording.displayTitle + "\n\n" + body
    }

    private func rename(_ recording: Recording) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { try env.store.rename(id: recordingID, title: title.isEmpty ? nil : title) }
    }

    private func delete(_ recording: Recording) {
        let player = env.player
        if player.loadedURL == audioURL(recording) { player.stop() }
        Task {
            await env.coordinator.cancel(recordingID)
            perform {
                try env.store.delete(id: recordingID)
                router.popToLibrary()
            }
        }
    }

    // MARK: Helpers

    private var profileNames: [UUID: String] {
        Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func audioURL(_ recording: Recording) -> URL { env.paths.audioURL(fileName: recording.audioFileName) }

    private func loadAudio(_ recording: Recording) {
        let url = audioURL(recording)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? env.player.load(url: url)
    }

    private func markSeenIfNeeded(_ recording: Recording) {
        guard recording.stage == .ready, recording.hasUnseenResult else { return }
        try? env.store.markSeen(id: recordingID)
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = NameSpeakerModel.message(for: error) }
    }

    private func showToast(_ text: String) {
        toast = nil
        Task {
            await Task.yield()
            toast = text
        }
    }

    private func stepHit(_ delta: Int, total: Int) {
        guard total > 0 else { return }
        hitIndex = (hitIndex + delta + total) % total
    }
}

/// Per-turn callbacks (by turn index).
struct TurnActions {
    var chip: (Int) -> Void
    var timestamp: (Int) -> Void
    var changeSpeaker: (Int) -> Void
    var copy: (Int) -> Void
    var tap: (Int) -> Void
}

/// One stable reference the rows call through, refreshed with the latest callbacks on every list render,
/// so rows can skip re-rendering without holding stale closures.
@MainActor
final class TurnActionsBox {
    var current: TurnActions?
    func update(_ actions: TurnActions) -> Bool { current = actions; return true }
}

/// The ready turn list. It does not read the playback position itself: `NowPlayingProbe` does, and only
/// writes `nowPlaying` when the highlighted phrase changes (about once per phrase, not 20 times a second).
private struct TranscriptTurnList: View {
    let state: TranscriptViewState
    let removeFillers: Bool
    let audioURL: URL
    /// False without local audio: timestamps are plain text, not "play from here".
    let canPlay: Bool
    let hits: [TranscriptViewState.TextSpan]
    let currentHit: TranscriptViewState.TextSpan?
    @Binding var lastTappedTurn: Int?
    let actions: TurnActions
    @State private var nowPlaying: TranscriptViewState.TextSpan?
    @State private var box = TurnActionsBox()

    var body: some View {
        let _ = box.update(actions)
        let marked = state.markedTurnIndices
        let hitsByTurn = Dictionary(grouping: hits, by: \.turnIndex)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.turns.enumerated()), id: \.element.id) { i, turn in
                VStack(alignment: .leading, spacing: 0) {
                    if i > 0 {
                        Rectangle().fill(DS.Colour.divider).frame(height: 1).padding(.vertical, 16)
                    }
                    TurnRow(index: i,
                            speaker: state.speaker(forTurn: i),
                            timestamp: state.timestamp(i),
                            text: state.displayText(i, removeFillers: removeFillers),
                            hasMark: marked.contains(i),
                            highlights: TurnHighlights(
                                nowPlaying: nowPlaying?.turnIndex == i ? nowPlaying?.range : nil,
                                searchHits: hitsByTurn[i]?.map(\.range) ?? [],
                                currentHit: currentHit?.turnIndex == i ? currentHit?.range : nil),
                            showsChangeLink: nowPlaying?.turnIndex == i || lastTappedTurn == i,
                            canPlay: canPlay,
                            actions: box)
                        .equatable()
                }
                .id(turn.id)
            }
        }
        .background {
            NowPlayingProbe(state: state, removeFillers: removeFillers, audioURL: audioURL, nowPlaying: $nowPlaying)
        }
    }
}

/// Observes the 20 Hz playback position and publishes the now-playing phrase only when it changes.
private struct NowPlayingProbe: View {
    let state: TranscriptViewState
    let removeFillers: Bool
    let audioURL: URL
    @Binding var nowPlaying: TranscriptViewState.TextSpan?
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let player = env.player
        let isActive = player.loadedURL == audioURL && (player.isPlaying || player.currentTime > 0)
        let span = isActive ? state.nowPlaying(at: player.currentTime, removeFillers: removeFillers) : nil
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: span, initial: true) { _, new in if nowPlaying != new { nowPlaying = new } }
    }
}

/// Decodes the transcript blob once per change (the `transcript` accessor decodes on every read).
@MainActor
final class DocumentCache {
    private var data: Data?
    private var decoded: TranscriptDocument?

    func document(_ data: Data?) -> TranscriptDocument? {
        if data != self.data {
            self.data = data
            decoded = data.flatMap { try? TranscriptDocument.decode($0) }
        }
        return decoded
    }
}
