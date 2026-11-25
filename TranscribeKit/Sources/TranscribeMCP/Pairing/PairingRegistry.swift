import CryptoKit
import Foundation
import Synchronization

/// A Claude app the user allowed (Settings → Claude → Allowed apps). Saved in `ClaudeAccess.json`.
public struct AllowedClient: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var publicKey: String
    /// The pairing transcript the user allowed (its code is what they checked); signed calls must name it.
    public var pairing: String
    public var allowedAt: Date

    public init(id: String, name: String, publicKey: String, pairing: String, allowedAt: Date) {
        self.id = id; self.name = name; self.publicKey = publicKey; self.pairing = pairing; self.allowedAt = allowedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, publicKey = "public_key", pairing, allowedAt = "allowed_at"
    }

    /// Well-formed: a client id, a canonical public key, a transcript and a clean name.
    public var isValid: Bool {
        PairingCrypto.isClientID(id) && PairingCrypto.isPublicKey(publicKey) && PairingCrypto.isDigest(pairing)
            && ClientName.sanitized(name) == name
    }
}

/// A Claude app waiting for Allow or Don't Allow, after it revealed its nonce. Held in memory only; it expires.
public struct PendingRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var publicKey: String
    public var pairing: String
    /// "482 913": what Claude shows the user.
    public var code: String
    public var requestedAt: Date
    public var expiresAt: Date
}

/// Who may read through the app's endpoint, and the requests waiting for the user. Shared by the endpoint (any
/// thread) and the app's Settings (main actor); every change is under one lock. Nothing here is logged.
///
/// Pairing is commit, then reveal (`PairingCrypto`):
/// - `commit`: a client sends its key and a commitment; the app answers with a fresh nonce of its own and holds the
///   exchange, unrevealed and invisible, for `revealLifetime`. The same commitment again gets the same nonce; a new
///   commitment from the same client id and key restarts the exchange with a fresh nonce. A client id that is already
///   waiting, allowed or tied to another key is refused (`.conflict`): a nonce is never reused with another
///   commitment.
/// - `reveal`: the client's nonce must match its commitment (otherwise the exchange is dropped); only then does the
///   request become pending (shown to the user, with the code) for `pendingLifetime`.
/// - Unrevealed and pending requests together are at most `maxPending`, and at most `maxNewRequests` app nonces are
///   handed out per `requestWindow` (a restart counts); more are refused (`.busy`), never queued and never displacing
///   one already there. The nonce limit also bounds how often anyone can try for a chosen code.
/// - Don't Allow holds the client as denied for `denialHold`; afterwards it is forgotten, so a later request asks the
///   user again.
/// - With `autoAllow` (DEBUG test hook, session only) every revealed request is allowed at once.
public final class PairingRegistry: Sendable {
    public enum CommitAnswer: Sendable, Equatable { case reveal(appNonce: String), denied, busy, conflict }
    public enum RevealAnswer: String, Sendable, Equatable { case pending, allowed, denied, rejected, unknown }
    public enum Access: String, Sendable, Equatable { case allowed, pending, denied, unknown }
    public enum Change: Sendable, Equatable { case newRequest, updated }

    public struct Limits: Sendable, Equatable {
        public var maxPending = 3
        public var pendingLifetime: TimeInterval = 600
        public var revealLifetime: TimeInterval = 30
        public var denialHold: TimeInterval = 300
        public var requestWindow: TimeInterval = 600
        public var maxNewRequests = 5
        public init() {}
    }

    private struct Unrevealed { var id: String; var name: String; var publicKey: String; var commitment: String
                                var appNonce: String; var expiresAt: Date }
    private struct Waiting { var request: PendingRequest; var commitment: String; var appNonce: String }
    private struct Denied { var id: String; var publicKey: String; var until: Date }

    private struct State {
        var allowed: [AllowedClient]
        var unrevealed: [Unrevealed] = []
        var pending: [Waiting] = []
        var denied: [Denied] = []
        var recent: [Date] = []
        var autoAllow = false
        var onChange: (@Sendable (Change) -> Void)?

        mutating func prune(_ now: Date, window: TimeInterval) {
            unrevealed.removeAll { $0.expiresAt <= now }
            pending.removeAll { $0.request.expiresAt <= now }
            denied.removeAll { $0.until <= now }
            recent.removeAll { $0 <= now.addingTimeInterval(-window) }
        }
    }

