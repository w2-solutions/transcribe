@preconcurrency import CoreML
import FluidAudio
import Foundation
import TranscribeCore

/// NVIDIA Nemotron 3 Diarization (streaming Sortformer, up to 8 speakers) as the primary "who spoke when"
/// step (§5.10). It only decides speaker turns; voice vectors still come from WeSpeaker via `embedVoice`.
///
/// Mirrors macparakeet's `NativeNemotronDiarizationRunner` (PR #1318): 16 kHz samples are streamed from a
/// disk-backed source in 1 s feeds through `appendAudio` / `processBufferedAudio` / `finishStream` (frame-exact
/// with `processComplete`, but bounded memory and a cancellation check per feed), then
/// `Nemotron3Diarizer.segments(threshold: 0.5, minDurationSeconds: 0)`.
///
/// Same model as macparakeet's default: the fp16 monolithic `fast128` preset (190 MB; 10.24 s chunks; AMI DER 9.36 with
/// 16/16 speaker counts in Fluid Inference's BENCHMARKS.md, against 9.63 for the 95 MB `c128-split-w8a8`). One
/// difference: it runs on the CPU only (`computeUnits`, decided 2026-11-25), never the Neural Engine or the GPU. The
/// `offline` preset is never used: its graph fails the Neural Engine compile and silently runs on the GPU.
///
/// The weights ship in the app bundle, flat: `<dir>/<bundle>.mlmodelc` plus `<dir>/learnable_sil_emb.bin`, loaded with
/// `Nemotron3Models.load(config:directory:)`, which only reads. Never FluidAudio's Hugging Face loader: it deletes the folder
/// when its weights marker does not match and always writes a marker, and the bundle is read-only.
///
/// `Nemotron3Models` / `Nemotron3Diarizer` are not Sendable. Nothing here is stored: every job loads the models,
/// runs and releases them inside one `@concurrent` function, so nothing crosses an isolation boundary and the
/// ~190 MB of weights are not resident while Parakeet or WeSpeaker run.
enum NemotronSeparation {
    /// `Nemotron3Config.fast128`, spelled out so a preset change upstream is a test failure rather than a silent
    /// model swap. Shipped from the repo's `monolithic/v2/` (the fp16-I/O re-exports that compile for the ANE), flattened.
    static let presetName = "fast128"
    static let config = Nemotron3Config(
        chunkLen: 128, chunkRightContext: 4, fifoLen: 40, spkcacheUpdatePeriod: 40,
        modelFileName: "Nemotron3Diarizer_fast128.mlmodelc")

    /// Speaker channels the model has. A result using all of them may have merged extra people into them.
    static let speakerChannels = 8
    static let activityThreshold: Float = 0.5
    /// Samples per streaming feed (1 s at 16 kHz): a cancellation check between feeds.
    static let feedSamples = 16_000

    /// One stretch of activity on one speaker channel.
    struct Activity: Sendable, Equatable {
        var channel: Int
        var start: Double
        var end: Double
        /// Mean activity probability over the stretch (the segment's `quality`).
        var meanProbability: Float
    }

    enum FallbackReason: String, Sendable, Equatable {
        case notInstalled       // the Nemotron files are missing or damaged in this build
        case unavailable        // the model failed to load on this device earlier
        case failed             // load or inference threw
        case noSpeech           // no channel was active anywhere
        case saturated          // every channel was used: there may be more than 8 voices
    }

    enum Decision: Sendable {
        case use(SpeakerSeparation)
        case fallback(FallbackReason)
    }

    // MARK: Mapping and fallback rules (pure, tested)

