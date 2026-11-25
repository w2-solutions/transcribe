import Foundation

/// What Claude reads when Transcribe cannot answer (§2.4), or has not allowed this Claude app yet. Every one comes
/// back as a tools/call result with `isError: true`. Fixed texts only (the code is computed by the helper itself):
/// nothing from the other side of the socket reaches Claude unless it is signed.
public enum BridgeMessages {
    public static let notSetUp = "Transcribe isn't set up in this Claude yet. In Transcribe, open Settings → Claude and choose Add to Claude Code or Add to Claude Desktop."
    public static let notSharing = "Transcribe is open but isn't sharing with Claude. In Transcribe, open Settings → Claude and turn on “Let Claude read transcripts”."
    public static let notOpen = "Transcribe isn't open. Open Transcribe and try again."
    public static let didNotStart = "Transcribe didn't start in time. Open Transcribe, check Settings → Claude, and try again."
    public static let unauthorized = "Transcribe didn't accept the request from this Claude app. Try again. If it keeps happening, remove this app in Transcribe (Settings → Claude → Allowed apps), then ask again."
    public static let impostor = "Something other than Transcribe answered, so Claude didn't use the reply. Make sure Transcribe is open, quit any other copy of Transcribe, and try again."
    public static let connectionLost = "Transcribe stopped answering partway through. Make sure Transcribe is open, then try again."
    public static let timedOut = "Transcribe took too long to answer. Try again."
    public static let denied = "Transcribe didn't allow this Claude app to read transcripts. If that was a mistake, ask again in a few minutes and click Allow in Transcribe."
    /// 429: three requests are waiting, or five new ones came in the last 10 minutes (then none may be waiting).
    public static let pairingBusy = "Transcribe has too many permission requests right now. Answer any that are waiting in Transcribe (Settings → Claude), or wait 10 minutes, then ask again."
    /// No port gave a signed answer, and one said, unsigned, that it does not know this Claude app, which has read from
    /// Transcribe before (a pairing that never has is replaced instead, without this message).
    public static let notRecognised = "Something answered for Transcribe, but it couldn't prove it's the Transcribe this Claude app was allowed in, so Claude didn't use it. Make sure Transcribe is open and Settings → Claude → “Let Claude read transcripts” is on, then try again. If Transcribe doesn't list this Claude app under Allowed apps (for example after its data was reset), delete the folder ~/Library/Application Support/Transcribe MCP and ask again: Transcribe will show a new request."
    public static let stateUnavailable = "Claude's connection to Transcribe couldn't save its settings in ~/Library/Application Support/Transcribe MCP. Check that folder, then try again."

    /// The first call from a Claude app Transcribe has not seen.
    public static func permissionNeeded(code: String) -> String {
        "Transcribe needs your permission before Claude can read transcripts. In Transcribe, check that the code is \(code) and click Allow, then ask again."
    }

    /// The user has not answered yet.
    public static func stillWaiting(code: String) -> String {
        "Transcribe is still waiting for your permission. In Transcribe, check that the code is \(code) and click Allow (the request is also in Settings → Claude), then ask again."
    }

    /// Transcribe no longer knows this Claude app, so the helper made a new request.
    public static func askingAgain(code: String) -> String {
        "This Claude app isn't allowed in Transcribe now (it may have been removed there), so Transcribe is asking again. In Transcribe, check that the code is \(code) and click Allow, then ask again."
    }

    /// Any other HTTP status, or a URL error's `NSURLError` code.
    public static func httpError(_ code: Int) -> String {
        "Transcribe returned an error (HTTP \(code)). Try again; if it keeps happening, turn Settings → Claude off and on in Transcribe."
    }
}
