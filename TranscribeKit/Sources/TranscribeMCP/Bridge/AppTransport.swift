import CryptoKit
import Foundation

/// How a signed call to one port fared (§2.4, §3.2). Only `.message`, `.accepted` and `.pairing` came from the app
/// the helper paired with: their replies verified against the derived key.
public enum AppReply: Sendable, Equatable {
    case message(Data)
    case accepted
    /// Signed: the app knows the key but has not allowed this client (yet, or any more).
    case pairing(PairingState)
    /// Nothing listens on the port (-1004).
    case refused
    /// The connection dropped mid-request (-1005). Never triggers a launch.
    case connectionLost
    /// 401: the signature did not verify there.
    case unauthorized
    /// 401 marked "unknown" (unsigned): what answered on that port claims it has no record of this client. Unsigned,
    /// so the helper never drops its pairing for it.
    case unknownClient
    /// 503: sharing was just turned off.
    case notServing
    /// A 200, 202 or 403 without a valid MAC, or an oversize reply: something other than the paired app answered.
    case impostor
    case timedOut
    /// Any other HTTP status, or a URL error's code.
    case httpError(Int)
}

/// The app's signed answer for a client it has not allowed.
public enum PairingState: String, Sendable, Equatable { case pending, denied, unknown }

/// The status a pairing request got.
public enum PairStatus: String, Sendable, Equatable { case pending, allowed, denied }

/// How one step of a pairing request to one port fared.
public enum PairReply: Sendable, Equatable {
    /// The commitment was taken: the app's public key and its fresh nonce. The helper now reveals its own nonce.
    case reveal(appPublicKey: String, appNonce: String)
    /// A status: after a reveal (pending, allowed or denied), or for a commitment from a client held as denied.
    case status(PairStatus)
    /// 429: too many requests are waiting, or arrived lately.
    case busy
    /// 409: the client id is tied to another exchange (or, for a reveal, there is no exchange any more).
    case conflict
    case refused
    case notServing
    case connectionLost
    case timedOut
    /// Anything else: not Transcribe, or a request Transcribe would not take (a reveal that does not match, 400).
    case invalid
}

/// The first step of `POST /pair`: the helper's key and a commitment to its nonce (`PairingCrypto.commitment`).
public struct PairingRequest: Sendable, Equatable {
    public var clientID: String
    public var clientName: String
    public var publicKey: String
    public var commitment: String

    public init(clientID: String, clientName: String, publicKey: String, commitment: String) {
        self.clientID = clientID; self.clientName = clientName; self.publicKey = publicKey; self.commitment = commitment
    }

    public var body: Data {
        JSONValue.object(["v": 2, "client_id": .string(clientID), "client_name": .string(clientName),
                          "client_key": .string(publicKey), "commit": .string(commitment)]).encoded()
    }
}

/// The second step of `POST /pair`: the nonce the commitment was made to.
public struct PairingReveal: Sendable, Equatable {
    public var clientID: String
    public var publicKey: String
    public var clientNonce: String

    public init(clientID: String, publicKey: String, clientNonce: String) {
        self.clientID = clientID; self.publicKey = publicKey; self.clientNonce = clientNonce
    }

    public var body: Data {
        JSONValue.object(["v": 2, "client_id": .string(clientID), "client_key": .string(publicKey),
                          "reveal": .string(clientNonce)]).encoded()
    }
}

/// Talks to whatever listens on one loopback port.
public protocol AppTransport: Sendable {
    /// One signed JSON-RPC message.
    func post(_ body: Data, protocolVersion: String, port: UInt16, credentials: ClientCredentials) async -> AppReply
    /// The commitment step of a pairing request.
    func pair(_ request: PairingRequest, port: UInt16) async -> PairReply
    /// The reveal step, to the port that took the commitment.
    func reveal(_ reveal: PairingReveal, port: UInt16) async -> PairReply
}

/// Posts to `http://127.0.0.1:<port>/mcp` and `/pair`, signing each call and checking the signature on each reply
/// (§3.2). The session is ephemeral, with no proxy, cookies, cache or redirects.
public struct URLSessionAppTransport: AppTransport {
    private let maxResponse: Int
    private let session: URLSession

