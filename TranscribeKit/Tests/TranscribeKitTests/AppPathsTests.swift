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

    @Test func removeLegacyModelsIsIdempotent() throws {
        try paths.prepare()
        #expect(!paths.removeLegacyModels())
        #expect(!paths.removeLegacyModels())
        #expect(FileManager.default.fileExists(atPath: paths.audioDirectory.path))
    }
}
