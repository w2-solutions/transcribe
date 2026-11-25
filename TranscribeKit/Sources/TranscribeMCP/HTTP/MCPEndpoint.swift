import CryptoKit
import Foundation
import os

/// The app's loopback endpoint (§3.1): `POST /pair` for a pairing request and `POST /mcp` for signed calls. The
/// common checks (path, method, Host, Origin, serving) run first. A signed call is checked with the key derived for
/// its client, then answered by `MCPServer` only when the user allowed that client; a pending, denied or unknown
/// client gets a signed 403 saying which, and never any data. Replies from there on are signed for the nonce the
/// request carried, so the helper can tell them from anything else that answers on the port. Nothing here logs keys,
/// codes, client names, arguments or transcript text.
public struct MCPEndpoint: Sendable {
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "mcp")
    /// JSON-RPC methods and tool names logged by name; anything else (client-chosen text) is logged as "other".
    private static let knownMethods: Set<String> = ["initialize", "ping", "tools/list", "tools/call", "server/discover",
                                                    "notifications/initialized", "notifications/cancelled"]
    private static let knownTools: Set<String> = [ToolCatalog.listRecordings, ToolCatalog.getTranscript]
    /// The largest pairing request body accepted.
    public static let maxPairBody = 1_024

    private let port: @Sendable () -> UInt16
    private let state: EndpointState
    private let pairing: PairingRegistry
    private let replay: ReplayGuard
    private let server: MCPServer
    private let now: @Sendable () -> Date

    public init(port: @escaping @Sendable () -> UInt16, state: EndpointState, pairing: PairingRegistry, replay: ReplayGuard,
                server: MCPServer, now: @escaping @Sendable () -> Date = Date.init) {
        self.port = port; self.state = state; self.pairing = pairing; self.replay = replay; self.server = server; self.now = now
    }

    public func handle(_ r: HTTPRequest) async -> HTTPResponse {
        guard r.path == "/mcp" || r.path == "/pair" else { return HTTPResponse(status: 404) }
        guard r.method == "POST" else { return HTTPResponse(status: 405, headers: [("Allow", "POST")]) }
        let port = port()
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost"]
        guard let host = r.headers["host"]?.lowercased(), hosts.contains(host) else { return HTTPResponse(status: 403) }
        guard r.headers["origin"] == nil else { return HTTPResponse(status: 403) }
        guard state.serving else { return HTTPResponse(status: 503) }
        return r.path == "/pair" ? pair(r) : await call(r, port: port)
    }

    // MARK: - POST /pair

    /// A pairing request, in two steps (commit, then reveal; `PairingRegistry`), nothing else in either body:
    /// - `{"v":2,"client_id":…,"client_name":…,"client_key":…,"commit":…}` gets
    ///   `{"v":2,"status":"reveal","app_key":…,"app_nonce":…}` (or `"status":"denied"` with the key), 429 or 409;
    /// - `{"v":2,"client_id":…,"client_key":…,"reveal":…}` gets `{"v":2,"status":"pending"|"allowed"|"denied"}`,
    ///   400 for a nonce that does not match the commitment, or 409 when there is no such exchange.
    /// Replies never hold anything about the library.
    private func pair(_ r: HTTPRequest) -> HTTPResponse {
        guard Self.isJSON(r) else { return HTTPResponse(status: 415) }
        guard r.body.count <= Self.maxPairBody else { return HTTPResponse(status: 413) }
        guard case .object(let o)? = try? JSONValue.decode(r.body), o["v"] == .int(2),
              let id = o["client_id"]?.string, PairingCrypto.isClientID(id),
              let key = o["client_key"]?.string, PairingCrypto.isPublicKey(key) else { return Self.badPair() }
        let keys = Set(o.keys)
        if keys == ["v", "client_id", "client_name", "client_key", "commit"] {
            guard let commitment = o["commit"]?.string, PairingCrypto.isDigest(commitment),
                  let name = ClientName.sanitized(o["client_name"]?.string) else { return Self.badPair() }
            let answer = pairing.commit(clientID: id, name: name, publicKey: key, commitment: commitment, now: now())
            switch answer {
            case .reveal(let appNonce):
                Self.log.info("pair answer=reveal")
                return Self.json(["v": 2, "status": "reveal", "app_key": .string(pairing.appPublicKey),
                                  "app_nonce": .string(appNonce)])
            case .denied:
                Self.log.info("pair answer=denied")
                return Self.json(["v": 2, "status": "denied", "app_key": .string(pairing.appPublicKey)])
            case .busy:
                Self.log.info("pair answer=busy")
                return HTTPResponse(status: 429)
            case .conflict:
                Self.log.info("pair answer=conflict")
                return HTTPResponse(status: 409)
            }
        }
        guard keys == ["v", "client_id", "client_key", "reveal"], let nonce = o["reveal"]?.string,
              PairingCrypto.isNonce(nonce) else { return Self.badPair() }
        let answer = pairing.reveal(clientID: id, publicKey: key, clientNonce: nonce, now: now())
        Self.log.info("reveal answer=\(answer.rawValue, privacy: .public)")
        switch answer {
        case .pending, .allowed, .denied: return Self.json(["v": 2, "status": .string(answer.rawValue)])
        case .rejected: return HTTPResponse(status: 400)
        case .unknown: return HTTPResponse(status: 409)
        }
    }

    private static func badPair() -> HTTPResponse {
        log.info("pair rejected status=400")
        return HTTPResponse(status: 400)
    }

    private static func json(_ o: [String: JSONValue]) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: JSONValue.object(o).encoded())
    }

    // MARK: - POST /mcp

    private func call(_ r: HTTPRequest, port: UInt16) async -> HTTPResponse {
        let time = now()
        guard let fields = MessageAuth.parse(r.headers["authorization"]),
              let key = pairing.key(clientID: fields.client, clientPublicKey: fields.publicKey, pairing: fields.pairing) else {
            Self.log.info("auth rejected status=401 reason=format")
            return HTTPResponse(status: 401)
        }
        let nonce: String
        switch MessageAuth.checkRequest(fields, body: r.body, key: key, port: port, now: time, notBefore: state.servingSince) {
        case .failure(let reason):
            Self.log.info("auth rejected status=401 reason=\(reason.rawValue, privacy: .public)")
            // No record of this client at all: say so (a helper paired with a key this app no longer has). Unsigned, so
            // the helper only reports it to the user and never pairs again because of it.
            guard pairing.knows(clientID: fields.client, now: time) else {
                return HTTPResponse(status: 401, headers: [(MessageAuth.pairingHeader, "unknown")])
            }
            return HTTPResponse(status: 401)
        case .success(let n):
            nonce = n
        }

        let access = pairing.access(clientID: fields.client, publicKey: fields.publicKey, pairing: fields.pairing, now: time)
        guard access == .allowed else {
            // Signed, so the helper can trust it: wait for the user, give up, or ask again. Checked before the replay
            // guard: anyone can sign as a client of their own making, so only allowed clients may fill the guard (a
            // replayed 403 carries nothing).
            Self.log.info("auth rejected status=403 reason=\(access.rawValue, privacy: .public)")
            return Self.signed(403, JSONValue.object(["pairing": .string(access.rawValue)]).encoded(), nonce: nonce, key: key)
        }
        switch replay.check(nonce, at: time) {
        case .admitted: break
        case .replayed:
            Self.log.info("auth rejected status=401 reason=replay")
            return HTTPResponse(status: 401)
        case .full:
            Self.log.error("auth rejected status=503 reason=replay")
            return HTTPResponse(status: 503)
        }

        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Answering Claude")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let started = ContinuousClock.now
        let (status, body) = await answer(r)
        logRequest(r.body, status: status, since: started)
        return Self.signed(status, body, nonce: nonce, key: key)
    }

    private static func signed(_ status: Int, _ body: Data, nonce: String, key: SymmetricKey) -> HTTPResponse {
        var headers: [(String, String)] = []
        if status == 200 || status == 403 && !body.isEmpty { headers.append(("Content-Type", "application/json")) }
        headers.append((MessageAuth.responseHeader, MessageAuth.signResponse(status: status, body: body, nonce: nonce, key: key)))
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    private static func isJSON(_ r: HTTPRequest) -> Bool {
        r.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// Steps 8–13: everything after authentication.
    private func answer(_ r: HTTPRequest) async -> (Int, Data) {
        guard Self.isJSON(r) else { return (415, Data()) }
        guard MCPVersion.headerAllowed(r.headers["mcp-protocol-version"]) else { return (400, Data()) }
        switch await server.handle(r.body) {
        case .badRequest(let d): return (400, d)
        case .accepted: return (202, Data())
        case .message(let d): return (200, d)
        }
    }

    private func logRequest(_ body: Data, status: Int, since start: ContinuousClock.Instant) {
        var method = "-", tool = "-"
        if case .success(let m) = RPCMessage.parse(body) {
            switch m {
            case .request(_, let name, let params), .notification(let name, let params):
                method = Self.knownMethods.contains(name) ? name : "other"
                if name == "tools/call", let t = params?["name"]?.string { tool = Self.knownTools.contains(t) ? t : "other" }
            case .response: method = "response"
            }
        }
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        Self.log.info("request method=\(method, privacy: .public) tool=\(tool, privacy: .public) status=\(status, privacy: .public) ms=\(ms, privacy: .public)")
    }
}
