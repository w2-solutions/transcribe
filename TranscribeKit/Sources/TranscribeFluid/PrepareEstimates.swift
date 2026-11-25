import CoreML
import Foundation
import TranscribeCore

/// How long each prepare stage is expected to take, for the setup progress the app shows (`PreparePlan`). Pure: it
/// reads earlier `PrepareRecord`s and this process's state, nothing else.
///
/// - A cold sample is the first attempt of a stage under one install of the app and one OS build
///   (`installStamp`, `osBuild`): the attempt that paid for the compile. It counts only when it ran cleanly in
///   front: kept, never in the background, no trip away, no suspended time, no error. Nemotron's also needs the
///   compute units it ran with to match today's (`NemotronSeparation.computeUnits`); a record without them is never
///   trusted for Nemotron. Refused stages (`notStarted`) did no work and are not attempts.
/// - The log keeps only its last 200 lines, so the true first attempt may have been trimmed away. Each stage
///   therefore also records whether its plan expected it warm (`expectedWarm`, written when it ran): a stage
///   expected warm is never a cold sample, whatever is left of the history. Older lines have no such field and rely
///   on the first-attempt rule alone.
/// - Records from other hardware (`hwModel`, e.g. a backup restored to a newer iPhone) are ignored; records
///   without a hardware model (older lines) still count.
/// - A stage's estimate is the most recent cold sample on the current OS build; otherwise a built-in number.
/// - A stage whose compile already finished (in this process, or kept earlier under this same install and OS build)
///   is warm.
/// - `timesFromThisDevice` is true only when every step still to run is measured here or warm. Built-in numbers
///   move the bar but never produce a time-left line.
enum PrepareEstimates {
    /// Built-in cold numbers. iPhone: measured on an iPhone 15 on 2026-11-25 (asr 18.8–23 s, diarizer 1–2 s, warm-up
    /// 0.06–0.25 s, Nemotron 0.89 s on the CPU). Mac: a cold prepare on a fresh model path on an M4 Max in the gated
    /// tests (FluidEngineTests 14, 2026-11-25): diarizer 0.66 s, Nemotron 0.51 s, Parakeet 13.4 s; the warm-up is a
    /// guess. Slower Macs and the app's own setup on a Mac are unmeasured, so the Mac numbers round up. Nemotron
    /// always runs on the CPU (`NemotronSeparation.computeUnits` is a constant), so there is no Neural Engine figure
    /// for it.
    static func coldDefaults(isPhone: Bool) -> [PrepareStage: Double] {
        if isPhone {
            return [.diarizer: 1.5, .nemotron: 1.5, .asr: 20, .warmup: 0.25]
        }
        return [.diarizer: 0.7, .nemotron: 0.6, .asr: 14, .warmup: 0.1]
    }

    /// A stage whose compile is already cached (Nemotron has none on the CPU: its load is about as long as cold;
    /// 2.1 s measured on an iPhone 15 back from the background).
    static let warmDefaults: [PrepareStage: Double] = [.diarizer: 0.5, .nemotron: 2, .asr: 1, .warmup: 0.25]

