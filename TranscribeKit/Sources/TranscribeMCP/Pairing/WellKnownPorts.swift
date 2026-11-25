/// Where the app listens for Claude, so no Claude config needs a port. The app binds the first of these that is free
/// (but stops at the first one when another copy of Transcribe holds it); the helper tries them in the same order.
/// All inside 40000–48999. Tests and the smoke script use their own ports (`TRANSCRIBE_MCP_PORT`,
/// `TRANSCRIBE_MCP_TEST_PORT`).
public enum WellKnownPorts {
    public static let all: [UInt16] = [41_873, 44_729, 47_461]
}
