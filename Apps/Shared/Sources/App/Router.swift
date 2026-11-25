import Foundation
import Observation
import TranscribeCore
import TranscribeKit

enum Route: Hashable {
    case transcript(UUID)
    case voices
    case voice(UUID)
    case settings
    case modelSettings
    case language
    case attributions
}

struct NameSpeakerContext: Hashable, Identifiable {
    enum Mode: Hashable {
        case name                       // "Who is this?" — whole speaker
        case correct(turnID: UUID?)     // "Who said this?" — from "Wrong speaker? Change"; turnID enables "Just this turn"
    }
    var recordingID: UUID
    var key: SpeakerKey
    var mode: Mode = .name
    var followUps: [SpeakerKey] = []    // "Name speakers" walks every unnamed speaker in ordinal order
    var id: String { "\(recordingID.uuidString)-\(key)-\(followUps.count)" }
}

enum SheetRoute: Identifiable, Hashable {
    case nameSpeaker(NameSpeakerContext)
    var id: String { switch self { case .nameSpeaker(let c): "name-\(c.id)" } }
}

@MainActor @Observable
final class Router {
    var path: [Route] = []
    var sheet: SheetRoute?
    var isRecordingPresented = false
    /// Mac: bumped to bring the Recording window to the front. It can be open but covered or minimised, which leaves
    /// `isRecordingPresented` true, so setting that flag again would change nothing.
    var recordingFocusRequest = 0
    /// Shows the recording screen (and on the Mac brings its window to the front).
    func presentRecording() { isRecordingPresented = true; recordingFocusRequest += 1 }
    func showTranscript(_ id: UUID, replacingPath: Bool = false) { if replacingPath { path = [.transcript(id)] } else { path.append(.transcript(id)) } }
    func popToLibrary() { path.removeAll() }
    func nameSpeaker(_ ctx: NameSpeakerContext) { sheet = .nameSpeaker(ctx) }

    /// Recordings or voices deleted while on screen (by sync from another device, or elsewhere on this one): their
    /// transcript or voice screen pops back to the screen before it, and a name sheet for such a recording closes.
    func dropGone(recordings: Set<UUID>, profiles: Set<UUID>) {
        guard !recordings.isEmpty || !profiles.isEmpty else { return }
        let pruned = GoneModels.prune(path) { route in
            switch route {
            case .transcript(let id): recordings.contains(id)
            case .voice(let id): profiles.contains(id)
            default: false
            }
        }
        if pruned != path { path = pruned }
        if case .nameSpeaker(let ctx)? = sheet, recordings.contains(ctx.recordingID) { sheet = nil }
    }
}
