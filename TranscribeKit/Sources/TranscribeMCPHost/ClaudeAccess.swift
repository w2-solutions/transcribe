import Foundation
import Observation
import os
import SwiftData
import Synchronization
import TranscribeMCP

/// Session-only overrides (D19). The Mac app passes them only in DEBUG builds; none of them is ever saved, and a
/// session with any of them on never writes `ClaudeAccess.json`.
public struct ClaudeAccessOptions: Sendable, Equatable {
    /// Bind port 0 (UI tests); `status` then reports the port actually bound.
    public var ephemeralPort = false
    /// Serve from launch even when the switch is off in the file (`TRANSCRIBE_MCP=on`).
    public var startOn = false
    /// Allow every pairing request at once (`TRANSCRIBE_MCP_AUTO_ALLOW=on`; the smoke script and the helper's fake
    /// launch). Clients allowed this way last for the session only.
    public var autoAllow = false
    /// Listen on this port only, instead of the well-known ones (`TRANSCRIBE_MCP_TEST_PORT`). Wins over `ephemeralPort`.
    public var fixedPort: UInt16? = nil

    public init(ephemeralPort: Bool = false, startOn: Bool = false, autoAllow: Bool = false, fixedPort: UInt16? = nil) {
        self.ephemeralPort = ephemeralPort; self.startOn = startOn; self.autoAllow = autoAllow; self.fixedPort = fixedPort
    }
}

/// "Let Claude read transcripts" (Settings → Claude, Mac only): the switch, the app's pairing key pair and the Claude
/// apps the user allowed (in `ClaudeAccess.json`), the requests waiting for Allow, and the loopback MCP server.
/// Created once at launch, before any window, so a launch by the helper serves straight away (§5).
@MainActor @Observable
public final class ClaudeAccess {
    public enum Status: Equatable, Sendable {
        case off, starting
        case ready(port: UInt16)
        /// Another copy of Transcribe (same bundle id) holds the first port: nothing to offer but quitting it.
        case otherCopy(UInt16)
        /// Something else holds every port Transcribe can use.
        case portsInUse([UInt16])
        /// A short errno name such as "EPERM", never a path.
        case failed(String)
    }

