import Foundation

/// All user-facing step subtitles live here (pure; used by the pipeline and placeholders).
public enum ProcessingCopy {
    public static let weights: [ProcessingStep: Double] = [.transcribing: 0.45, .separating: 0.45, .matching: 0.10]

    public static func subtitle(step: ProcessingStep, state: StepState, voicesFound: Int?, comparedWith: [String]) -> String {
        if case .skipped(let reason) = state { return reason }
        switch (step, state) {
        case (.transcribing, .done): return "Parakeet, on device"
        case (.transcribing, .active(let f)): return "Turning speech into text" + percent(f)
        case (.transcribing, _): return "Parakeet, on device"
        case (.separating, .done):
            guard let n = voicesFound else { return "Done" }
            return n == 0 ? "No speech found" : (n == 1 ? "1 voice found" : "\(n) voices found")
        case (.separating, .active(let f)): return "Listening for different voices" + percent(f)
        case (.separating, _): return "Finds who spoke when"
        case (.matching, _):
            return comparedWith.isEmpty ? "No saved voices yet" : "Compared with " + joinNames(comparedWith)
        }
    }
    /// "Liam", "Liam and Karan", "Liam, Karan and Mei"
    public static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
    static func percent(_ f: Double?) -> String { f.map { " · \(Int(($0 * 100).rounded()))%" } ?? "" }
}
