import CoreML
import Darwin
import Foundation
import os
import TranscribeCore

/// One prepare, as one JSON line of `prepare-log.jsonl` in the app's Application Support folder (and a `key=value`
/// summary in the unified log, subsystem `ai.w2solutions.transcribe`, category `ModelPrep`, because the unified log
/// cuts messages at 1 KB). It holds timings and app state only, never user data.
///
/// Fields added later must be optional, so older lines still decode.
struct PrepareRecord: Codable, Sendable, Equatable {
    struct Stage: Codable, Sendable, Equatable {
        /// asr | diarizer | warmup | nemotron
        var name: String
        /// ISO 8601 with fractional seconds.
        var start: String
        var end: String
        var seconds: Double
        /// Set when the stage threw (or, for nemotron, failed and was disabled for this process).
        var error: String?
        /// Whether the app was in the background when the stage started and when it ended, and whether it went to
        /// the background in between (`AppActivity`).
        var bgAtStart: Bool?
        var bgAtEnd: Bool?
        var epochChanged: Bool?
        /// What became of the stage (`StageVerdict`): kept | primed | droppedBackground | paused | failed | notStarted.
        var verdict: String?
        /// The part of `seconds` the app spent suspended (from the system ending the short background task to the
        /// next return to the front), so a stage that spanned a suspension is not read as slow.
        var suspendedSeconds: Double?
        /// Whether Core ML listed a Neural Engine among the available compute devices at the stage's start and end.
        var aneAtStart: Bool?
        var aneAtEnd: Bool?
        /// Whether the prepare's plan expected this stage warm (its compile already cached), written when it ran. A
        /// stage expected warm is never a cold sample (`PrepareEstimates`), even once the history before it has been
        /// trimmed. Older lines have none.
        var expectedWarm: Bool?
    }

    /// One app transition during the prepare (`AppActivity.Transition`, with an ISO 8601 time).
    struct Transition: Codable, Sendable, Equatable {
        /// background | active | expired
        var kind: String
        var at: String
    }

    var at: String
    var appVersion: String?
    var appBuild: String?
    /// `kern.osversion`, e.g. "24A335".
    var osBuild: String?
    var stages: [Stage]
    var totalSeconds: Double
    var nemotronWarmUpOK: Bool?
    /// ready | paused | failed. A pause is not a failure: the app went to the background, and the next prepare
    /// (on return) finishes the job, warm for every stage whose compile finished.
    var outcome: String
    var error: String?
    /// Why a paused prepare stopped (`PreparePauseReason`): startRefused | returnedInBackground | failedInBackground |
    /// primedInBackground.
    var pauseReason: String?
    /// The `AppActivity.backgroundInference` the rules used (the build carries the Background Inference entitlement).
    var backgroundInference: Bool?
    /// The app's transitions while this prepare ran.
    var transitions: [Transition]?
    /// An earlier prepare in this process paused.
    var resumesPause: Bool?
    /// The outcome is ready and the app was in the background when it ended.
    var readyInBackground: Bool?
    /// Low Power Mode was on at the start.
    var lowPower: Bool?
    /// Which install of the app ran this prepare: the build number plus the executable's modification date
    /// (`PrepareLog.installStamp()`). It changes with every install or update, after which iOS compiles the models
    /// again; on Debug builds the build number alone often does not change. Older lines have none.
    var installStamp: String?
    /// The compute units Nemotron 3 was loaded with (`NemotronSeparation.computeUnits`): "cpuOnly" since
    /// 2026-11-25; lines from the earlier Neural Engine builds say "cpuAndNeuralEngine" (a 55–58 s compile on an
    /// iPhone 15). Its timings are only comparable under the same value, so those lines are never used for today's
    /// estimate. Older lines have none.
    var nemotronUnits: String?
    /// The hardware model (`PrepareLog.hardwareModel()`, e.g. "iPhone15,4"), so timings restored from another
    /// device's backup are not read as this one's. Older lines have none.
    var hwModel: String?

    /// A record for a prepare starting now.
    static func begin(at date: Date = Date()) -> PrepareRecord {
        PrepareRecord(at: PrepareLog.iso(date), appVersion: PrepareLog.appVersion, appBuild: PrepareLog.appBuild,
                      osBuild: PrepareLog.osBuild(), stages: [], totalSeconds: 0, nemotronWarmUpOK: nil,
                      outcome: "failed", error: nil, pauseReason: nil, backgroundInference: nil, transitions: nil,
                      resumesPause: nil, readyInBackground: nil, lowPower: nil,
                      installStamp: PrepareLog.installStamp(),
                      nemotronUnits: PrepareEstimates.unitsName(NemotronSeparation.computeUnits),
                      hwModel: PrepareLog.hardwareModel())
    }