    public init(timeout: TimeInterval = 30, maxResponse: Int = 2_097_152) {
        self.maxResponse = maxResponse
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func post(_ body: Data, protocolVersion: String, port: UInt16, credentials: ClientCredentials) async -> AppReply {
        let nonce = MessageAuth.newNonce()
        var request = Self.request(port: port, path: "/mcp", body: body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(MessageAuth.signRequest(body: body, credentials: credentials, port: port, now: Date(), nonce: nonce),
                         forHTTPHeaderField: "Authorization")
        let reply: (HTTPURLResponse, Data?)
        switch await send(request) {
        case .failure(let failure): return failure.appReply
        case .success(let r): reply = r
        }
        let (http, data) = reply
        switch http.statusCode {
        case 200, 202, 403:
            // Read at most maxResponse bytes; a longer reply is not Transcribe's.
            guard let data else { return .impostor }
            let mac = http.value(forHTTPHeaderField: MessageAuth.responseHeader)
            guard MessageAuth.verifyResponse(mac, status: http.statusCode, body: data, nonce: nonce, key: credentials.key) else {
                return http.statusCode == 403 ? .httpError(403) : .impostor
            }
            switch http.statusCode {
            case 200: return .message(data)
            case 202: return .accepted
            default:
                guard let raw = (try? JSONValue.decode(data))?["pairing"]?.string, let state = PairingState(rawValue: raw) else {
                    return .httpError(403)
                }
                return .pairing(state)
            }
        case 401:
            return http.value(forHTTPHeaderField: MessageAuth.pairingHeader) == "unknown" ? .unknownClient : .unauthorized
        case 503:
            return .notServing
        default:
            return .httpError(http.statusCode)
        }
    }

    public func pair(_ pairing: PairingRequest, port: UInt16) async -> PairReply {
        await pairStep(pairing.body, port: port) { o in
            if Set(o.keys) == ["v", "status", "app_key", "app_nonce"], o["status"] == "reveal",
               let key = o["app_key"]?.string, PairingCrypto.isPublicKey(key),
               let nonce = o["app_nonce"]?.string, PairingCrypto.isNonce(nonce) {
                return .reveal(appPublicKey: key, appNonce: nonce)
            }
            if Set(o.keys) == ["v", "status", "app_key"], o["status"] == "denied",
               let key = o["app_key"]?.string, PairingCrypto.isPublicKey(key) {
                return .status(.denied)
            }
            return .invalid
        }
    }

    public func reveal(_ reveal: PairingReveal, port: UInt16) async -> PairReply {
        await pairStep(reveal.body, port: port) { o in
            guard Set(o.keys) == ["v", "status"], let status = o["status"]?.string.flatMap(PairStatus.init(rawValue:)) else {
                return .invalid
            }
            return .status(status)
        }
    }

    /// Posts one pairing step and reads its `{"v":2,…}` answer with `read`.
    private func pairStep(_ body: Data, port: UInt16, read: ([String: JSONValue]) -> PairReply) async -> PairReply {
        let reply: (HTTPURLResponse, Data?)
        switch await send(Self.request(port: port, path: "/pair", body: body), limit: 4_096) {
        case .failure(let failure):
            switch failure {
            case .refused: return .refused
            case .lost: return .connectionLost
            case .timedOut: return .timedOut
            case .other: return .invalid
            }
        case .success(let r): reply = r
        }
        let (http, data) = reply
        switch http.statusCode {
        case 200:
            guard let data, case .object(let o)? = try? JSONValue.decode(data), o["v"] == .int(2) else { return .invalid }
            return read(o)
        case 409: return .conflict
        case 429: return .busy
        case 503: return .notServing
        default: return .invalid
        }
    }

    // MARK: - Sending

    private enum Failure: Error {
        case refused, lost, timedOut, other(Int)

        var appReply: AppReply {
            switch self {
            case .refused: .refused
            case .lost: .connectionLost
            case .timedOut: .timedOut
            case .other(let code): .httpError(code)
            }
        }
    }

    private static func request(port: UInt16, path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// The response and its body; the body is nil when it ran past `limit` (or `maxResponse`).
    private func send(_ request: URLRequest, limit: Int? = nil) async -> Result<(HTTPURLResponse, Data?), Failure> {
        let limit = limit ?? maxResponse
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.other(0)) }
            if http.expectedContentLength > Int64(limit) { bytes.task.cancel(); return .success((http, nil)) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { bytes.task.cancel(); return .success((http, nil)) }
                data.append(byte)
            }
            return .success((http, data))
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost: return .failure(.refused)
            case .networkConnectionLost: return .failure(.lost)
            case .timedOut: return .failure(.timedOut)
            default: return .failure(.other(error.code.rawValue))
            }
        } catch {
            return .failure(.other(NSURLErrorUnknown))
        }
    }
}

/// Never follows a redirect: whatever holds the port must not send the signed request, and the arguments in it, on to
/// another address. The 3xx itself comes back as `.httpError` (or `.invalid` for a pairing request).
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
