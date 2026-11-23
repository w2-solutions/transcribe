import FluidAudio
import Foundation

/// Where the FluidAudio model files live under the models root, and whether they are complete.
///
/// The root is the read-only `BundledModels` folder inside the app bundle (`bundledRoot()`), filled at build time
/// by `scripts/fetch-models.sh` from the pinned `scripts/models.lock`. Nothing is ever downloaded or written there.
///
/// FluidAudio's folder names drop the HF repo's "-coreml" suffix (`Repo.folderName`), so the folders are
/// `<root>/parakeet-tdt-0.6b-v3`, `<root>/speaker-diarization` and `<root>/nemotron-3-diarization`.
///
/// The three loaders read "directory" differently (research §2):
/// - `AsrModels.load(from:)` takes the model folder itself.
/// - `OfflineDiarizerModels.load(from:)` takes the root and appends the diarizer's folder itself.
/// - `Nemotron3Models.load(config:directory:)` takes a flat folder: `<dir>/<bundle>.mlmodelc` next to
///   `<dir>/learnable_sil_emb.bin` (not the hub's `monolithic/v2/` layout).
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

    /// What the Nemotron 3 (fp16 `fast128`) set needs, flat in its folder: the compiled bundle and the root
    /// assets (`learnable_sil_emb.bin`; `pre_encode_proj_t.bin` only for split-graph presets, so not here).
    public static var nemotronRequiredFiles: [String] {
        let config = NemotronSeparation.config
        var files = [config.modelFileName, ModelNames.Nemotron3.silenceEmbeddingFile]
        if config.splitGraph { files.append(ModelNames.Nemotron3.preEncodeProjectionFile) }
        return files
    }

    /// The folder inside the app bundle that holds the shipped models.
    public static let bundledFolderName = "BundledModels"

    /// `<bundle resources>/BundledModels`: the models root of a shipped app.
    public static func bundledRoot(in bundle: Bundle = .main) -> URL {
        (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent(bundledFolderName, isDirectory: true)
    }

    /// The Parakeet set the app ships: repo plus the first 8 characters of the pinned revision in
    /// `scripts/models.lock` (a test ties the two together).
    public static let asrModelID = "parakeet-tdt-0.6b-v3-coreml@7dd20fe6"

    /// FluidAudio's revision marker (`ModelCache.revisionMarkerName`, internal there).
    static let revisionMarkerFile = ".fluidaudio-revision"

    /// Passed to `AsrModels.load(from:)`.
    public var asrDirectory: URL { root.appendingPathComponent(Self.asrFolderName, isDirectory: true) }

    /// Passed to `OfflineDiarizerModels.load(from:)` (the root, not the repo folder).
    public var diarizerLoadDirectory: URL { root }

    /// Where the diarizer files actually land.
    public var diarizerDirectory: URL { root.appendingPathComponent(Self.diarizerFolderName, isDirectory: true) }

    /// Passed to `Nemotron3Models.load(config:directory:)`: the bundle and its assets sit flat in this folder.
    public var nemotronDirectory: URL { root.appendingPathComponent(Self.nemotronFolderName, isDirectory: true) }

    /// Parakeet TDT v3 (int8 encoder) is complete and load-ready: every `.mlmodelc` has `coremldata.bin`,
    /// no `*.partial` download is left over, and the vocabulary is present.
    public var asrInstalled: Bool {
        AsrModels.modelsExist(at: asrDirectory, version: .v3)
    }

    /// FluidAudio has no public cache check for the diarizer, so this mirrors its internal rule:
    /// each required `.mlmodelc` is a directory containing `coremldata.bin` with no `*.partial` file inside,
    /// and each plain file exists. The folder must also carry no `.fluidaudio-revision` marker: with the "main"
    /// override (`FluidRuntime`), a marker naming the pinned commit would make FluidAudio treat the folder as stale.
    public var diarizerInstalled: Bool {
        guard Self.isComplete(directory: diarizerDirectory, requiredFiles: Self.diarizerRequiredFiles) else { return false }
        let marker = diarizerDirectory.appendingPathComponent(Self.revisionMarkerFile)
        return !FileManager.default.fileExists(atPath: marker.path)
    }

    /// Nemotron 3 is complete in the flat layout: the bundle (with `coremldata.bin`, no `*.partial`) and
    /// `learnable_sil_emb.bin` of exactly `preEncoderDims` floats (2,048 bytes), the size the loader checks.
    /// There is no weights marker: `scripts/models.lock` pins the weights version instead.
    public var nemotronInstalled: Bool {
        guard Self.isComplete(directory: nemotronDirectory, requiredFiles: Self.nemotronRequiredFiles) else { return false }
        let sil = nemotronDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
        let size = (try? FileManager.default.attributesOfItem(atPath: sil.path)[.size] as? NSNumber)?.intValue
        return size == Self.nemotronSilenceEmbeddingBytes
    }

    /// `learnable_sil_emb.bin`: `preEncoderDims` (512) Float32 values.
    static var nemotronSilenceEmbeddingBytes: Int { NemotronSeparation.config.preEncoderDims * MemoryLayout<Float>.size }

    /// Every model set is complete. Anything less means the app bundle is missing or damaged.
    public var allInstalled: Bool { asrInstalled && diarizerInstalled && nemotronInstalled }

    /// Bytes on disk for the speech (ASR) folder.
    public var speechBytesOnDisk: Int64 { Self.allocatedSize(of: asrDirectory) }

    /// Bytes on disk for the speaker models (community-1 and Nemotron 3 folders).
    public var speakersBytesOnDisk: Int64 { Self.allocatedSize(of: diarizerDirectory) + Self.allocatedSize(of: nemotronDirectory) }

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
