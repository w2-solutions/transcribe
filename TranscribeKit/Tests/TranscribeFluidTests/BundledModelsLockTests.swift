@testable import FluidAudio
import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// `scripts/models.lock` pins every file the app ships in `BundledModels/`. With the revision markers gone
/// (`FluidRuntime`), these tests are what stops a FluidAudio bump from shipping stale or unloadable models: a change
/// to any bundled repo's pinned revision (the diarizer today, Parakeet if FluidAudio pins it), the Nemotron weights
/// version or the required files fails `swift test` until the lock is regenerated with
/// `./scripts/fetch-models.sh --update-lock`. A bundled repo that `FluidRuntime` does not resolve to "main" fails
/// too, because FluidAudio would reject its marker-less folder offline.
@Suite("Bundled models lock")
struct BundledModelsLockTests {
    /// The repo root: this file is `<repo>/TranscribeKit/Tests/TranscribeFluidTests/BundledModelsLockTests.swift`.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let lockURL = repoRoot.appendingPathComponent("scripts/models.lock")
    static let bundledModels = repoRoot.appendingPathComponent(FluidModelPaths.bundledFolderName, isDirectory: true)

    struct Row: Sendable, Equatable {
        var localPath: String
        var repo: String
        var revision: String
        var remotePath: String
        var size: Int
        var sha256: String
        var folder: String { String(localPath.split(separator: "/", maxSplits: 1).first ?? "") }
    }

    struct Lock: Sendable {
        var metadata: [String: String] = [:]
        var rows: [Row] = []
        /// Lines that are neither comments, metadata nor six tab-separated columns with an integer size.
        var malformed: [String] = []

        func rows(in folder: String) -> [Row] { rows.filter { $0.folder == folder } }
        func row(_ localPath: String) -> Row? { rows.first { $0.localPath == localPath } }
    }

    static func loadLock() throws -> Lock {
        let text = try String(contentsOf: lockURL, encoding: .utf8)
        var lock = Lock()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("@") {
                let parts = line.dropFirst().split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2 { lock.metadata[parts[0]] = parts[1] } else { lock.malformed.append(line) }
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 6, let size = Int(columns[4]) else {
                lock.malformed.append(line)
                continue
            }
            lock.rows.append(Row(localPath: columns[0], repo: columns[1], revision: columns[2], remotePath: columns[3],
                                 size: size, sha256: columns[5]))
        }
        return lock
    }

    static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static let parakeetFolder = FluidModelPaths.asrFolderName
    static let diarizerFolder = FluidModelPaths.diarizerFolderName
    static let nemotronFolder = FluidModelPaths.nemotronFolderName

