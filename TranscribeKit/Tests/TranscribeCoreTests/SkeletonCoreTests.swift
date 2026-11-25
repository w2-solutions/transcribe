import AVFoundation
import Foundation
import Testing
@testable import TranscribeCore

@Suite("VoiceVector")
struct VoiceVectorTests {
    @Test func normalisesAndIsIdempotent() throws {
        let v = try #require(VoiceVector(raw: [3, 4]))
        #expect(abs(v.values[0] - 0.6) < 1e-6 && abs(v.values[1] - 0.8) < 1e-6)
        let again = try #require(VoiceVector(raw: v.values))
        #expect(again == v)
        #expect(abs(v.cosine(v) - 1) < 1e-6)
    }

    @Test(arguments: [[Float.nan, 1], [Float.infinity, 0], [0, 0], []])
    func rejectsBadInput(_ raw: [Float]) {
        #expect(VoiceVector(raw: raw) == nil)
    }

    @Test func rejectsWrongDimension() {
        #expect(VoiceVector(raw: [1, 2, 3], expectedDimension: 256) == nil)
        #expect(VoiceVector(raw: [1, 2, 3], expectedDimension: 3) != nil)
    }

    @Test func packsLittleEndianAndRoundTrips() throws {
        let v = try #require(VoiceVector(raw: [1, 0]))
        let bytes = [UInt8](v.packed)
        #expect(bytes == [0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x00])   // 1.0f LE, 0.0f
        let w = try #require(VoiceVector(raw: (0..<256).map { Float($0) - 100.5 }))
        let back = try #require(VoiceVector(packed: w.packed, expectedDimension: 256))
        #expect(zip(back.values, w.values).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(VoiceVector(packed: Data([1, 2, 3])) == nil)
    }

    @Test func weightedMean() throws {
        let a = try #require(VoiceVector(raw: [1, 0])), b = try #require(VoiceVector(raw: [0, 1]))
        let m = try #require(VoiceVector.weightedMean([(a, 3), (b, 1)]))
        #expect(abs(m.values[0] - 3 / Float(10).squareRoot()) < 1e-5)
        #expect(VoiceVector.weightedMean([]) == nil)
        let c = try #require(VoiceVector(raw: [1, 0, 0]))
        #expect(VoiceVector.weightedMean([(a, 1), (c, 1)]) == nil)
    }
}

@Suite("DisplayFormat (en_AU, Australia/Sydney)")
struct DisplayFormatTests {
    let locale = Locale(identifier: "en_AU")
    let tz = TimeZone(identifier: "Australia/Sydney")!

    func date(_ day: Int, _ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    @Test func dates() {
        #expect(DisplayFormat.cardDate(date(18, 14, 29), locale: locale, timeZone: tz) == "Wed 18 Nov · 2:29 pm")
        #expect(DisplayFormat.longDate(date(18, 14, 24), locale: locale, timeZone: tz) == "Wed 18 Nov 2026 · 2:24 pm")
        #expect(DisplayFormat.shortDate(date(18, 14, 24), locale: locale, timeZone: tz) == "18 Nov · 2:24 pm")
        #expect(DisplayFormat.dayMonth(date(18, 14, 24), locale: locale, timeZone: tz) == "18 Nov")
        #expect(DisplayFormat.dayDate(date(17, 9, 2), locale: locale, timeZone: tz) == "Tue 17 Nov")
        #expect(DisplayFormat.time(date(17, 9, 2), locale: Locale(identifier: "en_US"), timeZone: tz) == "9:02 am")
    }

    @Test(arguments: [(7.0, "0:07"), (7.99, "0:07"), (20, "0:20"), (768, "12:48"), (3723, "1:02:03"), (-3, "0:00")])
    func durations(_ t: TimeInterval, _ expected: String) {
        #expect(DisplayFormat.duration(t) == expected)
    }

    @Test func spokenAndRate() {
        #expect(DisplayFormat.spokenDuration(14) == "0 minutes 14 seconds")
        #expect(DisplayFormat.rate(1) == "1×")
        #expect(DisplayFormat.rate(1.5) == "1.5×")
        #expect(DisplayFormat.rate(2) == "2×")
        #expect(DisplayFormat.rate(0.75) == "0.75×")
    }
}

@Suite("LaunchConfig")
struct LaunchConfigTests {
    @Test func defaults() {
        let c = LaunchConfig(arguments: [], environment: [:])
        #expect(!c.useFakeEngine && !c.uiTesting)
        #expect(c.seed == nil && c.script == .newVoices && c.speed == .demo && c.models == .installed)
        #expect(c.now == nil && c.route == nil && c.mic == .granted)
        #expect(LaunchConfig(arguments: ["-uiTesting"], environment: [:]).speed == .instant)
    }

