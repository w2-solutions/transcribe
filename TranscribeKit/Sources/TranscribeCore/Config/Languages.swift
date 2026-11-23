import Foundation

public enum Languages {
    /// Parakeet TDT v3 languages, ISO 639-1 code -> English display name, display order.
    public static let parakeetV3: [(code: String, name: String)] = [
        ("bg","Bulgarian"),("hr","Croatian"),("cs","Czech"),("da","Danish"),("nl","Dutch"),("en","English"),
        ("et","Estonian"),("fi","Finnish"),("fr","French"),("de","German"),("el","Greek"),("hu","Hungarian"),
        ("it","Italian"),("lv","Latvian"),("lt","Lithuanian"),("mt","Maltese"),("pl","Polish"),("pt","Portuguese"),
        ("ro","Romanian"),("ru","Russian"),("sk","Slovak"),("sl","Slovenian"),("es","Spanish"),("sv","Swedish"),("uk","Ukrainian"),
    ]
    public static func displayName(_ hint: LanguageHint) -> String {
        switch hint {
        case .automatic: "Auto"
        case .language(let c): parakeetV3.first { $0.code == c }?.name ?? c
        }
    }
}
