import CoreML
import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// Where the setup progress gets its expected seconds (`PrepareEstimates`).
@Suite("PrepareEstimates")
struct PrepareEstimatesTests {
    /// Today's Nemotron units (`NemotronSeparation.computeUnits`), and the Neural Engine units of the builds before
    /// 2026-11-25, whose lines are still in the log on the phone.
    static let cpu = "cpuOnly"
    static let ane = "cpuAndNeuralEngine"

    /// A clean stage in front, kept.
    static func clean(_ name: String, _ seconds: Double) -> PrepareRecord.Stage {
        PrepareRecord.Stage(name: name, start: "", end: "", seconds: seconds, error: nil, bgAtStart: false,
                            bgAtEnd: false, epochChanged: false, verdict: "kept", suspendedSeconds: 0,
                            aneAtStart: true, aneAtEnd: true)
    }

    static func record(install: String?, os: String? = "24B156", units: String? = cpu,
                       _ stages: [PrepareRecord.Stage]) -> PrepareRecord {
        var r = PrepareRecord.begin()
        r.installStamp = install
        r.osBuild = os
        r.nemotronUnits = units
        r.stages = stages
        r.outcome = "ready"
        return r
    }

    /// A clean cold prepare, in run order.
    static func cold(_ install: String, os: String = "24B156", units: String? = cpu,
                     asr: Double, warmup: Double = 0.2, diarizer: Double = 1.4, nemotron: Double = 0.9) -> PrepareRecord {
        record(install: install, os: os, units: units, [clean("diarizer", diarizer), clean("nemotron", nemotron),
                                                         clean("asr", asr), clean("warmup", warmup)])
    }

    /// The index of a stage in a record made by `cold`.
    static func index(_ name: String, _ record: PrepareRecord) -> Int {
        record.stages.firstIndex { $0.name == name } ?? 0
    }

    static func plan(_ records: [PrepareRecord], os: String? = "24B156", install: String? = "9300@3",
                     units: String = cpu, isPhone: Bool = true, compiled: Set<PrepareStage> = [],
                     diarizerDone: Bool = false, nemotronDone: Bool = false,
                     includeNemotron: Bool = true) -> PreparePlan {
        PrepareEstimates.plan(records: records, osBuild: os, installStamp: install, nemotronUnits: units,
                              isPhone: isPhone, compiled: compiled, diarizerDone: diarizerDone,
                              nemotronDone: nemotronDone, includeNemotron: includeNemotron)
    }

    /// Seconds per step, in plan order (diarizer, nemotron, asr, warmup).
    static func seconds(_ plan: PreparePlan) -> [Double] { plan.steps.map(\.expectedSeconds) }

    @Test func thePlanRunsTheShortStagesFirst() {
        #expect(Self.plan([]).steps.map(\.stage) == [.diarizer, .nemotron, .asr, .warmup])
    }

    @Test func theColdSampleIsTheFirstAttemptPerInstallAndOSBuild() {
        let first = Self.cold("9200@1", asr: 21)
        let relaunch = Self.cold("9200@1", asr: 0.6, nemotron: 1.5)   // same install: warm, not a sample
        let samples = PrepareEstimates.coldSamples([first, relaunch], nemotronUnits: Self.cpu)
        #expect(samples.filter { $0.stage == .asr }.map(\.seconds) == [21])
        let plan = Self.plan([first, relaunch])
        #expect(Self.seconds(plan) == [1.4, 0.9, 21, 0.2])
        #expect(plan.timesFromThisDevice)
    }

    @Test func anInterruptedFirstAttemptGivesNoSampleSoAnEarlierInstallIsUsed() {
        let older = Self.cold("9100@1", asr: 20)
        var touched = Self.cold("9200@2", asr: 30)
        let asr = Self.index("asr", touched)
        touched.stages[asr].bgAtEnd = true   // the first attempt touched the background
        touched.stages[asr].epochChanged = true
        let retry = Self.cold("9200@2", asr: 1)   // the next prepare of that install is warm: not a sample
        var primed = Self.cold("9250@2", asr: 25)
        primed.stages[asr].verdict = "primed"
        let plan = Self.plan([older, touched, retry, primed], install: "9300@3")
        #expect(plan.step(.asr)?.expectedSeconds == 20)
        #expect(plan.timesFromThisDevice)
    }