    mutating func addStage(_ name: String, start: Date, end: Date, error: String? = nil) {
        stages.append(Stage(name: name, start: PrepareLog.iso(start), end: PrepareLog.iso(end),
                            seconds: end.timeIntervalSince(start), error: error))
    }

    /// Adds the background facts to the stage just added.
    mutating func noteLastStage(bgAtStart: Bool, bgAtEnd: Bool, epochChanged: Bool, verdict: StageVerdict,
                                suspendedSeconds: Double?, aneAtStart: Bool?, aneAtEnd: Bool?,
                                expectedWarm: Bool? = nil) {
        guard !stages.isEmpty else { return }
        stages[stages.count - 1].expectedWarm = expectedWarm
        stages[stages.count - 1].bgAtStart = bgAtStart
        stages[stages.count - 1].bgAtEnd = bgAtEnd
        stages[stages.count - 1].epochChanged = epochChanged
        stages[stages.count - 1].verdict = verdict.rawValue
        stages[stages.count - 1].suspendedSeconds = suspendedSeconds
        stages[stages.count - 1].aneAtStart = aneAtStart
        stages[stages.count - 1].aneAtEnd = aneAtEnd
    }

    /// A stage the start rule refused: no time, no work.
    mutating func addRefusedStage(_ name: String, at date: Date, inBackground: Bool) {
        addStage(name, start: date, end: date)
        stages[stages.count - 1].bgAtStart = inBackground
        stages[stages.count - 1].bgAtEnd = inBackground
        stages[stages.count - 1].verdict = StageVerdict.notStarted.rawValue
    }

    mutating func noteTransitions(_ list: [AppActivity.Transition]) {
        transitions = list.map { Transition(kind: $0.kind.rawValue, at: PrepareLog.iso($0.at)) }
    }
}

/// What became of one prepare stage (`PrepareRecord.Stage.verdict`).
enum StageVerdict: String, Sendable, Codable {
    /// Returned and its models are used: it ran wholly in front, or it is the CPU-only stage (nemotron), or (with
    /// Background Inference) it touched the background with the Neural Engine listed at its start and end
    /// (`bgAtStart`/`bgAtEnd` tell which).
    case kept
    /// With Background Inference: returned after touching the background, but Core ML did not list the Neural
    /// Engine at its start or end. Its compile is cached; its models are released and loaded again (warm) in front,
    /// so a model that may have loaded for the CPU is never kept.
    case primed
    /// Without Background Inference, a Neural Engine stage returned after a trip to the background. Released; the
    /// prepare pauses.
    case droppedBackground
    /// Threw, but not wholly in front: not a failure. The prepare pauses.
    case paused
    /// Threw wholly in front: a real failure (or, for nemotron, Nemotron is disabled for the process).
    case failed
    /// The start rule refused it (a Neural Engine stage in the background without the entitlement, or any stage
    /// after the short task expired).
    case notStarted
}

/// Why a prepare paused (`PrepareRecord.pauseReason`).
enum PreparePauseReason: String, Sendable, Codable {
    /// A stage was due to start in the background and the start rule refused it.
    case startRefused
    /// Without Background Inference, a Neural Engine stage returned after a trip to the background.
    case returnedInBackground
    /// A stage threw after a trip to the background.
    case failedInBackground
    /// With Background Inference, every stage ran but at least one only primed (no Neural Engine listed).
    case primedInBackground
}

/// Writes `PrepareRecord`s and reads the facts they hold.
enum PrepareLog {
    /// Lines kept in the file; older ones are dropped.
    static let keptLines = 200

    static let logger = Logger(subsystem: "ai.w2solutions.transcribe", category: "ModelPrep")

