import Foundation

/// The constants of `SourceAttribution` (Mac audio, 2026-11-26). Every value is an untested starting point, chosen
/// before any real call was recorded: tune them from the matching log (`systemShare` in each speaker's trace and the
/// policy block), never per person.
public struct SourceAttributionPolicy: Sendable, Equatable, Codable {
    /// Length of one level frame.
    public var frameSeconds: Double = 0.020
    /// A frame at or below this level (dBFS) is silence on the system stream.
    public var silenceFloorDB: Float = -55
    /// The reference level is this percentile of the frames above the silence floor (the far side's speech level).
    public var referencePercentile: Double = 0.90
    /// A frame is system speech when it is no more than this many dB below the reference (and above the floor), so
    /// line noise from the far side is not counted as speech.
    public var relativeFloorDB: Float = 20
    /// Fewer frames than this above the floor: the system stream is silent and every speaker is on the microphone.
    public var minActiveFrames = 100
    /// A speaker whose clean speech is at least this share system speech was heard through Mac audio...
    public var systemShareMin: Float = 0.80
    /// ...and at most this share, on the microphone. Anything between is mixed.
    public var micShareMax: Float = 0.20
    /// Under this much clean speech a speaker is mixed: too little to say which stream it was on.
    public var minCleanSeconds: Double = 3.0
    /// A stem covering less than this share of a speaker's clean speech frames (a truncated stem) makes it mixed.
    public var minStemCoverage: Double = 0.5

    public init() {}
    public static let `default` = SourceAttributionPolicy()
}

/// Which stream each speaker of a recording that captured the microphone and Mac audio was heard on (decision D1),
/// from the level of the system stem over the speaker's clean speech. Pure: it never reads a file except through
/// `levels(ofWAV:)`. Echo of the far side picked up by the microphone does not matter: only the system stem is read.
///
/// 1. The system stem is cut into 20 ms frames; each frame's RMS level in dBFS.
/// 2. `reference` = the 90th percentile of the frames above −55 dBFS. With fewer than 100 such frames the stream is
///    silent, and every speaker is `mic`.
/// 3. A frame is system speech when its level is at least `max(−55, reference − 20)`.
/// 4. A speaker's `share` = system-speech frames ÷ the frames of its clean spans that the stem covers (a frame
///    belongs to a span when its centre lies in it). `share ≥ 0.80` → `system`, `share ≤ 0.20` → `mic`, otherwise
///    `mixed`; also `mixed` under 3.0 s of clean speech, or when the stem covers under half of the span frames.
public enum SourceAttribution {
    /// The level of every frame of a stream, in dBFS (silence is −200).
    public struct Levels: Sendable, Equatable {
        public var frameSeconds: Double
        public var dbfs: [Float]
        public init(frameSeconds: Double, dbfs: [Float]) { self.frameSeconds = frameSeconds; self.dbfs = dbfs }
        public var duration: Double { Double(dbfs.count) * frameSeconds }
    }

    /// What the stream as a whole says, before any speaker.
    public struct Analysis: Sendable, Equatable {
        /// Frames above the silence floor.
        public var activeFrames: Int
        /// Fewer active frames than `minActiveFrames`: every speaker is on the microphone.
        public var silent: Bool
        /// The reference level (dBFS); nil when silent.
        public var reference: Float?
        /// The system-speech threshold (dBFS); nil when silent.
        public var threshold: Float?
    }

    /// Why a speaker got its source, for the log.
    public enum Reason: String, Sendable, Codable, Equatable {
        case silentStream, truncatedStem, shortSpeech, share
    }

    public struct Result: Sendable, Equatable {
        public var source: SpeakerSource
        /// System-speech frames ÷ covered span frames; nil when the stream is silent or nothing is covered.
        public var share: Float?
        public var cleanSeconds: Double
        public var reason: Reason
        public init(source: SpeakerSource, share: Float?, cleanSeconds: Double, reason: Reason) {
            self.source = source; self.share = share; self.cleanSeconds = cleanSeconds; self.reason = reason
        }
    }

    static let silenceDB: Float = -200

    // MARK: Levels

    /// Frame levels of mono samples (any channel count would have been mixed down by the caller).
    public static func levels(samples: [Float], sampleRate: Int, policy: SourceAttributionPolicy = .default) -> Levels {
        let frame = Swift.max(1, Int((policy.frameSeconds * Double(sampleRate)).rounded()))
        var out: [Float] = []
        out.reserveCapacity(samples.count / frame + 1)
        var i = 0
        while i < samples.count {
            let end = Swift.min(samples.count, i + frame)
            var sum: Double = 0
            for k in i..<end { sum += Double(samples[k]) * Double(samples[k]) }
            out.append(dbfs(meanSquare: sum / Double(end - i)))
            i = end
        }
        return Levels(frameSeconds: Double(frame) / Double(sampleRate), dbfs: out)
    }

