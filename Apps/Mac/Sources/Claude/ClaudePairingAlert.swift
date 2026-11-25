import SwiftUI
import TranscribeMCP
import TranscribeMCPHost

/// The Allow prompt on the main window: the oldest waiting request from a Claude app, named as the app claims and with
/// the code Claude shows. The same requests are listed in Settings → Claude; answering either removes both.
///
/// Return and Esc both mean Don't Allow; Allow takes a click. Any local process can make this prompt appear, so a
/// Return pressed while typing in Transcribe, or out of habit, must never grant access. A SwiftUI alert cannot do this
/// (AppKit gives Return to the first button unless the cancel button takes it, and then Esc does nothing), so this is a
/// sheet with its own buttons.
struct ClaudePairingAlert: ViewModifier {
    @Environment(ClaudeAccess.self) private var claude

    func body(content: Content) -> some View {
        // Read here, in body, so the view follows the list; the binding only hands that value to the sheet.
        let first = claude.pendingRequests.first
        return content.sheet(item: Binding(get: { first }, set: { _ in })) { request in
            Prompt(request: request, allow: { claude.allow(request) }, deny: { claude.deny(request) })
        }
    }

    static func title(_ request: PendingRequest?) -> String {
        "Allow “\(request?.name ?? ClientName.fallback)” to read your transcripts?"
    }

    static func message(_ request: PendingRequest) -> String {
        "Claude should be showing the code \(request.code). Only allow this if you just asked Claude to read from Transcribe."
    }

    private struct Prompt: View {
        let request: PendingRequest
        let allow: () -> Void
        let deny: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(ClaudePairingAlert.title(request))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ClaudePairingAlert.message(request))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Allow", action: allow)
                        .accessibilityIdentifier(AX.Claude.alertAllow)
                    Button("Don't Allow", action: deny)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(AX.Claude.alertDeny)
                }
                // Esc: Don't Allow too. Hidden, and out of the accessibility tree (the visible button is the one to use).
                .background {
                    Button("Cancel", action: deny)
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}
