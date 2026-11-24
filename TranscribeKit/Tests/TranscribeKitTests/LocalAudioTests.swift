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
}
