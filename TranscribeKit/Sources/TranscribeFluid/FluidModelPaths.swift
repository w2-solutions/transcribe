import FluidAudio
import Foundation

/// Where the FluidAudio model files live under the app's models root, and whether they are complete.
///
/// The two FluidAudio loaders read "directory" differently (research §2):
/// - `AsrModels.download(to:)` / `load(from:)` take the model folder itself and use `<its parent>/<Repo.folderName>`.
/// - `OfflineDiarizerModels.load(from:)` takes the root and appends the diarizer's folder itself.
///
/// FluidAudio's cache folder names drop the HF repo's "-coreml" suffix (`Repo.folderName`), so on disk the
/// folders are `<root>/parakeet-tdt-0.6b-v3`, `<root>/speaker-diarization` and `<root>/nemotron-3-diarization`
/// (not the repo names).
///
/// `Nemotron3Models.loadFromHuggingFace(config:cacheDirectory:)` takes the root and keeps the repo layout:
/// `<root>/nemotron-3-diarization/monolithic/v2/<bundle>.mlmodelc` plus the root `.bin` asset and a weights-version marker.
public struct FluidModelPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Repo folder names, taken from FluidAudio so a rename upstream cannot silently split the cache.
    public static let asrFolderName = Repo.parakeetV3.folderName              // "parakeet-tdt-0.6b-v3"
    public static let diarizerFolderName = Repo.diarizer.folderName           // "speaker-diarization"
    public static let nemotronFolderName = Repo.nemotron3Diarization.folderName // "nemotron-3-diarization"

    /// The five files the offline (community-1) diarizer needs: four compiled models and the PLDA parameters.
    public static let diarizerRequiredFiles: [String] = ModelNames.OfflineDiarizer.requiredModels.sorted()

    /// What the Nemotron 3 (fp16 `fast128`) set needs, relative to its repo folder: the compiled bundle and the root
    /// assets (`learnable_sil_emb.bin`; `pre_encode_proj_t.bin` only for split-graph presets, so not here).
    public static var nemotronRequiredFiles: [String] {
        let config = NemotronSeparation.config
        var files = ["\(config.hubSubdirectory)/\(config.modelFileName)", ModelNames.Nemotron3.silenceEmbeddingFile]
        if config.splitGraph { files.append(ModelNames.Nemotron3.preEncodeProjectionFile) }
        return files
    }

    /// Download sizes reported to the UI (HF API, 2026-11-23; research §2).
    public static let speechDownloadBytes: Int64 = 483_000_000
    /// pyannote community-1 (segmentation, embedding, PLDA): the fallback separator and the voice embedder.
    public static let communityOneDownloadBytes: Int64 = 22_000_000
    /// Nemotron 3 fp16 `fast128` (HF main = revision 25a90f97 on 2026-11-23): bundle 199_094_387 + asset 2_048 bytes.
    public static let nemotronDownloadBytes: Int64 = 199_096_000
    /// Everything for "who spoke when" and voice vectors.
    public static let speakersDownloadBytes: Int64 = communityOneDownloadBytes + nemotronDownloadBytes
    public static let totalDownloadBytes: Int64 = speechDownloadBytes + speakersDownloadBytes

    /// Passed to `AsrModels.download(to:)` / `AsrModels.load(from:)`.
    public var asrDirectory: URL { root.appendingPathComponent(Self.asrFolderName, isDirectory: true) }

    /// Passed to `OfflineDiarizerModels.load(from:)` (the root, not the repo folder).
    public var diarizerLoadDirectory: URL { root }

    /// Where the diarizer files actually land.
    public var diarizerDirectory: URL { root.appendingPathComponent(Self.diarizerFolderName, isDirectory: true) }

    /// Passed to `Nemotron3Models.loadFromHuggingFace(cacheDirectory:)` (the root, not the repo folder).
    public var nemotronLoadDirectory: URL { root }

    /// Where the Nemotron 3 files land.
    public var nemotronDirectory: URL { root.appendingPathComponent(Self.nemotronFolderName, isDirectory: true) }

    /// Parakeet TDT v3 (int8 encoder) is complete and load-ready: every `.mlmodelc` has `coremldata.bin`,
    /// no `*.partial` download is left over, and the vocabulary is present.
    public var asrInstalled: Bool {
        AsrModels.modelsExist(at: asrDirectory, version: .v3)
    }

    /// FluidAudio has no public cache check for the diarizer, so this mirrors its internal rule:
    /// each required `.mlmodelc` is a directory containing `coremldata.bin` with no `*.partial` file inside,
    /// and each plain file exists.
    public var diarizerInstalled: Bool {
        Self.isComplete(directory: diarizerDirectory, requiredFiles: Self.diarizerRequiredFiles)
    }

    /// Nemotron 3 is complete: the bundle (with `coremldata.bin`, no `*.partial`), the assets, and FluidAudio's
    /// weights-version marker matching this FluidAudio release. Without the marker `loadFromHuggingFace` would
    /// delete the folder as stale and try to download it again, so a missing marker means "not installed".
    public var nemotronInstalled: Bool {
        guard Self.isComplete(directory: nemotronDirectory, requiredFiles: Self.nemotronRequiredFiles) else { return false }
        let marker = nemotronDirectory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        let cached = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cached == ModelNames.Nemotron3.weightsVersion
    }

    /// Every model set is on disk. An older install without Nemotron 3 is therefore "not installed": the Library
    /// card offers the download again, and only the missing Nemotron files are fetched (§5.10).
    public var allInstalled: Bool { asrInstalled && diarizerInstalled && nemotronInstalled }

    /// Bytes on disk for the speech (ASR) folder.
    public var speechBytesOnDisk: Int64 { Self.allocatedSize(of: asrDirectory) }

    /// Bytes on disk for the speaker models (community-1 and Nemotron 3 folders).
    public var speakersBytesOnDisk: Int64 { Self.allocatedSize(of: diarizerDirectory) + Self.allocatedSize(of: nemotronDirectory) }

    /// Files a build that shipped the 95 MB `c128-split-w8a8` variant left in the Nemotron folder; removed after a
    /// successful install so they do not take 100 MB for nothing.
    public static let nemotronObsoleteItems = ["split", ModelNames.Nemotron3.preEncodeProjectionFile]

    /// Every model folder. Deleting these removes every model file the engine uses.
    public var modelFolders: [URL] { [asrDirectory, diarizerDirectory, nemotronDirectory] }

    // MARK: Helpers (internal for tests)

    static func isComplete(directory: URL, requiredFiles: [String]) -> Bool {
        let fm = FileManager.default
        for name in requiredFiles {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            if name.hasSuffix(".mlmodelc") {
                guard isDirectory.boolValue,
                      fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path),
                      !containsPartialDownload(url)
                else { return false }
            } else if isDirectory.boolValue {
                return false
            }
        }
        return true
    }

    static func containsPartialDownload(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let item as URL in enumerator where item.pathExtension == "partial" { return true }
        return false
    }

    /// Total allocated size of every regular file below `url` (0 when missing).
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