    private let privateKey: String
    public let appPublicKey: String
    public let limits: Limits
    private let state: Mutex<State>

    /// `privateKey` is the app's own (stored form, from `PairingCrypto.newPrivateKey()`); nil when malformed.
    public init?(privateKey: String, allowed: [AllowedClient], limits: Limits = Limits()) {
        guard let publicKey = PairingCrypto.publicKey(ofPrivate: privateKey) else { return nil }
        self.privateKey = privateKey
        appPublicKey = publicKey
        self.limits = limits
        state = Mutex(State(allowed: allowed.filter(\.isValid)))
    }

    /// Called after each change, outside the lock, on whatever thread made it.
    public func setOnChange(_ handler: (@Sendable (Change) -> Void)?) { state.withLock { $0.onChange = handler } }

    public func setAutoAllow(_ on: Bool) { state.withLock { $0.autoAllow = on } }

    // MARK: - The endpoint

    /// The first half of a pairing request (`POST /pair` with a commitment). `name` must already be sanitised.
    public func commit(clientID: String, name: String, publicKey: String, commitment: String, now: Date) -> CommitAnswer {
        state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            if s.allowed.contains(where: { $0.id == clientID }) { return .conflict }
            if let w = s.pending.first(where: { $0.request.id == clientID }) {
                return w.request.publicKey == publicKey && w.commitment == commitment ? .reveal(appNonce: w.appNonce) : .conflict
            }
            if let d = s.denied.first(where: { $0.id == clientID }) { return d.publicKey == publicKey ? .denied : .conflict }
            if let i = s.unrevealed.firstIndex(where: { $0.id == clientID }) {
                let u = s.unrevealed[i]
                guard u.publicKey == publicKey else { return .conflict }
                if u.commitment == commitment { return .reveal(appNonce: u.appNonce) }
                // A restart: a fresh nonce for the new commitment, within the nonce limit.
                guard s.recent.count < limits.maxNewRequests else { return .busy }
                s.recent.append(now)
                let nonce = PairingCrypto.newNonce()
                s.unrevealed[i] = Unrevealed(id: clientID, name: name, publicKey: publicKey, commitment: commitment,
                                             appNonce: nonce, expiresAt: now.addingTimeInterval(limits.revealLifetime))
                return .reveal(appNonce: nonce)
            }
            guard s.pending.count + s.unrevealed.count < limits.maxPending, s.recent.count < limits.maxNewRequests else {
                return .busy
            }
            s.recent.append(now)
            let nonce = PairingCrypto.newNonce()
            s.unrevealed.append(Unrevealed(id: clientID, name: name, publicKey: publicKey, commitment: commitment,
                                           appNonce: nonce, expiresAt: now.addingTimeInterval(limits.revealLifetime)))
            return .reveal(appNonce: nonce)
        }
    }

    /// The second half: the client's nonce. A request becomes visible (pending) only here, and only when the nonce
    /// matches the commitment; a wrong nonce drops the exchange.
    public func reveal(clientID: String, publicKey: String, clientNonce: String, now: Date) -> RevealAnswer {
        let (answer, change): (RevealAnswer, Change?) = state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            let commitment = PairingCrypto.commitment(clientID: clientID, clientPublicKey: publicKey, clientNonce: clientNonce)
            if let w = s.pending.first(where: { $0.request.id == clientID && $0.request.publicKey == publicKey }) {
                return (w.commitment == commitment ? .pending : .rejected, nil)
            }
            if s.denied.contains(where: { $0.id == clientID && $0.publicKey == publicKey }) { return (.denied, nil) }
            guard let i = s.unrevealed.firstIndex(where: { $0.id == clientID && $0.publicKey == publicKey }) else {
                return (.unknown, nil)
            }
            let u = s.unrevealed.remove(at: i)
            guard u.commitment == commitment else { return (.rejected, nil) }
            let pairing = PairingCrypto.transcript(clientID: clientID, clientPublicKey: publicKey, appPublicKey: appPublicKey,
                                                   appNonce: u.appNonce, clientNonce: clientNonce)
            if s.autoAllow {
                s.allowed.append(AllowedClient(id: clientID, name: u.name, publicKey: publicKey, pairing: pairing, allowedAt: now))
                return (.allowed, .updated)
            }
            let request = PendingRequest(id: clientID, name: u.name, publicKey: publicKey, pairing: pairing,
                                         code: PairingCrypto.code(pairing: pairing), requestedAt: now,
                                         expiresAt: now.addingTimeInterval(limits.pendingLifetime))
            s.pending.append(Waiting(request: request, commitment: u.commitment, appNonce: u.appNonce))
            return (.pending, .newRequest)
        }
        if let change { notify(change) }
        return answer
    }

    /// What a signed call from this client id, key and pairing may do. Anything that does not match a record exactly
    /// is `.unknown`; an unrevealed exchange is never `.pending`.
    public func access(clientID: String, publicKey: String, pairing: String, now: Date) -> Access {
        state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            if s.allowed.contains(where: { $0.id == clientID && $0.publicKey == publicKey && $0.pairing == pairing }) {
                return .allowed
            }
            if s.pending.contains(where: { $0.request.id == clientID && $0.request.publicKey == publicKey
                && $0.request.pairing == pairing }) {
                return .pending
            }
            if s.denied.contains(where: { $0.id == clientID && $0.publicKey == publicKey }) { return .denied }
            return .unknown
        }
    }

    /// Whether this client id is allowed, pending or denied, whatever its key.
    public func knows(clientID: String, now: Date) -> Bool {
        state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            return s.allowed.contains { $0.id == clientID } || s.pending.contains { $0.request.id == clientID }
                || s.denied.contains { $0.id == clientID }
        }
    }

    /// The HMAC key for a pairing, derived from the app's private key, the client's public key and the transcript the
    /// call names (so the app can answer a client it does not know with a signed "unknown"). nil for malformed values.
    public func key(clientID: String, clientPublicKey: String, pairing: String) -> SymmetricKey? {
        PairingCrypto.sharedKey(privateKey: privateKey, peerPublicKey: clientPublicKey, clientID: clientID,
                                clientPublicKey: clientPublicKey, appPublicKey: appPublicKey, pairing: pairing)
    }

    // MARK: - Settings

    public var allowedClients: [AllowedClient] { state.withLock { $0.allowed } }

    /// The requests shown to the user: revealed ones only.
    public func pendingRequests(now: Date) -> [PendingRequest] {
        state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            return s.pending.map(\.request)
        }
    }

    /// When the next pending request expires (Settings refreshes then).
    public func nextExpiry(now: Date) -> Date? { pendingRequests(now: now).map(\.expiresAt).min() }

    /// Allow: false when the request is gone (expired, or answered elsewhere).
    @discardableResult public func allow(clientID: String, now: Date) -> Bool {
        let done: Bool = state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            guard let i = s.pending.firstIndex(where: { $0.request.id == clientID }) else { return false }
            let p = s.pending.remove(at: i).request
            s.allowed.append(AllowedClient(id: p.id, name: p.name, publicKey: p.publicKey, pairing: p.pairing, allowedAt: now))
            return true
        }
        if done { notify(.updated) }
        return done
    }

    /// Don't Allow: held as denied for `denialHold`.
    @discardableResult public func deny(clientID: String, now: Date) -> Bool {
        let done: Bool = state.withLock { s in
            s.prune(now, window: limits.requestWindow)
            guard let i = s.pending.firstIndex(where: { $0.request.id == clientID }) else { return false }
            let p = s.pending.remove(at: i).request
            s.denied.append(Denied(id: p.id, publicKey: p.publicKey, until: now.addingTimeInterval(limits.denialHold)))
            return true
        }
        if done { notify(.updated) }
        return done
    }

    /// Remove an allowed app; its next call is told it is unknown.
    @discardableResult public func remove(clientID: String) -> Bool {
        let done: Bool = state.withLock { s in
            let before = s.allowed.count
            s.allowed.removeAll { $0.id == clientID }
            return s.allowed.count != before
        }
        if done { notify(.updated) }
        return done
    }

    /// The switch went off: waiting requests, revealed or not, are dropped (allowed apps are kept).
    public func dropPending() {
        let done: Bool = state.withLock { s in
            defer { s.pending = []; s.unrevealed = [] }
            return !s.pending.isEmpty
        }
        if done { notify(.updated) }
    }

    private func notify(_ change: Change) {
        state.withLock { $0.onChange }?(change)
    }
}
