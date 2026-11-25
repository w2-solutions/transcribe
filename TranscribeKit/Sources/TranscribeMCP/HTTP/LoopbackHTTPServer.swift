import Foundation
import Network
import Synchronization

public enum LoopbackError: Error, Equatable, Sendable {
    /// EADDRINUSE: another socket holds the port.
    case portInUse(UInt16)
    /// EPERM or EACCES: the sandbox denied the bind (no `network.server` entitlement).
    case notPermitted
    /// Anything else, as a short errno name such as "EADDRNOTAVAIL" (never a path).
    case other(String)
}

/// A one-route HTTP/1.1 server on `127.0.0.1` only (§3.1, D5). One request per connection, then `Connection: close`.
/// Limits: 16 open connections, the header section within 2 s of accept and the whole request within 10 s of accept
/// (absolute deadlines). At the cap the oldest connection still sending headers makes room; if every connection has
/// finished its headers, the new one is dropped. All Network callbacks run on one private serial queue.
public final class LoopbackHTTPServer: Sendable {
    private enum Phase { case headers, body, handling }

    private struct Entry {
        let connection: NWConnection
        let acceptedAt: ContinuousClock.Instant
        var phase: Phase
    }

    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: Entry] = [:]
    }

    /// Resumes the pending `start()` once; afterwards a listener failure goes to `onFailure`.
    private final class Pending: Sendable {
        let continuation: Mutex<CheckedContinuation<Result<UInt16, LoopbackError>, Never>?>
        init(_ c: CheckedContinuation<Result<UInt16, LoopbackError>, Never>) { continuation = Mutex(c) }
        func resume(_ r: Result<UInt16, LoopbackError>) -> Bool {
            guard let c = continuation.withLock({ c in defer { c = nil }; return c }) else { return false }
            c.resume(returning: r)
            return true
        }
    }

    private let port: UInt16
    private let headerDeadline: Duration
    private let requestDeadline: Duration
    private let maxConnections: Int
    private let onFailure: @Sendable (LoopbackError) -> Void
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    /// `HTTPRequestParser.parse`; tests wrap it to count calls.
    private let parse: @Sendable (Data) -> HTTPParse
    private let queue = DispatchQueue(label: "ai.w2solutions.transcribe.mcp.http")
    private let state = Mutex(State())

    /// `port` 0 binds any free port (UI tests and tests); `start()` returns the port bound. `onFailure` is called when
    /// a listener that was ready fails later (the app then shows "Couldn't start").
    public convenience init(port: UInt16, headerDeadline: Duration = .seconds(2), requestDeadline: Duration = .seconds(10),
                            maxConnections: Int = 16, onFailure: @escaping @Sendable (LoopbackError) -> Void = { _ in },
                            handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.init(port: port, headerDeadline: headerDeadline, requestDeadline: requestDeadline,
                  maxConnections: maxConnections, onFailure: onFailure, parse: { HTTPRequestParser.parse($0) },
                  handler: handler)
    }

    init(port: UInt16, headerDeadline: Duration, requestDeadline: Duration, maxConnections: Int,
         onFailure: @escaping @Sendable (LoopbackError) -> Void, parse: @escaping @Sendable (Data) -> HTTPParse,
         handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port; self.headerDeadline = headerDeadline; self.requestDeadline = requestDeadline
        self.maxConnections = maxConnections; self.onFailure = onFailure; self.parse = parse; self.handler = handler
    }

    /// Binds `127.0.0.1:<port>` and returns the port once the listener is ready.
    public func start() async throws(LoopbackError) -> UInt16 {
        stop()
        let params = NWParameters.tcp
        // Never share the port: a second binder gets EADDRINUSE (spike A). SO_REUSEPORT is never set.
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw Self.map(error, port: port) }

        let result: Result<UInt16, LoopbackError> = await withCheckedContinuation { c in
            let pending = Pending(c)
            let requested = port
            listener.stateUpdateHandler = { [weak self, weak listener] update in
                switch update {
                case .ready:
                    _ = pending.resume(.success(listener?.port?.rawValue ?? requested))
                case .failed(let error), .waiting(let error):
                    let mapped = Self.map(error, port: requested)
                    listener?.cancel()
                    if !pending.resume(.failure(mapped)), let self, let listener, self.isCurrent(listener) {
                        self.stop()
                        self.onFailure(mapped)
                    }
                case .cancelled:
                    _ = pending.resume(.failure(.other("ECANCELED")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            state.withLock { $0.listener = listener }
            listener.start(queue: queue)
        }
        return try result.get()
    }

    /// Cancels the listener and every open connection.
    public func stop() {
        let (listener, connections) = state.withLock { s in
            defer { s.listener = nil; s.connections = [:] }
            return (s.listener, s.connections.values.map(\.connection))
        }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func isCurrent(_ listener: NWListener) -> Bool { state.withLock { $0.listener === listener } }

    // MARK: - Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, case .ipv4(let address) = host,
              address.rawValue == IPv4Address.loopback.rawValue else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        let now = ContinuousClock.now
        let (admitted, evicted): (Bool, NWConnection?) = state.withLock { s in
            guard s.listener != nil else { return (false, nil) }
            var evicted: NWConnection?
            if s.connections.count >= maxConnections {
                guard let oldest = s.connections.filter({ $0.value.phase == .headers })
                    .min(by: { $0.value.acceptedAt < $1.value.acceptedAt }) else { return (false, nil) }
                s.connections[oldest.key] = nil
                evicted = oldest.value.connection
            }
            s.connections[id] = Entry(connection: connection, acceptedAt: now, phase: .headers)
            return (true, evicted)
        }
        evicted?.cancel()
        guard admitted else { connection.cancel(); return }

        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard let connection else { return }
            switch update {
            case .failed, .waiting:
                connection.cancel()
            case .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.interval(headerDeadline)) { [weak self] in
            self?.expire(connection, during: [.headers])
        }
        queue.asyncAfter(deadline: .now() + Self.interval(requestDeadline)) { [weak self] in
            self?.expire(connection, during: [.headers, .body])
        }
        receive(connection, Received())
    }

    /// What one connection has sent so far. Only `queue` touches it, and nothing else holds the buffer, so an append
    /// never copies it. `total` is set once the header section has been parsed: the request's full byte count.
    private final class Received: @unchecked Sendable {
        var buffer = Data()
        var total: Int?
    }

    private func receive(_ connection: NWConnection, _ received: Received) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data { received.buffer.append(data) }
            let ended = isComplete || error != nil
            // The header section is parsed once; until the body is all here, only count its bytes.
            if let total = received.total, received.buffer.count < total {
                self.continueReceiving(connection, received, ended: ended)
                return
            }
            switch self.parse(received.buffer) {
            case .reject(let response):
                self.respond(connection, response)
            case .request(let request):
                guard self.move(connection, to: .handling) else { connection.cancel(); return }
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.respond(connection, response)
                }
            case .headersComplete(let total):
                received.total = total
                _ = self.move(connection, to: .body)
                self.continueReceiving(connection, received, ended: ended)
            case .needMore:
                self.continueReceiving(connection, received, ended: ended)
            }
        }
    }

    private func continueReceiving(_ connection: NWConnection, _ received: Received, ended: Bool) {
        if ended { connection.cancel() } else { receive(connection, received) }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Records a connection's progress; false when it is no longer tracked (stopped, evicted or expired).
    private func move(_ connection: NWConnection, to phase: Phase) -> Bool {
        state.withLock { s in
            let id = ObjectIdentifier(connection)
            guard s.connections[id]?.connection === connection else { return false }
            s.connections[id]?.phase = phase
            return true
        }
    }

    private func expire(_ connection: NWConnection, during phases: Set<Phase>) {
        let expired = state.withLock { s in
            let id = ObjectIdentifier(connection)
            guard let entry = s.connections[id], entry.connection === connection, phases.contains(entry.phase) else {
                return false
            }
            s.connections[id] = nil
            return true
        }
        if expired { connection.cancel() }
    }

    private func forget(_ connection: NWConnection) {
        state.withLock { s in
            let id = ObjectIdentifier(connection)
            if s.connections[id]?.connection === connection { s.connections[id] = nil }
        }
    }

    // MARK: - Helpers

    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = d.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    static func map(_ error: any Error, port: UInt16) -> LoopbackError {
        guard let error = error as? NWError, case .posix(let code) = error else { return .other("ENETWORK") }
        switch code {
        case .EADDRINUSE: return .portInUse(port)
        case .EPERM, .EACCES: return .notPermitted
        case .EADDRNOTAVAIL: return .other("EADDRNOTAVAIL")
        case .ECANCELED: return .other("ECANCELED")
        default: return .other("errno \(code.rawValue)")
        }
    }
}