    @Test func lockPinsMatchFluidAudio() throws {
        let lock = try Self.loadLock()
        // Each folder comes from the repo FluidAudio loads it from, at one revision.
        let repos = [Self.parakeetFolder: Repo.parakeetV3.remotePath, Self.diarizerFolder: Repo.diarizer.remotePath,
                     Self.nemotronFolder: Repo.nemotron3Diarization.remotePath]
        #expect(Set(lock.rows.map(\.folder)) == Set(repos.keys))
        for (folder, repo) in repos {
            let rows = lock.rows(in: folder)
            #expect(!rows.isEmpty, "\(folder) has rows")
            #expect(rows.allSatisfy { $0.repo == repo }, "\(folder) comes from \(repo)")
            #expect(Set(rows.map(\.revision)).count == 1, "\(folder) is pinned to one revision")
        }
        // Where FluidAudio pins a bundled repo to a commit (the diarizer today), the lock must ship exactly that commit.
        for repo in FluidRuntime.bundledRepos where repo.revision != "main" {
            let rows = lock.rows.filter { $0.repo == repo.remotePath }
            #expect(rows.allSatisfy { $0.revision == repo.revision },
                    "\(repo.remotePath) rows must be at FluidAudio's pinned revision \(repo.revision)")
        }
        let diarizer = lock.rows(in: Self.diarizerFolder)
        #expect(diarizer.allSatisfy { $0.revision == Repo.diarizer.revision },
                "speaker-diarization rows must be at FluidAudio's Repo.diarizer.revision \(Repo.diarizer.revision)")
        #expect(lock.metadata["nemotron3-weights"] == ModelNames.Nemotron3.weightsVersion,
                "the lock's Nemotron weights must be FluidAudio's ModelNames.Nemotron3.weightsVersion")
        // Voice profiles are keyed by the embedder revision: a new diarizer commit means re-enrolling everyone.
        #expect(EmbeddingModelID.communityOneResNet34.revision.contains(String(Repo.diarizer.revision.prefix(8))))
        let parakeet = try #require(lock.rows(in: Self.parakeetFolder).first)
        #expect(FluidModelPaths.asrModelID.hasSuffix(String(parakeet.revision.prefix(8))))
    }

    /// The bundle has no `.fluidaudio-revision` markers, so `ModelHub` accepts a bundled folder offline only when the
    /// repo's effective revision is "main" (`ModelCache.matchesRevision`). Every repo in the lock must be in
    /// `FluidRuntime.bundledRepos`, and after `lockDown()` each must resolve to "main" through FluidAudio's own
    /// `ModelRegistry.mapRevision`, whatever `Repo.revision` a FluidAudio release pins it to.
    @Test func everyBundledRepoLoadsWithoutARevisionMarker() throws {
        let lock = try Self.loadLock()
        #expect(Set(lock.rows.map(\.repo)) == Set(FluidRuntime.bundledRepos.map(\.remotePath)),
                "FluidRuntime.bundledRepos lists exactly the repos in scripts/models.lock")
        FluidRuntime.lockDown()
        for repo in FluidRuntime.bundledRepos {
            #expect(ModelRegistry.revisionOverrides[repo.remotePath] == "main", "\(repo.remotePath) is overridden")
            #expect(ModelRegistry.mapRevision(repo.remotePath, default: repo.revision) == "main",
                    "\(repo.remotePath) resolves to main, so its marker-less bundled folder passes matchesRevision")
        }
    }

    /// The community-1 credit links the NOTICE.md of the exact diarizer commit the app ships.
    @Test func communityOneAttributionNamesTheShippedCommit() throws {
        let lock = try Self.loadLock()
        let revision = try #require(lock.rows(in: Self.diarizerFolder).first?.revision)
        let community = try #require(Attributions.all.first { $0.id == "community-1" })
        #expect(community.notes.contains("\(Repo.diarizer.remotePath)/blob/\(revision)/NOTICE.md"),
                "update the community-1 notes in Attributions.swift to the NOTICE.md at \(revision)")
    }

    @Test func lockWasMadeForThisFluidAudio() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { var version: String? }
                var identity: String
                var state: State
            }
            var pins: [Pin]
        }
        let lock = try Self.loadLock()
        let resolvedURL = Self.repoRoot.appendingPathComponent("TranscribeKit/Package.resolved")
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolvedURL))
        let version = try #require(resolved.pins.first { $0.identity == "fluidaudio" }?.state.version)
        #expect(lock.metadata["fluidaudio"] == version, "regenerate scripts/models.lock after a FluidAudio bump")
    }

    @Test func lockCoversEveryRequiredFile() throws {
        let lock = try Self.loadLock()
        func expectRow(_ path: String) {
            #expect(lock.row(path) != nil, "scripts/models.lock has \(path)")
        }
        // Parakeet TDT v3 with the int8 encoder (what `AsrModels.load(from:version: .v3)` loads).
        for name in ModelNames.ASR.requiredModelsV3(precision: .int8).sorted() {
            expectRow("\(Self.parakeetFolder)/\(name)/coremldata.bin")
        }
        expectRow("\(Self.parakeetFolder)/\(ModelNames.ASR.vocabularyFile)")
        // Community-1: four compiled models and the PLDA parameters.
        for name in FluidModelPaths.diarizerRequiredFiles {
            expectRow(name.hasSuffix(".mlmodelc") ? "\(Self.diarizerFolder)/\(name)/coremldata.bin" : "\(Self.diarizerFolder)/\(name)")
        }
        // Nemotron 3 fast128, flat.
        let config = NemotronSeparation.config
        expectRow("\(Self.nemotronFolder)/\(config.modelFileName)/coremldata.bin")
        let sil = lock.row("\(Self.nemotronFolder)/\(ModelNames.Nemotron3.silenceEmbeddingFile)")
        #expect(sil?.size == FluidModelPaths.nemotronSilenceEmbeddingBytes)
        // Every Nemotron row comes from the preset's hub folder (flattened) or is the root asset.
        for row in lock.rows(in: Self.nemotronFolder) {
            #expect(row.remotePath.hasPrefix(config.hubSubdirectory + "/") || row.remotePath == ModelNames.Nemotron3.silenceEmbeddingFile,
                    "\(row.remotePath) belongs to the \(NemotronSeparation.presetName) preset")
        }
    }

    @Test func lockIsWellFormed() throws {
        let lock = try Self.loadLock()
        #expect(lock.malformed.isEmpty, "malformed lines: \(lock.malformed)")
        #expect(!lock.rows.isEmpty)
        for row in lock.rows {
            #expect(Self.isHex(row.revision, count: 40), "\(row.localPath): revision is a full commit")
            #expect(Self.isHex(row.sha256, count: 64), "\(row.localPath): sha256")
            #expect(row.size >= 0, "\(row.localPath): size")
            for path in [row.localPath, row.remotePath] {
                #expect(!path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0.hasPrefix(".") },
                        "\(path): no hidden or empty path components")
            }
            // Local path = <folder>/<remote path>; Nemotron alone drops the hub's subfolder (flat layout).
            var remote = row.remotePath
            let hub = NemotronSeparation.config.hubSubdirectory + "/"
            if row.folder == Self.nemotronFolder, remote.hasPrefix(hub) { remote.removeFirst(hub.count) }
            #expect(row.localPath == "\(row.folder)/\(remote)")
        }
        let paths = lock.rows.map(\.localPath)
        #expect(Set(paths).count == paths.count, "local paths are unique")
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: BundledModelsLockTests.bundledModels.appendingPathComponent(FluidModelPaths.asrFolderName).path),
        "Run ./scripts/fetch-models.sh to fill BundledModels/"))
    func fetchedFolderIsComplete() {
        let paths = FluidModelPaths(root: Self.bundledModels)
        #expect(paths.asrInstalled)
        #expect(paths.diarizerInstalled)
        #expect(paths.nemotronInstalled)
        #expect(paths.allInstalled)
    }
}
