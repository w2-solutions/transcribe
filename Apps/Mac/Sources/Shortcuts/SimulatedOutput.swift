import AppKit
import Observation
import TranscribeKit

/// Where a dictation's text goes in a simulated run (`TRANSCRIBE_SHORTCUTS=sim`, fake engine or UI tests): a named
/// pasteboard of its own, never the general one, so a UI test never replaces the user's clipboard and never reads it
/// (which could raise macOS's pasteboard-privacy prompt). It never posts events and never pastes. In DEBUG the main
/// window publishes `lastDelivered` in a hidden accessibility element (`AX.Dictation.lastDelivered`) for the tests.
///
/// Compiled into every build (it is tiny and harmless) so the Release wiring can name it; only a simulated run, which
/// Release builds never are, creates it.
@MainActor @Observable
final class SimulatedOutput: DictationOutput {
    static let pasteboardName = NSPasteboard.Name("ai.w2solutions.transcribe.uitest")

    /// The text the last dictation delivered; empty until one does.
    private(set) var lastDelivered = ""

    init() {}

    func noteTarget() -> Int32? { nil }

    func deliver(_ text: String, target: Int32?) async -> DeliveryOutcome {
        write(text)
        return .copied(.notPasting)
    }

    func copy(_ text: String, reason: CopyReason) -> DeliveryOutcome {
        write(text)
        return .copied(.notPasting)
    }

    private func write(_ text: String) {
        let board = NSPasteboard(name: Self.pasteboardName)
        board.clearContents()
        board.setString(text, forType: .string)
        lastDelivered = text
    }
}
