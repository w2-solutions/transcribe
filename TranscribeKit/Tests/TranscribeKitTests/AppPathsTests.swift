import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

@Suite("AppPaths")
final class AppPathsTests {
    let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("apppaths-\(UUID().uuidString)", isDirectory: true)
    var paths: AppPaths { AppPaths(root: root) }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func prepareNoLongerCreatesModels() throws {
        try paths.prepare()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: paths.audioDirectory.path))
        #expect(!fm.fileExists(atPath: paths.legacyModelsDirectory.path))
        #expect(paths.legacyModelsDirectory.lastPathComponent == "Models")
        #expect(paths.prepareLogURL == root.appendingPathComponent("prepare-log.jsonl"))
        #expect(!fm.fileExists(atPath: paths.prepareLogURL.path), "prepare() does not create the prepare log")
    }

    @Test func removeLegacyModelsDeletesTheOldDownload() throws {
        let fm = FileManager.default
        try paths.prepare()
        let weights = paths.legacyModelsDirectory.appendingPathComponent("x.mlmodelc/weights", isDirectory: true)
        try fm.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: weights.appendingPathComponent("weight.bin"))
        try Data([1]).write(to: paths.legacyModelsDirectory.appendingPathComponent("a.partial"))
        let audio = paths.audioURL(fileName: "keep.wav")
        try Data([1, 2, 3]).write(to: audio)
        try Data([4]).write(to: paths.storeURL)

        #expect(paths.removeLegacyModels())
        #expect(!fm.fileExists(atPath: paths.legacyModelsDirectory.path))
        #expect(fm.fileExists(atPath: audio.path))
        #expect(fm.fileExists(atPath: paths.storeURL.path))
    }

    @Test func dictationFilesLiveApartFromTheLibrary() throws {
        let fm = FileManager.default
        try paths.prepare()
        #expect(paths.dictationDirectory == root.appendingPathComponent("Dictation", isDirectory: true))
        #expect(!fm.fileExists(atPath: paths.dictationDirectory.path), "prepare() does not create Dictation/")
        try paths.prepareDictation()
        #expect(fm.fileExists(atPath: paths.dictationDirectory.path))
        let excluded = try paths.dictationDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)

        let a = paths.newDictationURL(), b = paths.newDictationURL()
        #expect(a != b)
        #expect(a.deletingLastPathComponent().standardizedFileURL == paths.dictationDirectory.standardizedFileURL)
        #expect(a.lastPathComponent.hasPrefix(DictationFiles.prefix) && a.pathExtension == "wav")
        #expect(DictationFiles.prefix == "dictation-")

        try Data([1]).write(to: a)
        let audio = paths.audioURL(fileName: "keep.wav")
        try Data([2]).write(to: audio)
        paths.clearDictationFiles()
        #expect(!fm.fileExists(atPath: paths.dictationDirectory.path))
        #expect(fm.fileExists(atPath: audio.path))
        paths.clearDictationFiles()   // nothing there: fine
    }

    /// Another copy of Transcribe shares the folder and may be dictating into it: only files untouched for an hour go.
    @Test func whileAnotherCopyRunsOnlyOldDictationFilesGo() throws {
        let fm = FileManager.default
        try paths.prepareDictation()
        let now = Date()
        let old = paths.newDictationURL(), recent = paths.newDictationURL()
        try Data([1]).write(to: old)
        try Data([2]).write(to: recent)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-AppPaths.dictationLeftoverAge - 1)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)

        paths.clearDictationFiles(otherCopyRunning: true, now: now)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: recent.path))

        paths.clearDictationFiles(otherCopyRunning: false, now: now)
        #expect(!fm.fileExists(atPath: paths.dictationDirectory.path))
        paths.clearDictationFiles(otherCopyRunning: true, now: now)   // no folder: fine
        #expect(AppPaths.dictationLeftoverAge > DictationLimits.handsFreeMax + DictationLimits.modelsWaitCap)
    }

    @Test func removeLegacyModelsIsIdempotent() throws {
        try paths.prepare()
        #expect(!paths.removeLegacyModels())
        #expect(!paths.removeLegacyModels())
        #expect(FileManager.default.fileExists(atPath: paths.audioDirectory.path))
    }
}