    /// Frame levels of a 16-bit PCM WAV (the stems are 16 kHz mono), streamed in chunks; with several channels the
    /// first channel is read.
    public static func levels(ofWAV url: URL, policy: SourceAttributionPolicy = .default) throws -> Levels {
        let info = try WAVHeaderInfo.read(url)
        let frame = Swift.max(1, Int((policy.frameSeconds * Double(info.sampleRate)).rounded()))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(info.dataOffset))
        var out: [Float] = []
        out.reserveCapacity(info.frameCount / frame + 1)
        var sum: Double = 0, count = 0
        var remaining = info.frameCount
        let chunkFrames = frame * 512
        while remaining > 0 {
            let want = Swift.min(chunkFrames, remaining)
            guard let data = try handle.read(upToCount: want * info.blockAlign), !data.isEmpty else { break }
            let got = data.count / info.blockAlign
            data.withUnsafeBytes { raw in
                for f in 0..<got {
                    let o = f * info.blockAlign
                    let v = Double(Int16(bitPattern: UInt16(raw[o]) | UInt16(raw[o + 1]) << 8)) / 32768
                    sum += v * v
                    count += 1
                    if count == frame {
                        out.append(dbfs(meanSquare: sum / Double(count)))
                        sum = 0; count = 0
                    }
                }
            }
            remaining -= got
            if got < want { break }
        }
        if count > 0 { out.append(dbfs(meanSquare: sum / Double(count))) }
        return Levels(frameSeconds: Double(frame) / Double(info.sampleRate), dbfs: out)
    }

    static func dbfs(meanSquare: Double) -> Float {
        guard meanSquare > 0 else { return silenceDB }
        return Swift.max(silenceDB, Float(10 * log10(meanSquare)))
    }

    // MARK: Analysis

    public static func analyse(_ levels: Levels, policy: SourceAttributionPolicy = .default) -> Analysis {
        let active = levels.dbfs.filter { $0 > policy.silenceFloorDB }.sorted()
        guard active.count >= Swift.max(1, policy.minActiveFrames) else {
            return Analysis(activeFrames: active.count, silent: true, reference: nil, threshold: nil)
        }
        let p = Swift.min(1, Swift.max(0, policy.referencePercentile))
        let reference = active[Int((Double(active.count - 1) * p).rounded(.down))]
        let threshold = Swift.max(policy.silenceFloorDB, reference - policy.relativeFloorDB)
        return Analysis(activeFrames: active.count, silent: false, reference: reference, threshold: threshold)
    }

    // MARK: Attribution

    /// The source of one speaker from its clean spans.
    public static func attribute(spans: [TimeRange], levels: Levels, analysis: Analysis,
                                 policy: SourceAttributionPolicy = .default) -> Result {
        let clean = spans.reduce(0) { $0 + $1.duration }
        guard !analysis.silent, let threshold = analysis.threshold else {
            return Result(source: .mic, share: nil, cleanSeconds: clean, reason: .silentStream)
        }
        let f = levels.frameSeconds
        var total = 0, covered = 0, system = 0
        var seen = Set<Int>()
        for span in spans where span.duration > 0 {
            // Frames whose centre lies in [start, end).
            var i = Swift.max(0, Int((span.start / f - 0.5).rounded(.up)))
            while (Double(i) + 0.5) * f < span.end {
                if (Double(i) + 0.5) * f >= span.start, seen.insert(i).inserted {
                    total += 1
                    if i < levels.dbfs.count {
                        covered += 1
                        if levels.dbfs[i] >= threshold { system += 1 }
                    }
                }
                i += 1
            }
        }
        let share: Float? = covered > 0 ? Float(system) / Float(covered) : nil
        if total == 0 || Double(covered) < policy.minStemCoverage * Double(total) {
            return Result(source: .mixed, share: share, cleanSeconds: clean, reason: .truncatedStem)
        }
        if clean < policy.minCleanSeconds {
            return Result(source: .mixed, share: share, cleanSeconds: clean, reason: .shortSpeech)
        }
        let s = share ?? 0
        let source: SpeakerSource = s >= policy.systemShareMin ? .system : (s <= policy.micShareMax ? .mic : .mixed)
        return Result(source: source, share: share, cleanSeconds: clean, reason: .share)
    }

    /// Every speaker's source from one system stem.
    public static func attribute(speakers: [SpeakerKey: [TimeRange]], levels: Levels,
                                 policy: SourceAttributionPolicy = .default) -> [SpeakerKey: Result] {
        let analysis = analyse(levels, policy: policy)
        return speakers.mapValues { attribute(spans: $0, levels: levels, analysis: analysis, policy: policy) }
    }

    /// The share rounded to two places, as traces and the log keep it.
    public static func rounded(_ share: Float?) -> Float? {
        share.map { ($0 * 100).rounded() / 100 }
    }
}
