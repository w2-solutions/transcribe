import Foundation
import TranscribeCore
import TranscribeKit

/// Imports an audio file as a new recording and queues it for processing. Shared by the iPhone's import button
/// and the Mac's importer and drop target. Returns the new recording's id; on failure nothing is left behind
/// (no row, no copied file) and the error is rethrown for the caller to show.
@MainActor func importAudio(from source: URL, env: AppEnvironment) async throws -> UUID {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let id = UUID()
    let fileName = env.paths.newAudioFileName(for: id)
    let destination = env.paths.audioURL(fileName: fileName)
    var created = false
    do {
        try env.paths.prepare()
        let audio = try await AudioImporter.importAudio(from: source, to: destination)
        try env.store.createRecording(id: id, createdAt: env.clock.now, audioFileName: fileName, source: .imported)
        created = true
        try env.store.finishCapture(id: id, audio: audio, language: env.settings.language)
        await env.coordinator.enqueue(id)
        return id
    } catch {
        if created { try? env.store.discardRecording(id: id) } else { try? FileManager.default.removeItem(at: destination) }
        throw error
    }
}