    /// Channel activity → contract types, or why Community-1 should run instead.
    /// - Invalid stretches (non-finite, empty, unknown channel) are dropped.
    /// - No stretches left → `.noSpeech` (Community-1 then confirms "no speech" or finds what Nemotron missed).
    /// - All 8 channels used → `.saturated`.
    /// - Otherwise speakers are keyed "S1", "S2", … in order of first speech; segments sorted by start;
    ///   no centroids (voice vectors come from `embedVoice`).
    static func decide(_ activities: [Activity]) -> Decision {
        let valid = activities.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > Swift.max(0, $0.start)
                && (0..<speakerChannels).contains($0.channel)
        }
        guard !valid.isEmpty else { return .fallback(.noSpeech) }
        if Set(valid.map(\.channel)).count >= speakerChannels { return .fallback(.saturated) }
        let chronological = valid.sorted { ($0.start, $0.channel) < ($1.start, $1.channel) }
        var keys: [Int: SpeakerKey] = [:]
        var segments: [SpeakerSegment] = []
        for activity in chronological {
            let key: SpeakerKey
            if let existing = keys[activity.channel] {
                key = existing
            } else {
                key = "S\(keys.count + 1)"
                keys[activity.channel] = key
            }
            let quality = activity.meanProbability.isFinite ? Swift.min(1, Swift.max(0, activity.meanProbability)) : 0
            segments.append(SpeakerSegment(speakerKey: key, range: TimeRange(start: Swift.max(0, activity.start), end: activity.end),
                                           quality: quality))
        }
        segments.sort { ($0.range.start, $0.range.end, $0.speakerKey) < ($1.range.start, $1.range.end, $1.speakerKey) }
        return .use(SpeakerSeparation(segments: segments, centroids: [:], separator: .nemotron3))
    }

    /// Frame probabilities ([frames × channels], 10 ms frames) → activity stretches with their mean probability.
    static func activities(probabilities: [Float], frameCount: Int, channels: Int = speakerChannels,
                           threshold: Float = activityThreshold, frameSeconds: Float = 0.01) -> [Activity] {
        let frames = Swift.min(frameCount, probabilities.count / Swift.max(1, channels))
        guard frames > 0 else { return [] }
        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames, numSpeakers: channels,
                                          threshold: threshold, frameSeconds: frameSeconds, minDurationSeconds: 0)
            .map { segment in
                let first = Swift.max(0, Int((segment.startSeconds / frameSeconds).rounded()))
                let last = Swift.min(frames, Int((segment.endSeconds / frameSeconds).rounded()))
                var sum: Float = 0
                for frame in first..<Swift.max(first, last) { sum += probabilities[frame * channels + segment.speakerIndex] }
                let mean = last > first ? sum / Float(last - first) : 0
                return Activity(channel: segment.speakerIndex, start: Double(segment.startSeconds),
                                end: Double(segment.endSeconds), meanProbability: mean)
            }
    }

    // MARK: Models

    /// Loads the bundled preset once and releases it: the setup's check that Nemotron loads on this device (a
    /// failure there makes separation use community-1 for the process). On the CPU there is no Neural Engine compile
    /// to warm; the load takes about 1 s. Returns seconds.
    @concurrent
    static func warmUp(directory: URL) async throws -> TimeInterval {
        let start = Date()
        _ = try await Nemotron3Models.load(config: config, directory: directory, computeUnits: computeUnits)
        return Date().timeIntervalSince(start)
    }

    /// The CPU only (decided by Liam on 2026-11-25). On the Neural Engine its first load after every install compiled
    /// for 55–58 s on an iPhone 15 (A16), most of the whole setup; on the CPU the cold load is 0.89 s there (0.5–0.65 s
    /// against about 30 s on an M4 Max). Per 10.24 s chunk the CPU is slower (46 ms against 24 ms on the M4 Max), and
    /// the outputs agree within 0.0002 on random input. The CPU also needs no Background Inference entitlement in the
    /// background, and never the GPU, which iOS forbids there. Pinned by `presetIsTheFullPrecisionFast128Bundle`;
    /// `PrepareStage.usesNeuralEngine` must agree.
    static let computeUnits: MLComputeUnits = .cpuOnly

    // MARK: Inference

    /// Loads the models from the flat `directory`, streams the file through them and returns every channel's activity. The models are
    /// released when this returns. `progress` gets 0...1 (feeds done / total). Throws `CancellationError`.
    @concurrent
    static func run(audio: URL, directory: URL, config: Nemotron3Config = NemotronSeparation.config,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [Activity] {
        let models = try await Nemotron3Models.load(config: config, directory: directory, computeUnits: computeUnits)
        try Task.checkCancellation()
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: audio, targetSampleRate: feedSamples)
        defer { source.cleanup() }
        let sampleCount = source.sampleCount
        guard sampleCount > 0 else { return [] }
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        var probabilities: [Float] = []
        probabilities.reserveCapacity((sampleCount / 160 + 1) * speakerChannels)
        var frames = 0
        func append(_ chunks: [Nemotron3ChunkResult]) {
            for chunk in chunks {
                probabilities.append(contentsOf: chunk.probabilities)
                frames += chunk.frameCount
            }
        }
        let feeds = (sampleCount + feedSamples - 1) / feedSamples
        var feed = [Float](repeating: 0, count: feedSamples)
        for index in 0..<feeds {
            try Task.checkCancellation()
            let offset = index * feedSamples
            let count = Swift.min(feedSamples, sampleCount - offset)
            if feed.count != count { feed = [Float](repeating: 0, count: count) }
            try feed.withUnsafeMutableBufferPointer { buffer in
                try source.copySamples(into: buffer.baseAddress!, offset: offset, count: count)
            }
            diarizer.appendAudio(feed)
            append(try diarizer.processBufferedAudio())
            progress(0.98 * Double(index + 1) / Double(feeds))
        }
        try Task.checkCancellation()
        append(try diarizer.finishStream())
        progress(1)
        return activities(probabilities: probabilities, frameCount: frames)
    }
}