    public private(set) var isEnabled: Bool
    public private(set) var status: Status = .off
    /// The switch has been on before (a `ClaudeAccess.json` exists, or it went on this session): Claude may still list
    /// Transcribe, so Settings says how to remove it while the switch is off.
    public private(set) var wasSetUp: Bool
    public private(set) var allowedApps: [AllowedClient] = []
    public private(set) var pendingRequests: [PendingRequest] = []
    /// Called on every change of the switch and once from `start()` (the app mirrors it into
    /// `AppEnvironment.claudeAccessOn` for the privacy wording).
    @ObservationIgnored public var onEnabledChange: (@MainActor (Bool) -> Void)?
    /// A Claude app asked for permission (a new request, not a repeat): the Mac app asks for the user's attention.
    @ObservationIgnored public var onNewRequest: (@MainActor () -> Void)?

    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "mcp")

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let options: ClaudeAccessOptions
    @ObservationIgnored private let ports: [UInt16]
    @ObservationIgnored private let serverVersion: String
    @ObservationIgnored private let otherCopyRunning: @MainActor () -> Bool
    @ObservationIgnored private let appKey: String
    @ObservationIgnored private let registry: PairingRegistry
    @ObservationIgnored private let state: EndpointState
    @ObservationIgnored private let boundPort: PortBox
    @ObservationIgnored private let endpoint: MCPEndpoint
    @ObservationIgnored private var server: LoopbackHTTPServer?
    /// Bumped by every bind and stop, so a bind or listener failure that lands after the switch moved is ignored.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var expiryRefresh: Task<Void, Never>?

    /// A session started on, with a fixed port or with auto-allow (the smoke script, the DEBUG fake launch) never
    /// writes the file: not at launch, and not from the switch, Allow or Remove.
    private var persists: Bool { options.fixedPort == nil && !options.startOn && !options.autoAllow }

    /// `ports` are the ones to try in order (tests pass their own; the app uses the well-known ones).
    public init(container: ModelContainer, root: URL, serverVersion: String, options: ClaudeAccessOptions = .init(),
                ports: [UInt16] = WellKnownPorts.all, limits: PairingRegistry.Limits = .init(),
                otherCopyRunning: @escaping @MainActor () -> Bool) {
        self.root = root
        self.options = options
        self.ports = ports
        self.serverVersion = serverVersion
        self.otherCopyRunning = otherCopyRunning
        let file = ClaudeAccessFile.load(root: root)
        let key = file?.appKey ?? PairingCrypto.newPrivateKey()
        appKey = key
        // The key comes from PairingCrypto or a file that load() checked, so the registry always exists.
        registry = PairingRegistry(privateKey: key, allowed: file?.allowed ?? [], limits: limits)!
        registry.setAutoAllow(options.autoAllow)
        isEnabled = (file?.enabled ?? false) || options.startOn
        wasSetUp = file != nil
        let state = EndpointState(serving: false)
        let box = PortBox()
        self.state = state
        self.boundPort = box
        endpoint = MCPEndpoint(port: { box.get() }, state: state, pairing: registry, replay: ReplayGuard(),
                               server: MCPServer(version: serverVersion, library: LibraryReader(container: container)))
        allowedApps = registry.allowedClients
        registry.setOnChange { [weak self] change in
            Task { @MainActor in self?.registryChanged(change) }
        }
    }

    /// At launch: serves when the switch is on (in the file, or `options.startOn`). Never writes the file.
    public func start() async {
        onEnabledChange?(isEnabled)
        guard isEnabled else { status = .off; return }
        await bind()
    }

    /// The switch. On: saves (the first time, with the app's new key pair), binds. Off: in-flight requests get 503,
    /// the listener and every open connection close, waiting requests are dropped, and allowed apps are kept.
    public func setEnabled(_ on: Bool) async {
        if on {
            isEnabled = true
            wasSetUp = true
            persist()
            onEnabledChange?(true)
            await bind()
        } else {
            isEnabled = false
            shutDown()
            registry.dropPending()
            refresh()
            status = .off
            persist()
            onEnabledChange?(false)
            Self.log.info("stopped")
        }
    }

    /// Allow: false when the request is gone (it expired). Saved at once.
    @discardableResult public func allow(_ request: PendingRequest) -> Bool {
        guard registry.allow(clientID: request.id, now: Date()) else { refresh(); return false }
        Self.log.info("pairing allowed")
        persist()
        refresh()
        return true
    }

    /// Don't Allow: the client is refused for a few minutes, then forgotten. Not saved.
    public func deny(_ request: PendingRequest) {
        if registry.deny(clientID: request.id, now: Date()) { Self.log.info("pairing denied") }
        refresh()
    }

    /// Remove an allowed app: its next call is told Transcribe doesn't know it. Saved at once.
    public func remove(_ app: AllowedClient) {
        guard registry.remove(clientID: app.id) else { return }
        Self.log.info("client removed")
        persist()
        refresh()
    }

    /// What Settings copies; nil while off.
    public func setup(helperPath: String) -> ClientSetup? {
        isEnabled ? ClientSetup(helperPath: helperPath, appVersion: serverVersion) : nil
    }

    /// The port the endpoint checks requests against (tests).
    var endpointPort: UInt16 { boundPort.get() }

    // MARK: - Private

    private func registryChanged(_ change: PairingRegistry.Change) {
        refresh()
        // Auto-allow adds clients from the endpoint; a persisting session never has auto-allow, so nothing to save.
        if change == .newRequest { onNewRequest?() }
    }

    /// Copies the registry into the observed lists, and refreshes again when the next request expires.
    private func refresh() {
        let now = Date()
        allowedApps = registry.allowedClients
        pendingRequests = registry.pendingRequests(now: now)
        expiryRefresh?.cancel()
        guard let next = registry.nextExpiry(now: now) else { expiryRefresh = nil; return }
        expiryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func persist() {
        guard persists else { return }
        do {
            try ClaudeAccessFile(enabled: isEnabled, appKey: appKey, allowed: registry.allowedClients).save(root: root)
        } catch {
            Self.log.error("save failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Binds the first port that is free. When another copy of Transcribe holds one, that copy is the one sharing:
    /// stop there rather than move to the next port (only a foreign holder moves this copy on).
    private func bind() async {
        shutDown()
        attempt += 1
        let mine = attempt
        // Records `servingSince` before the listener exists: requests signed earlier went to whatever held the port.
        state.set(serving: true)
        status = .starting
        let candidates: [UInt16] = options.fixedPort.map { [$0] } ?? (options.ephemeralPort ? [0] : ports)
        for requested in candidates {
            // The listener serves as soon as it is ready, which can be well before the main actor (busy launching the
            // app) resumes below, so the endpoint must already check Host and the MAC against the right port. Port 0
            // is only known once bound; nobody can have it before then.
            boundPort.set(requested)
            let endpoint = endpoint
            let server = LoopbackHTTPServer(port: requested, onFailure: { [weak self] error in
                Task { @MainActor in self?.listenerFailed(error, attempt: mine) }
            }, handler: { await endpoint.handle($0) })
            self.server = server
            do {
                let bound = try await server.start()
                guard mine == attempt else { server.stop(); return }
                boundPort.set(bound)
                status = .ready(port: bound)
                Self.log.info("server ready port=\(bound, privacy: .public)")
                return
            } catch {
                guard mine == attempt else { return }
                self.server = nil
                Self.log.error("bind failed port=\(requested, privacy: .public) errno=\(Self.errnoName(error), privacy: .public)")
                switch error {
                case .portInUse(let taken):
                    if otherCopyRunning() {
                        state.set(serving: false)
                        status = .otherCopy(taken)
                        return
                    }
                case .notPermitted, .other:
                    state.set(serving: false)
                    status = .failed(Self.errnoName(error))
                    return
                }
            }
        }
        state.set(serving: false)
        status = .portsInUse(candidates)
    }

    /// A listener that was ready and failed later: "Couldn't start"; turning the switch off and on retries.
    private func listenerFailed(_ error: LoopbackError, attempt failed: Int) {
        guard failed == attempt, isEnabled else { return }
        shutDown()
        status = .failed(Self.errnoName(error))
        Self.log.error("listener failed errno=\(Self.errnoName(error), privacy: .public)")
    }

    /// Refuse first (in-flight requests get 503), then close the listener and every connection.
    private func shutDown() {
        attempt += 1
        state.set(serving: false)
        server?.stop()
        server = nil
    }

    private static func errnoName(_ error: LoopbackError) -> String {
        switch error {
        case .portInUse: "EADDRINUSE"
        case .notPermitted: "EPERM"
        case .other(let name): name
        }
    }
}

/// The port the endpoint checks `Host` and the request MAC against: the one actually bound.
private final class PortBox: Sendable {
    private let value = Mutex<UInt16>(0)
    func get() -> UInt16 { value.withLock { $0 } }
    func set(_ p: UInt16) { value.withLock { $0 = p } }
}
