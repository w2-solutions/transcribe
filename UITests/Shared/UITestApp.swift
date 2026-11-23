import XCTest
@MainActor enum UITestApp {
    static func launch(seed: String? = nil, script: String? = nil, speed: String = "instant", models: String? = nil,
                       route: String? = nil, mic: String? = nil,
                       now: String? = "2026-11-18T14:31:00+11:00") -> XCUIApplication {
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
        if let now { env["TRANSCRIBE_NOW"] = now }
        app.launchEnvironment = env
        app.launch()
        return app
    }
}