    @Test func parsesEveryVariable() throws {
        let c = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: [
            "TRANSCRIBE_SEED": "library", "TRANSCRIBE_SCRIPT": "knownVoices", "TRANSCRIBE_SPEED": "frozen",
            "TRANSCRIBE_MODELS": "missing", "TRANSCRIBE_NOW": "2026-11-18T14:31:00+11:00",
            "TRANSCRIBE_ROUTE": "voice:Karan", "TRANSCRIBE_MIC": "denied",
        ])
        #expect(c.useFakeEngine && c.uiTesting)
        #expect(c.seed == .library && c.script == .knownVoices && c.speed == .frozen && c.models == .missing)
        #expect(c.route == .voice("Karan") && c.mic == .denied)
        let now = try #require(c.now)
        #expect(now.timeIntervalSince1970 == 1_794_972_660)
        #expect(c.clock.now == now)
        #expect(LaunchConfig(arguments: [], environment: ["TRANSCRIBE_ENGINE": "fake"]).useFakeEngine)
    }

    @Test func firstRunDefaultsToMissingModels() {
        #expect(LaunchConfig(arguments: [], environment: ["TRANSCRIBE_SEED": "firstRun"]).models == .missing)
        #expect(LaunchConfig(arguments: [], environment: ["TRANSCRIBE_SEED": "firstRun", "TRANSCRIBE_MODELS": "installed"]).models == .installed)
    }

    @Test(arguments: [
        ("library", LaunchRoute.library), ("recording", .recording), ("voices", .voices), ("settings", .settings),
        ("models", .modelSettings), ("attributions", .attributions), ("transcript:latest", .transcript("latest")),
        ("transcript:1", .transcript("1")), ("name:latest:S2", .nameSpeaker("latest", "S2")), ("voice:Karan", .voice("Karan")),
    ])
    func routes(_ raw: String, _ expected: LaunchRoute) {
        #expect(LaunchRoute(raw) == expected)
    }

    @Test(arguments: ["", "transcript", "name:latest", "voice", "nowhere"])
    func badRoutes(_ raw: String) {
        #expect(LaunchRoute(raw) == nil)
    }

    /// Claude access for the session (D19): read only with the fake engine or `-uiTesting`, so a stray environment
    /// variable can never turn it on for the real library.
    @Test func mcpLaunchKeysReadOnlyWithFakeOrUITesting() {
        let env = ["TRANSCRIBE_MCP": "on", "TRANSCRIBE_MCP_AUTO_ALLOW": "on", "TRANSCRIBE_MCP_TEST_PORT": "39123"]
        let real = LaunchConfig(arguments: [], environment: env)
        #expect(!real.mcpOn && !real.mcpAutoAllow && real.mcpTestPort == nil)
        for args in [["-useFakeEngine"], ["-uiTesting"]] {
            let c = LaunchConfig(arguments: args, environment: env)
            #expect(c.mcpOn && c.mcpAutoAllow && c.mcpTestPort == 39_123, "\(args)")
        }
        let fake = LaunchConfig(arguments: [], environment: env.merging(["TRANSCRIBE_ENGINE": "fake"]) { $1 })
        #expect(fake.mcpOn && fake.mcpAutoAllow)
        let defaults = LaunchConfig(arguments: ["-useFakeEngine"], environment: [:])
        #expect(!defaults.mcpOn && !defaults.mcpAutoAllow && defaults.mcpTestPort == nil)
        #expect(!LaunchConfig(arguments: ["-useFakeEngine"], environment: ["TRANSCRIBE_MCP": "yes"]).mcpOn)
        #expect(!LaunchConfig(arguments: ["-useFakeEngine"], environment: ["TRANSCRIBE_MCP_AUTO_ALLOW": "1"]).mcpAutoAllow)
        #expect(LaunchConfig(arguments: ["-useFakeEngine"], environment: ["TRANSCRIBE_MCP_AUTO_ALLOW": " ON "]).mcpAutoAllow)
    }