    /// The log keeps 200 lines, so an install's real cold first attempt can be trimmed away. Its warm relaunches
    /// recorded that they were expected warm, so none of them becomes the "cold" sample.
    @Test func aTrimmedHistoryNeverTurnsAWarmRelaunchIntoAColdSample() {
        func warm(_ record: PrepareRecord) -> PrepareRecord {
            var r = record
            for i in r.stages.indices { r.stages[i].expectedWarm = true }
            return r
        }
        let relaunches = (0..<3).map { _ in warm(Self.cold("9200@1", asr: 0.5, diarizer: 0.4, nemotron: 2)) }
        #expect(PrepareEstimates.coldSamples(relaunches, nemotronUnits: Self.cpu).isEmpty)
        let plan = Self.plan(relaunches, install: "9300@3")
        #expect(Self.seconds(plan) == [1.5, 1.5, 20, 0.25], "built-in numbers, not the warm relaunch's")
        #expect(!plan.timesFromThisDevice)
        #expect(plan.steps.allSatisfy { !$0.isWarm })

        // A first attempt recorded as cold still counts.
        var first = Self.cold("9200@1", asr: 21)
        for i in first.stages.indices { first.stages[i].expectedWarm = false }
        #expect(Self.plan([first] + relaunches, install: "9300@3").step(.asr)?.expectedSeconds == 21)
    }

    /// Timings from other hardware (a backup restored to a newer iPhone) are never this device's.
    @Test func recordsFromOtherHardwareAreIgnored() {
        var other = Self.cold("9200@1", asr: 21)
        other.hwModel = "iPhone15,4"
        var unknown = Self.cold("9100@1", asr: 19)
        unknown.hwModel = nil   // an older line: still counts
        let records = [unknown, other]
        let plan = PrepareEstimates.plan(records: records, osBuild: "24B156", installStamp: "9200@1",
                                         nemotronUnits: Self.cpu, hwModel: "iPhone17,1", isPhone: true,
                                         compiled: [], diarizerDone: false, nemotronDone: false,
                                         includeNemotron: true)
        #expect(plan.step(.asr)?.expectedSeconds == 19, "the other phone's sample is skipped")
        #expect(plan.steps.allSatisfy { !$0.isWarm }, "its kept stages say nothing about this device's cache")
        let same = PrepareEstimates.plan(records: records, osBuild: "24B156", installStamp: "9200@1",
                                         nemotronUnits: Self.cpu, hwModel: "iPhone15,4", isPhone: true,
                                         compiled: [], diarizerDone: false, nemotronDone: false,
                                         includeNemotron: true)
        #expect(same.steps.allSatisfy { $0.isWarm }, "kept under this install on this hardware: warm")
    }

    @Test func warmStepsAreMarkedWarm() {
        let plan = Self.plan([], compiled: [.asr, .warmup])
        #expect(plan.steps.map(\.isWarm) == [false, false, true, true])
    }

    @Test func theLogFileIsLeftOutOfBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prepare-log.jsonl")
        PrepareLog.append(Self.cold("9200@1", asr: 21), to: file)
        PrepareLog.append(Self.cold("9200@1", asr: 1), to: file)
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "set again after the atomic rewrite")
        #expect(PrepareLog.read(file).count == 2)
    }

    @Test func theRecordKeepsTheHardwareModel() {
        #expect(PrepareRecord.begin().hwModel == PrepareLog.hardwareModel())
        #expect(PrepareLog.hardwareModel()?.isEmpty == false)
    }

    @Test func theLatestInstallWins() {
        let plan = Self.plan([Self.cold("9100@1", asr: 20), Self.cold("9200@2", asr: 23)], install: "9300@3")
        #expect(plan.step(.asr)?.expectedSeconds == 23)
    }

    @Test func pausedSuspendedOrFailedFirstAttemptsAreNotSamples() {
        var suspended = Self.cold("9200@2", asr: 40)
        suspended.stages[Self.index("asr", suspended)].suspendedSeconds = 12
        var failed = Self.cold("9201@2", asr: 40)
        failed.stages[Self.index("asr", failed)].error = "boom"
        var notStarted = Self.cold("9202@2", asr: 40)
        notStarted.stages.insert(PrepareRecord.Stage(name: "asr", start: "", end: "", seconds: 0, verdict: "notStarted"), at: 0)
        let samples = PrepareEstimates.coldSamples([suspended, failed, notStarted], nemotronUnits: Self.cpu)
        #expect(samples.filter { $0.stage == .asr }.map(\.installStamp) == ["9202@2"],
                "a refused stage did no work: the attempt after it is the first")
    }

    /// The built-in numbers: the iPhone 15's measured cold stages (Nemotron on the CPU), and the M4 Max's from the
    /// gated tests, rounded up, for the Mac.
    @Test func anotherOSBuildGivesTheBuiltInNumbers() {
        let plan = Self.plan([Self.cold("9200@1", os: "24A335", asr: 21)], os: "24B156")
        #expect(Self.seconds(plan) == [1.5, 1.5, 20, 0.25])
        #expect(!plan.timesFromThisDevice, "built-in numbers never give a time")
        let mac = Self.plan([], isPhone: false)
        #expect(Self.seconds(mac) == [0.7, 0.6, 14, 0.1])
    }

    /// Nemotron's timings count only under today's units: the Neural Engine lines of the builds before 2026-11-25
    /// (a 55–58 s compile) and lines without units are never used for its estimate.
    @Test func nemotronSamplesNeedTheSameComputeUnits() {
        let ane = Self.cold("9200@1", units: Self.ane, asr: 21, nemotron: 56)
        let unknown = Self.cold("9201@1", units: nil, asr: 22, nemotron: 9)
        let onCPU = Self.plan([ane, unknown])
        #expect(onCPU.step(.asr)?.expectedSeconds == 22, "asr from the latest install")
        #expect(onCPU.step(.nemotron)?.expectedSeconds == 1.5, "no Nemotron sample under cpuOnly: built-in")
        #expect(!onCPU.timesFromThisDevice, "a plan mixing device and built-in numbers gives no time")
        #expect(!onCPU.steps.contains { $0.isWarm }, "a Neural Engine Nemotron kept earlier says nothing about the CPU")
        let measured = Self.cold("9202@1", units: Self.cpu, asr: 18.8, diarizer: 0.98, nemotron: 0.89)
        let withCPU = Self.plan([ane, unknown, measured])
        #expect(withCPU.step(.nemotron)?.expectedSeconds == 0.89)
        #expect(withCPU.timesFromThisDevice)
    }

    @Test func warmAndDoneStagesInThisProcess() {
        let plan = Self.plan([], compiled: [.asr, .warmup], diarizerDone: true)
        #expect(plan.steps.map(\.stage) == [.diarizer, .nemotron, .asr, .warmup])
        #expect(plan.steps[0].isDone)
        #expect(plan.steps[2].expectedSeconds == 1 && plan.steps[3].expectedSeconds == 0.25)
        #expect(!plan.timesFromThisDevice, "Nemotron still has only a built-in number")
        let allWarm = Self.plan([], compiled: [.asr, .warmup, .nemotron], diarizerDone: true)
        #expect(allWarm.timesFromThisDevice)
        #expect(allWarm.steps[1].expectedSeconds == 2)
        let doneNemotron = Self.plan([], compiled: [.asr, .warmup], diarizerDone: true, nemotronDone: true)
        #expect(doneNemotron.steps[1].isDone && doneNemotron.timesFromThisDevice)
    }

    @Test func nemotronIsLeftOutWhenUnavailableOrNotInstalled() {
        let plan = Self.plan([], includeNemotron: false)
        #expect(plan.steps.map(\.stage) == [.diarizer, .asr, .warmup])
    }

    @Test func stagesKeptEarlierUnderThisInstallAreWarm() {
        // A relaunch of the same install: iOS kept the compiled models, so every stage loads warm.
        let plan = Self.plan([Self.cold("9300@3", asr: 21)], install: "9300@3")
        #expect(Self.seconds(plan) == [0.5, 2, 1, 0.25])
        #expect(plan.timesFromThisDevice)
    }

    @Test func unitsNames() {
        #expect(PrepareEstimates.unitsName(.cpuOnly) == "cpuOnly")
        #expect(PrepareEstimates.unitsName(.cpuAndNeuralEngine) == "cpuAndNeuralEngine")
        #expect(PrepareEstimates.unitsName(.all) == "all")
        #expect(PrepareEstimates.unitsName(.cpuAndGPU) == "cpuAndGPU")
    }
}
