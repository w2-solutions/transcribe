import FluidAudio
import TranscribeCore

/// Maps the app's language hint (ISO 639-1 codes from `Languages.parakeetV3`) to FluidAudio's `Language`.
///
/// For Parakeet v3 the hint is a script filter (Latin, Cyrillic, Greek), not a language model switch,
/// so `nil` (automatic) is always safe.
public enum LanguageMapping {
    public static func fluid(_ hint: LanguageHint) -> Language? {
        switch hint {
        case .automatic: nil
        case .language(let code): fluid(code: code)
        }
    }

    /// `nil` for codes FluidAudio does not know (treated as automatic).
    public static func fluid(code: String) -> Language? {
        Language(rawValue: code.lowercased())
    }
}