    @Test func mcpTestPortValidated() {
        func config(port: String? = nil) -> LaunchConfig {
            var env: [String: String] = [:]
            env["TRANSCRIBE_MCP_TEST_PORT"] = port
            return LaunchConfig(arguments: ["-useFakeEngine"], environment: env)
        }
        #expect(config(port: "1").mcpTestPort == 1)
        #expect(config(port: "65535").mcpTestPort == 65_535)
        for bad in ["0", "65536", "-1", "abc", "", " 40000"] {
            #expect(config(port: bad).mcpTestPort == nil, "\(bad)")
        }
    }
}

@Suite("WAVFileWriter")
struct WAVFileWriterTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString).wav")
    }

    @Test func headerAndSizes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append([Float](repeating: 0.5, count: 16_000))
        try writer.flushHeader()
        var data = try Data(contentsOf: url)
        #expect(data.count == 44 + 32_000)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        func u32(_ o: Int) -> UInt32 { data[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        #expect(u32(4) == 36 + 32_000 && u32(40) == 32_000)
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 16_000 && u32(28) == 32_000 && u16(32) == 2 && u16(34) == 16)
        try writer.append([2, -2])   // clamped
        let duration = try writer.finish()
        #expect(abs(duration - 16_002.0 / 16_000.0) < 1e-9)
        data = try Data(contentsOf: url)
        #expect(u32(40) == 32_004)
        #expect(data[data.count - 4] == 0xFF && data[data.count - 3] == 0x7F)   // +32767
    }

    @Test func avAudioFileReadsIt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append((0..<8_000).map { Float(sin(Double($0) * 0.1)) * 0.3 })
        try writer.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 8_000)
    }
}

@Suite("ProcessingCopy")
struct ProcessingCopyTests {
    @Test func joinNames() {
        #expect(ProcessingCopy.joinNames([]) == "")
        #expect(ProcessingCopy.joinNames(["Liam"]) == "Liam")
        #expect(ProcessingCopy.joinNames(["Liam", "Karan"]) == "Liam and Karan")
        #expect(ProcessingCopy.joinNames(["Liam", "Karan", "Mei"]) == "Liam, Karan and Mei")
    }

    @Test func subtitles() {
        func s(_ step: ProcessingStep, _ state: StepState, _ n: Int? = nil, _ names: [String] = []) -> String {
            ProcessingCopy.subtitle(step: step, state: state, voicesFound: n, comparedWith: names)
        }
        #expect(s(.transcribing, .done) == "Parakeet, on device")
        #expect(s(.transcribing, .active(fraction: 0.42)) == "Turning speech into text · 42%")
        #expect(s(.separating, .active(fraction: nil)) == "Listening for different voices")
        #expect(s(.separating, .done, 2) == "2 voices found")
        #expect(s(.separating, .done, 1) == "1 voice found")
        #expect(s(.separating, .done, 0) == "No speech found")
        #expect(s(.separating, .waiting) == "Finds who spoke when")
        #expect(s(.matching, .waiting) == "No saved voices yet")
        #expect(s(.matching, .active(fraction: nil), nil, ["Liam", "Karan"]) == "Compared with Liam and Karan")
        #expect(s(.matching, .skipped("Identify speakers is off")) == "Identify speakers is off")
    }

    @Test func snapshotStepCounter() {
        let steps = [
            StepStatus(step: .transcribing, state: .done, subtitle: ""),
            StepStatus(step: .separating, state: .active(fraction: 0.6), subtitle: ""),
            StepStatus(step: .matching, state: .waiting, subtitle: ""),
        ]
        let snap = ProcessingSnapshot(recordingID: UUID(), steps: steps, overall: 0.72, voicesFound: nil, comparedWith: [], phase: .running)
        #expect(snap.currentStep == .separating)
        #expect(snap.stepCounterText == "Step 2 of 3")
        #expect(steps.map(\.axValue) == ["done", "inProgress", "waiting"])
    }
}