    /// Whether this build runs on an iPhone (the built-in numbers differ).
    static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The name a record keeps for a compute-units value.
    static func unitsName(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "other(\(units.rawValue))"
        }
    }

    struct Sample: Equatable {
        var stage: PrepareStage
        var osBuild: String
        var installStamp: String
        var seconds: Double
    }

    /// Whether a record was written on this hardware (a record without a hardware model is taken as this one).
    static func sameHardware(_ record: PrepareRecord, _ hwModel: String?) -> Bool {
        guard let recorded = record.hwModel, let hwModel else { return true }
        return recorded == hwModel
    }

    /// Every cold sample in `records` (oldest first), as defined in the type doc.
    static func coldSamples(_ records: [PrepareRecord], nemotronUnits: String, hwModel: String? = nil) -> [Sample] {
        var attempted = Set<String>()
        var samples: [Sample] = []
        for record in records where sameHardware(record, hwModel) {
            guard let install = record.installStamp, let os = record.osBuild else { continue }
            for entry in record.stages {
                guard let stage = PrepareStage(rawValue: entry.name),
                      entry.verdict != StageVerdict.notStarted.rawValue else { continue }
                let key = "\(install)|\(os)|\(stage.rawValue)"
                guard attempted.insert(key).inserted else { continue }   // not the first attempt
                guard entry.expectedWarm != true else { continue }          // its compile was already cached
                guard isClean(entry) else { continue }
                if stage == .nemotron, record.nemotronUnits != nemotronUnits { continue }
                samples.append(Sample(stage: stage, osBuild: os, installStamp: install, seconds: entry.seconds))
            }
        }
        return samples
    }

    /// Ran wholly in front, was kept, threw nothing and spent no time suspended.
    static func isClean(_ entry: PrepareRecord.Stage) -> Bool {
        entry.verdict == StageVerdict.kept.rawValue && entry.bgAtStart == false && entry.bgAtEnd == false
            && entry.epochChanged != true && (entry.suspendedSeconds ?? 0) == 0 && entry.error == nil
    }

    /// The stages kept earlier under this install and OS build: their compile is cached, so they load warm.
    static func keptUnder(_ records: [PrepareRecord], installStamp: String?, osBuild: String?,
                          nemotronUnits: String, hwModel: String? = nil) -> Set<PrepareStage> {
        guard let installStamp, let osBuild else { return [] }
        var kept = Set<PrepareStage>()
        for record in records where record.installStamp == installStamp && record.osBuild == osBuild
            && sameHardware(record, hwModel) {
            for entry in record.stages where entry.verdict == StageVerdict.kept.rawValue && entry.error == nil {
                guard let stage = PrepareStage(rawValue: entry.name) else { continue }
                if stage == .nemotron, record.nemotronUnits != nemotronUnits { continue }
                kept.insert(stage)
            }
        }
        return kept
    }

    /// The plan for a prepare starting now.
    /// - Parameters:
    ///   - compiled: stages whose work returned earlier in this process (warm now).
    ///   - diarizerDone / nemotronDone: kept earlier in this process (the prepare skips them).
    ///   - includeNemotron: Nemotron is installed and not disabled for this process.
    ///   - hwModel: this device's hardware model (`PrepareLog.hardwareModel()`); nil matches every record.
    static func plan(records: [PrepareRecord], osBuild: String?, installStamp: String?, nemotronUnits: String,
                     hwModel: String? = nil, isPhone: Bool = Self.isPhone, compiled: Set<PrepareStage>,
                     diarizerDone: Bool, nemotronDone: Bool, includeNemotron: Bool) -> PreparePlan {
        let cold = coldDefaults(isPhone: isPhone)
        let samples = coldSamples(records, nemotronUnits: nemotronUnits, hwModel: hwModel)
            .filter { $0.osBuild == osBuild && osBuild != nil }
        let warmHere = compiled.union(keptUnder(records, installStamp: installStamp, osBuild: osBuild,
                                                nemotronUnits: nemotronUnits, hwModel: hwModel))
        let stages = PrepareStage.allCases.filter { $0 != .nemotron || includeNemotron }
        var fromDevice = true
        let steps = stages.map { stage -> PreparePlan.Step in
            let done = (stage == .diarizer && diarizerDone) || (stage == .nemotron && nemotronDone)
            if done { return PreparePlan.Step(stage: stage, expectedSeconds: 0, isDone: true) }
            if warmHere.contains(stage) {
                return PreparePlan.Step(stage: stage, expectedSeconds: warmDefaults[stage] ?? 1, isWarm: true)
            }
            if let sample = samples.last(where: { $0.stage == stage }) {
                return PreparePlan.Step(stage: stage, expectedSeconds: Swift.max(0.05, sample.seconds))
            }
            fromDevice = false
            return PreparePlan.Step(stage: stage, expectedSeconds: cold[stage] ?? 1)
        }
        return PreparePlan(steps: steps, timesFromThisDevice: fromDevice)
    }
}
