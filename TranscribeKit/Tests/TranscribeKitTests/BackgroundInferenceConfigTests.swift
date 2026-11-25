import Foundation
import Testing

/// The Background Inference entitlement and the Info.plist flag the app reads in its place (`Composition.appActivity`)
/// must agree, or the engine would start Neural Engine work in the background without it (or never use it). The flag
/// comes from the build setting `TRANSCRIBE_BACKGROUND_INFERENCE` in project.yml: "NO" while Transcribe.entitlements
/// lacks the key, and `$(TRANSCRIBE_SYNC)` once it has it, so it follows the entitlements file the build picks.
@Suite("Background Inference configuration")
struct BackgroundInferenceConfigTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let inferenceKey = "com.apple.developer.background-tasks.continued-processing.inference"
    static let gpuKey = "com.apple.developer.background-tasks.continued-processing.gpu"
    static let entitlementFiles = ["Apps/iPhone/Transcribe.entitlements", "Apps/iPhone/Transcribe.local.entitlements",
                                   "Apps/Mac/TranscribeMac.entitlements", "Apps/Mac/TranscribeMac.local.entitlements"]

    static func entitlements(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func projectYML() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    /// Every `TRANSCRIBE_BACKGROUND_INFERENCE: <value>` setting line in project.yml, values unquoted.
    static func settingValues(_ yml: String) -> [String] {
        yml.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TRANSCRIBE_BACKGROUND_INFERENCE:") else { return nil }
            return trimmed.dropFirst("TRANSCRIBE_BACKGROUND_INFERENCE:".count)
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    @Test func theLocalEntitlementsNeverCarryTheKey() throws {
        // TRANSCRIBE_SYNC=NO builds sign with this file under the wildcard profile, which cannot carry it.
        #expect(try Self.entitlements("Apps/iPhone/Transcribe.local.entitlements")[Self.inferenceKey] == nil)
    }

    @Test func noEntitlementsFileAsksForBackgroundGPU() throws {
        // Every prepare stage is .cpuAndNeuralEngine or .cpuOnly; the GPU entitlement is not wanted.
        for file in Self.entitlementFiles {
            #expect(try Self.entitlements(file)[Self.gpuKey] == nil, "\(file)")
        }
    }

    @Test func theFlagFollowsTheEntitlementsFile() throws {
        let yml = try Self.projectYML()
        let values = Self.settingValues(yml)
        #expect(values.count == 1, "one setting, on the iPhone target: \(values)")
        let value = try #require(values.first)
        let entitled = try Self.entitlements("Apps/iPhone/Transcribe.entitlements")[Self.inferenceKey]
        if let entitled {
            #expect(entitled as? Bool == true, "the entitlement's value is a Boolean true")
            #expect(value == "$(TRANSCRIBE_SYNC)", "Transcribe.entitlements has the key: the flag must follow TRANSCRIBE_SYNC")
        } else {
            #expect(value == "NO", "Transcribe.entitlements lacks the key: the flag must be NO")
        }
        #expect(yml.contains("TranscribeBackgroundInference: $(TRANSCRIBE_BACKGROUND_INFERENCE)"),
                "the iPhone Info.plist mirrors the setting")
    }

    @Test func theMacTargetHasNoFlag() throws {
        let yml = try Self.projectYML()
        let start = try #require(yml.range(of: "\n  TranscribeMac:\n"))
        let rest = yml[start.upperBound...]
        let end = rest.range(of: "\n  TranscribeUITests:")?.lowerBound ?? rest.endIndex
        #expect(!rest[..<end].isEmpty)
        #expect(!rest[..<end].contains("BackgroundInference"),
                "the Mac app reads no flag, so AppActivity never allows background stages there")
    }
}
