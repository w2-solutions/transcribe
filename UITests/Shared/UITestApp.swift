import XCTest
@MainActor enum UITestApp {
    static func launch(seed: String? = nil, script: String? = nil, speed: String = "instant", models: String? = nil,
                       route: String? = nil, mic: String? = nil, channel: String? = nil, sync: String? = nil,
                       source: String? = nil, macAudio: String? = nil, macAudioExplained: Bool? = nil,
                       outputRoute: String? = nil,
                       now: String? = "2026-11-18T14:31:00+11:00", extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-useFakeEngine", "-uiTesting", "-AppleLocale", "en_AU", "-AppleLanguages", "(en)"]
        #if os(macOS)
        // No window animations, and no windows restored from an earlier run (each test starts from the seed).
        app.launchArguments += ["-NSAutomaticWindowAnimationsEnabled", "NO", "-ApplePersistenceIgnoreState", "YES"]
        #endif
        var env: [String: String] = ["TRANSCRIBE_SPEED": speed]
        if let seed { env["TRANSCRIBE_SEED"] = seed }
        if let script { env["TRANSCRIBE_SCRIPT"] = script }
        if let models { env["TRANSCRIBE_MODELS"] = models }
        if let route { env["TRANSCRIBE_ROUTE"] = route }
        if let mic { env["TRANSCRIBE_MIC"] = mic }
        // The capture channel the store stamps on new recordings ("iphone", "ipad", "mac"); default: this device's.
        if let channel { env["TRANSCRIBE_CHANNEL"] = channel }
        // A fake iCloud scenario ("fresh", "remoteLibrary", "signedOut", …; §8.6). UI tests never touch CloudKit.
        if let sync { env["TRANSCRIBE_SYNC"] = "fake:\(sync)" }
        // Mac audio (Mac only): the recording source setting ("microphone", "both", "macAudio"), the fake Mac audio
        // stream ("granted", "silent", "lost"; given with any source, so the fake engine offers Mac audio), whether the
        // explainer was already seen, and the output route the headphones hint reads ("builtInSpeaker", "headphones").
        if let source { env["TRANSCRIBE_SOURCE"] = source }
        if let macAudio { env["TRANSCRIBE_MAC_AUDIO"] = macAudio } else if source != nil { env["TRANSCRIBE_MAC_AUDIO"] = "granted" }
        if let macAudioExplained { env["TRANSCRIBE_MAC_AUDIO_EXPLAINED"] = macAudioExplained ? "1" : "0" }
        if let outputRoute { env["TRANSCRIBE_OUTPUT_ROUTE"] = outputRoute }
        if let now { env["TRANSCRIBE_NOW"] = now }
        // Anything else a test needs for this launch only (Claude access: TRANSCRIBE_MCP_TEST_PORT).
        env.merge(extraEnvironment) { _, new in new }
        app.launchEnvironment = env
        app.launch()
        return app
    }
}
