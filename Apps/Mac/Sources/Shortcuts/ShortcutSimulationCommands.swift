#if DEBUG
import SwiftUI
import TranscribeKit

/// DEBUG only, and only in a simulated run (`TRANSCRIBE_SHORTCUTS=sim`, fake engine or UI tests): a Shortcut
/// Simulation menu that feeds the same backend events a real key press would, through `ShortcutCenter` (so the launch
/// gate and the dispatch rules apply). XCUITest cannot press fn or grant Accessibility; this is how the UI tests drive
/// the shortcuts.
struct ShortcutSimulationCommands: Commands {
    let center: ShortcutCenter

    var body: some Commands {
        CommandMenu("Shortcut Simulation") {
            Button("Start or Stop Recording") {
                center.simulate(.pressed(.toggleRecording))
                center.simulate(.released(.toggleRecording))
            }
            Divider()
            Button("Dictate: Press") { center.simulate(.pressed(.dictateHold)) }
            Button("Dictate: Release") { center.simulate(.released(.dictateHold)) }
            Button("Dictate Hands-free") {
                center.simulate(.pressed(.dictateToggle))
                center.simulate(.released(.dictateToggle))
            }
            Divider()
            Button("Cancel Dictation (Esc)") { center.simulate(.escape) }
        }
    }
}
#endif
