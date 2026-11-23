import Foundation
import Observation
import TranscribeCore

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
    func showTranscript(_ id: UUID, replacingPath: Bool = false) { if replacingPath { path = [.transcript(id)] } else { path.append(.transcript(id)) } }
    func popToLibrary() { path.removeAll() }
    func nameSpeaker(_ ctx: NameSpeakerContext) { sheet = .nameSpeaker(ctx) }
}