    /// One line of JSON with sorted keys.
    static func line(_ record: PrepareRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The unified log cuts a message at 1,024 bytes, and the JSON line is longer than that. So the unified log gets
    /// this summary instead: every number the device checks compare, as `key=value` with no ISO times, kept under
    /// `summaryLimit` bytes (the error keeps its first part).
    static func summary(_ r: PrepareRecord) -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            guard text.utf8.count > limit else { return text }
            var chars = Array(text)
            // "…" is 3 bytes in UTF-8.
            while !chars.isEmpty, String(chars).utf8.count > limit - 3 { chars.removeLast() }
            return String(chars) + "…"
        }
        func s(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
        var parts = ["outcome=\(r.outcome)"]
        if let reason = r.pauseReason { parts.append("pause=\(reason)") }
        parts.append("ver=\(r.appVersion ?? "-")")
        parts.append("build=\(r.appBuild ?? "-")")
        parts.append("os=\(r.osBuild ?? "-")")
        for stage in r.stages.prefix(12) {
            let verdict = stage.verdict.flatMap(StageVerdict.init(rawValue:)).map { "/\(Self.code($0))" } ?? ""
            let background = stage.bgAtStart == true || stage.bgAtEnd == true ? "^" : ""
            parts.append("\(stage.name)=\(s(stage.seconds))\(stage.error == nil ? "" : "!")\(verdict)\(background)")
        }
        parts.append("total=\(s(r.totalSeconds))")
        if let ok = r.nemotronWarmUpOK { parts.append("nemoOK=\(ok ? 1 : 0)") }
        if let bi = r.backgroundInference { parts.append("bi=\(bi ? 1 : 0)") }
        if let transitions = r.transitions, !transitions.isEmpty {
            parts.append("tr=\(transitions.prefix(8).map { String($0.kind.prefix(1)) }.joined())")
        }
        if r.resumesPause == true { parts.append("resumes=1") }
        if r.readyInBackground == true { parts.append("readyBg=1") }
        if r.lowPower == true { parts.append("lowPower=1") }
        if let units = r.nemotronUnits { parts.append("units=\(units)") }
        if let error = r.error { parts.append("error=\(clip(error, 200))") }
        return clip("prepare " + parts.joined(separator: " "), summaryLimit)
    }

    /// One letter per verdict in the summary (`asr=12.30/k`; `^` marks a stage that touched the background).
    static func code(_ verdict: StageVerdict) -> String {
        switch verdict {
        case .kept: "k"
        case .primed: "p"
        case .droppedBackground: "d"
        case .paused: "z"
        case .failed: "f"
        case .notStarted: "n"
        }
    }

    /// Whether Core ML lists a Neural Engine among the compute devices it can use now (a cheap probe, logged only).
    static func neuralEngineAvailable() -> Bool {
        MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
    }

    /// Seconds of `start...end` the app spent suspended: the overlap with each interval from an `expired` transition
    /// to the next `active` one (or to `end` when there is none yet).
    static func suspendedSeconds(start: Date, end: Date, transitions: [AppActivity.Transition]) -> Double {
        var total = 0.0
        var frozenSince: Date?
        func add(_ from: Date, _ to: Date) {
            let lower = max(from, start), upper = min(to, end)
            if upper > lower { total += upper.timeIntervalSince(lower) }
        }
        for t in transitions {
            switch t.kind {
            case .expired: if frozenSince == nil { frozenSince = t.at }
            case .active:
                if let since = frozenSince { add(since, t.at) }
                frozenSince = nil
            case .background: break
            }
        }
        if let since = frozenSince { add(since, end) }
        return total
    }

    /// Well under the unified log's 1,024-byte cut.
    static let summaryLimit = 960

    /// Logs a summary of the record (`.notice`, so `log collect` keeps it) and appends the full JSON to `file`,
    /// keeping the last 200 lines. The file is written only inside a folder that already exists (it never creates
    /// one); with no file, or no such folder, the record is only logged. The file is left out of backups (its
    /// timings belong to this device and this install), set again after every write since an atomic write replaces
    /// the file.
    static func append(_ record: PrepareRecord, to file: URL?) {
        logger.notice("\(summary(record), privacy: .public)")
        guard let json = line(record) else { return }
        guard let file, (try? file.deletingLastPathComponent().checkResourceIsReachable()) == true else { return }
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(json)
        if lines.count > keptLines { lines.removeFirst(lines.count - keptLines) }
        do {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
            excludeFromBackup(file)
        } catch {
            logger.error("Could not write \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks `file` as excluded from iCloud and device backups.
    static func excludeFromBackup(_ file: URL) {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Every record in a log file, oldest first (lines that do not decode are skipped).
    static func read(_ file: URL) -> [PrepareRecord] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(PrepareRecord.self, from: Data($0.utf8)) }
    }

    // MARK: Facts

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The hardware model: `hw.machine` on iPhone ("iPhone15,4"), `hw.model` on the Mac ("Mac14,2").
    static func hardwareModel() -> String? {
        #if os(macOS)
        sysctlString("hw.model")
        #else
        sysctlString("hw.machine")
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// `sysctl kern.osversion`, the OS build.
    static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var appVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// This install of the app: "<build>@<executable modification time, whole seconds>". iOS compiles the bundled
    /// models again after every install or update, and a new install always writes a new executable.
    static func installStamp(executable: URL? = Bundle.main.executableURL, build: String? = appBuild) -> String? {
        guard let executable,
              let modified = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return "\(build ?? "-")@\(Int(modified.timeIntervalSince1970))"
    }
    static var appBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
}
