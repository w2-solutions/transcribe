import Foundation
import TranscribeMCP

// transcribe-mcp: the stdio MCP server Claude Code and Claude Desktop launch (§6). It answers the handshake itself
// and forwards each tools/call to the running Transcribe app over signed loopback HTTP, on the first of the
// well-known ports that answers. Each Claude app is paired once (Transcribe shows an Allow prompt); the pairing keys
// live in ~/Library/Application Support/Transcribe MCP/. stdout carries JSON-RPC only; stderr carries short logs,
// never keys, codes, arguments or transcript text.

signal(SIGPIPE, SIG_IGN)

let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let appURL = EnclosingApp.url(forHelper: exe)
let version = appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "0"

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") {
    print(version)
    exit(0)
}
if arguments.contains("--help") || !arguments.isEmpty {
    let usage = """
        usage: transcribe-mcp [--version | --help]
        The MCP server for the Transcribe app, spoken over stdio. Set it up from Transcribe: Settings → Claude.
        Claude's config needs no environment. For tests only: TRANSCRIBE_MCP_PORT (one port instead of the
        well-known ones) and TRANSCRIBE_MCP_STATE_DIR (another folder for the pairing keys).

        """
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.contains("--help") ? 0 : 64)
}

let environment = HelperEnvironment(ProcessInfo.processInfo.environment)
let identities = HelperIdentityStore(directory: HelperIdentityStore.directory(environment: environment))
let launcher = WorkspaceLauncher(appURL: appURL, bundleID: appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
                                    ?? "ai.w2solutions.transcribe.mac", env: environment)
let bridge = StdioBridge(transport: URLSessionAppTransport(), launcher: launcher, identities: identities,
                         ports: environment.ports, serverVersion: version)
await StdioBridge.run(bridge, input: .standardInput, output: .standardOutput, onOutputClosed: { exit(0) })
exit(0)
