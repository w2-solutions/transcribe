import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Recordings without local audio and the launch sweep of orphaned audio files (§8.5).
@Suite("Local audio")
@MainActor
struct LocalAudioTests {
    @Test func hasLocalAudioFollowsTheFile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = try h.recording(Seeds.ID.recordingA)
        #expect(h.store.hasLocalAudio(a))
        try FileManager.default.removeItem(at: h.paths.audioURL(fileName: a.audioFileName))
        #expect(!h.store.hasLocalAudio(a))
    }

    @Test func sweepRemovesOnlyOldFilesNoRowNames() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let fm = FileManager.default
        let now = Date()
        func write(_ name: String, age: TimeInterval) throws -> URL {
            let url = h.paths.audioURL(fileName: name)
            try Data("RIFF".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let oldOrphan = try write("\(UUID().uuidString).wav", age: 2 * 3_600)
        let newOrphan = try write("\(UUID().uuidString).wav", age: 10 * 60)     // a capture still saving its row
        let notAudio = try write("notes.txt", age: 2 * 3_600)
        let seeded = h.paths.audioURL(fileName: try h.recording(Seeds.ID.recordingA).audioFileName)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-5 * 3_600)], ofItemAtPath: seeded.path)

        #expect(try h.store.sweepOrphanAudio(minimumAge: 3_600, now: now) == 1)
        #expect(!fm.fileExists(atPath: oldOrphan.path))
        #expect(fm.fileExists(atPath: newOrphan.path))
        #expect(fm.fileExists(atPath: notAudio.path))
        #expect(fm.fileExists(atPath: seeded.path))   // its row names it
    }

    @Test func sweepKeepsTheFileOfARecordingStillCapturing() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = UUID()
        let name = h.paths.newAudioFileName(for: id)
        try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: name, source: .microphone)
        let url = h.paths.audioURL(fileName: name)
        try Data("RIFF".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3_600)], ofItemAtPath: url.path)
        #expect(try h.store.sweepOrphanAudio(minimumAge: 3_600, now: Date()) == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Downloaded audio

    /// Writes `data` to Audio/<name>, `age` seconds old.
    private func writeAudio(_ h: WP3Harness, _ name: String, age: TimeInterval, data: Data = Data("audio".utf8)) throws -> URL {
        let url = h.paths.audioURL(fileName: name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test func sweepRemovesAnOrphanM4A() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let orphan = try writeAudio(h, "\(UUID().uuidString).m4a", age: 2 * 3_600)
        let fresh = try writeAudio(h, "\(UUID().uuidString).m4a", age: 60)
        #expect(try h.store.sweepOrphanAudio(minimumAge: 3_600, now: Date()) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func sweepKeepsADownloadedFileItsRowNames() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = try h.recording(Seeds.ID.recordingA)
        let wav = h.paths.audioURL(fileName: a.audioFileName)
        try FileManager.default.removeItem(at: wav)
        let copy = try writeAudio(h, "\(a.id.uuidString).m4a", age: 5 * 3_600)
        a.audioFileName = copy.lastPathComponent
        try h.context.save()
        #expect(try h.store.sweepOrphanAudio(minimumAge: 3_600, now: Date()) == 0)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(h.store.hasLocalAudio(a))
    }

    @Test func adoptStrayDownloadsPointsTheRowAtTheCopy() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = try h.recording(Seeds.ID.recordingA), b = try h.recording(Seeds.ID.recordingB)
        // A: the WAV is gone (synced from another device) and a download landed before the crash that lost its save.
        try FileManager.default.removeItem(at: h.paths.audioURL(fileName: a.audioFileName))
        _ = try writeAudio(h, "\(a.id.uuidString).m4a", age: 0)
        // B: its own WAV is there, and a stray copy next to it is left alone.
        _ = try writeAudio(h, "\(b.id.uuidString).m4a", age: 0)
        #expect(try h.store.adoptStrayDownloads() == 1)
        #expect(a.audioFileName == "\(a.id.uuidString).m4a")
        #expect(h.store.hasLocalAudio(a))
        #expect(b.audioFileName == "\(b.id.uuidString).wav")
        #expect(!h.context.hasChanges)                               // saved
        #expect(try h.store.adoptStrayDownloads() == 0)              // idempotent
        // The protocol's default, for stores that keep no downloads (a test double).
        #expect(try (NamingSpyStore(context: h.context) as any LibraryStoring).adoptStrayDownloads() == 0)
    }

    @Test func installDownloadedAudioRefusesAGoneOrLocalRecording() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let fm = FileManager.default
        func part(_ id: UUID) throws -> URL {
            let url = h.paths.audioIncomingDirectory.appendingPathComponent("\(id.uuidString).m4a.part")
            try Data("aac".utf8).write(to: url)
            return url
        }
        // A recording that still has its own audio: refused, the download deleted.
        let a = try h.recording(Seeds.ID.recordingA)
        let localPart = try part(a.id)
        #expect(try !h.store.installDownloadedAudio(localPart, for: a.id, fileExtension: "m4a"))
        #expect(!fm.fileExists(atPath: localPart.path))
        #expect(a.audioFileName == "\(a.id.uuidString).wav")
        // A recording that is gone.
        let gone = UUID()
        let gonePart = try part(gone)
        #expect(try !h.store.installDownloadedAudio(gonePart, for: gone, fileExtension: "m4a"))
        #expect(!fm.fileExists(atPath: gonePart.path))
        #expect(!fm.fileExists(atPath: h.paths.audioURL(fileName: "\(gone.uuidString).m4a").path))
        // A recording still processing.
        let queued = try h.queuedRecording()                         // no file written
        let queuedPart = try part(queued)
        #expect(try !h.store.installDownloadedAudio(queuedPart, for: queued, fileExtension: "m4a"))
        #expect(!fm.fileExists(atPath: queuedPart.path))

        // A ready recording without its audio: moved in, the row repointed and saved, nothing else touched.
        let b = try h.recording(Seeds.ID.recordingB)
        try fm.removeItem(at: h.paths.audioURL(fileName: b.audioFileName))
        let (stage, attempts) = (b.stage, b.attemptCount)
        let bPart = try part(b.id)
        #expect(try h.store.installDownloadedAudio(bPart, for: b.id, fileExtension: "M4A"))
        #expect(!fm.fileExists(atPath: bPart.path))
        #expect(b.audioFileName == "\(b.id.uuidString).m4a")
        #expect(try Data(contentsOf: h.paths.audioURL(fileName: b.audioFileName)) == Data("aac".utf8))
        #expect(h.store.hasLocalAudio(b))
        #expect(b.stage == stage && b.attemptCount == attempts)
        #expect(!h.context.hasChanges)

        // A PCM copy keeps the row's name: no save needed, the file is simply there.
        let c = try h.recording(Seeds.ID.recordingC)
        try fm.removeItem(at: h.paths.audioURL(fileName: c.audioFileName))
        #expect(try h.store.installDownloadedAudio(try part(c.id), for: c.id, fileExtension: "wav"))
        #expect(c.audioFileName == "\(c.id.uuidString).wav")
        #expect(h.store.hasLocalAudio(c))
    }

    @Test func aCrashBetweenTheMoveAndTheSaveIsAdoptedAtLaunch() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = try h.recording(Seeds.ID.recordingA)
        try FileManager.default.removeItem(at: h.paths.audioURL(fileName: a.audioFileName))
        let part = h.paths.audioIncomingDirectory.appendingPathComponent("\(a.id.uuidString).m4a.part")
        try Data("aac".utf8).write(to: part)
        struct Crash: Error {}
        #expect(throws: Crash.self) {
            try h.store.installDownloadedAudio(part, for: a.id, fileExtension: "m4a", afterMove: { throw Crash() })
        }
        #expect(a.audioFileName == "\(a.id.uuidString).wav")         // not repointed
        #expect(FileManager.default.fileExists(atPath: h.paths.audioURL(fileName: "\(a.id.uuidString).m4a").path))
        #expect(try h.store.adoptStrayDownloads() == 1)
        #expect(h.store.hasLocalAudio(a))
        #expect(try h.store.sweepOrphanAudio(minimumAge: 0, now: Date().addingTimeInterval(3_600)) == 0)
    }

    @Test func removeAudioAlsoClearsScratch() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let fm = FileManager.default
        let a = try h.recording(Seeds.ID.recordingA)
        let id = a.id.uuidString
        let other = UUID().uuidString
        let files = [h.paths.audioOutgoingDirectory.appendingPathComponent("\(id).m4a"),
                     h.paths.audioOutgoingDirectory.appendingPathComponent("\(id).tmp.m4a"),
                     h.paths.audioIncomingDirectory.appendingPathComponent("\(id).m4a.part"),
                     h.paths.audioURL(fileName: "\(id).m4a")]
        let kept = [h.paths.audioOutgoingDirectory.appendingPathComponent("\(other).m4a"),
                    h.paths.audioIncomingDirectory.appendingPathComponent("\(other).wav.part")]
        for url in files + kept { try Data("x".utf8).write(to: url) }
        try h.store.delete(id: a.id)
        #expect(!fm.fileExists(atPath: h.paths.audioURL(fileName: "\(id).wav").path))
        for url in files { #expect(!fm.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in kept { #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
    }

    @Test func prepareCreatesScratchFoldersExcludedFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        #expect(paths.audioIncomingDirectory == root.appendingPathComponent("AudioIncoming", isDirectory: true))
        #expect(paths.audioOutgoingDirectory == root.appendingPathComponent("AudioOutgoing", isDirectory: true))
        try paths.prepare()
        try paths.prepare()                                          // idempotent
        func excluded(_ url: URL) throws -> Bool {
            try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        }
        var isDir: ObjCBool = false
        for dir in [paths.audioIncomingDirectory, paths.audioOutgoingDirectory] {
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            #expect(try excluded(dir))
        }
        // Recordings' audio, downloaded copies included, stays in backups.
        #expect(try !excluded(paths.audioDirectory))
    }
}
