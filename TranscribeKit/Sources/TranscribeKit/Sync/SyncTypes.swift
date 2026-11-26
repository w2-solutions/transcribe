import Foundation

// Sync value types (§8.1). No CloudKit import in this folder: only `TranscribeCloudKit` imports CloudKit.

/// The record types in the `Library` zone. The raw value is the CloudKit record type and is stored in
/// `SyncRecordState.typeRaw`, so it must never change.
public enum SyncRecordType: String, CaseIterable, Sendable, Codable {
    case recording = "Recording", speaker = "Speaker", profile = "VoiceProfile", sample = "VoiceSample",
         negative = "VoiceNegative", folder = "Folder", groupLabel = "VoiceGroupLabel"

    /// The record-name prefix: "<prefix>.<UUID>".
    public var prefix: String {
        switch self {
        case .recording: "rec"
        case .speaker: "spk"
        case .profile: "vp"
        case .sample: "vs"
        case .negative: "vn"
        case .folder: "fd"
        case .groupLabel: "vg"
        }
    }

    /// Order in which fetched records are applied, so a link's target usually arrives before the record that names
    /// it (folders and profiles first, then recordings, their speakers, then samples, negatives and group labels).
    public var applyOrder: Int {
        switch self {
        case .folder: 0
        case .profile: 1
        case .recording: 2
        case .speaker: 3
        case .sample: 4
        case .negative: 5
        case .groupLabel: 6
        }
    }

    init?(prefix: Substring) {
        guard let type = Self.allCases.first(where: { $0.prefix == prefix }) else { return nil }
        self = type
    }
}

/// A record's identity: its type and the id of the local entity. The CloudKit record name is "<prefix>.<UUID>".
public struct SyncRecordID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let type: SyncRecordType
    public let entityID: UUID

    public init(type: SyncRecordType, entityID: UUID) { self.type = type; self.entityID = entityID }

    public var recordName: String { "\(type.prefix).\(entityID.uuidString)" }

    public init?(recordName: String) {
        guard let dot = recordName.firstIndex(of: "."),
              let type = SyncRecordType(prefix: recordName[..<dot]),
              let id = UUID(uuidString: String(recordName[recordName.index(after: dot)...])) else { return nil }
        self.init(type: type, entityID: id)
    }

    public var description: String { recordName }
}

/// One field value in its canonical form (§8.1). Dates are milliseconds since 1970, float arrays are little-endian
/// Float32 `.bytes`, booleans are `.int(0/1)` and an optional nil is `.null`. Projecting, applying and projecting
/// again gives identical values: that is what stops echo loops.
public enum SyncValue: Sendable, Equatable, Codable {
    case null, string(String), int(Int64), double(Double), dateMillis(Int64), bytes(Data), strings([String]), doubles([Double])
    case asset(Data)      // uncompressed payload; the transport compresses (LZFSE) and wraps in CKAsset

    // A compact, canonical JSON form. Doubles are written as their bit pattern so the encoding is exact (and NaN-safe);
    // group hashes are SHA-256 over this JSON with sorted keys.
    private enum Key: String, CodingKey { case n, s, i, d, t, b, ss, ds, a }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .null: try c.encode(true, forKey: .n)
        case .string(let v): try c.encode(v, forKey: .s)
        case .int(let v): try c.encode(v, forKey: .i)
        case .double(let v): try c.encode(Self.bits(v), forKey: .d)
        case .dateMillis(let v): try c.encode(v, forKey: .t)
        case .bytes(let v): try c.encode(v.base64EncodedString(), forKey: .b)
        case .strings(let v): try c.encode(v, forKey: .ss)
        case .doubles(let v): try c.encode(v.map(Self.bits), forKey: .ds)
        case .asset(let v): try c.encode(v.base64EncodedString(), forKey: .a)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "empty SyncValue"))
        }
        switch key {
        case .n: self = .null
        case .s: self = .string(try c.decode(String.self, forKey: .s))
        case .i: self = .int(try c.decode(Int64.self, forKey: .i))
        case .d: self = .double(try Self.double(c.decode(String.self, forKey: .d)))
        case .t: self = .dateMillis(try c.decode(Int64.self, forKey: .t))
        case .b: self = .bytes(try Self.data(c.decode(String.self, forKey: .b)))
        case .ss: self = .strings(try c.decode([String].self, forKey: .ss))
        case .ds: self = .doubles(try c.decode([String].self, forKey: .ds).map(Self.double))
        case .a: self = .asset(try Self.data(c.decode(String.self, forKey: .a)))
        }
    }

    private static func bits(_ v: Double) -> String { String(v.bitPattern, radix: 16) }
    private static func double(_ s: String) throws -> Double {
        guard let bits = UInt64(s, radix: 16) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad double \(s)"))
        }
        return Double(bitPattern: bits)
    }
    private static func data(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad base64"))
        }
        return d
    }
}

/// A record as the sync core sees it: canonical field values, plus the transport's opaque system fields
/// (`CKRecord.encodeSystemFields`, or the fake's change tag). Every record carries `sv` (the record schema version).
public struct SyncRecord: Sendable, Equatable {
    public var id: SyncRecordID
    public var fields: [String: SyncValue]
    public var systemFields: Data?
    public init(id: SyncRecordID, fields: [String: SyncValue], systemFields: Data? = nil) {
        self.id = id; self.fields = fields; self.systemFields = systemFields
    }
}

/// What a `SyncRecordState` row still has to do (`pendingRaw`).
public enum SyncPending: Int, Sendable {
    case none = 0, save = 1, delete = 2
    /// A remote delete waiting for the entity's recording to finish local processing.
    case parkedDelete = 3
}

/// Who is signed in to iCloud now, as the transport reports it. Hashes are `sha256(userRecordID.recordName)`.
public enum AccountChange: Sendable, Equatable {
    case signIn(String), signOut, switchAccounts(String)
}

/// Why the `Library` zone disappeared.
public enum ZoneDeletionReason: String, Sendable, Codable {
    case deleted, purged, encryptedDataReset
}

// MARK: - Typed accessors on the sync models (current schema)

public extension TranscribeSchemaV4.SyncRecordState {
    var pending: SyncPending {
        get { SyncPending(rawValue: pendingRaw) ?? .none }
        set { pendingRaw = newValue.rawValue }
    }
    var type: SyncRecordType? { SyncRecordType(rawValue: typeRaw) }
    var recordID: SyncRecordID? { type.map { SyncRecordID(type: $0, entityID: entityID) } }

    /// [group: hex sha256] as last agreed with the server; empty = never synced. Setting it (a new agreement with the
    /// server) also ends `mustMergeWithServer`.
    var baseHashes: [String: String] {
        get {
            var d = storedBaseJSON
            d.removeValue(forKey: Self.mustMergeKey)
            return d
        }
        set { baseHashesJSON = SyncSchema.sortedJSON(newValue) }
    }

    /// Kept inside `baseHashesJSON` (no group name starts with "~"), so the V3 store schema is unchanged.
    private static var mustMergeKey: String { "~mustMerge" }
    private var storedBaseJSON: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: baseHashesJSON)) ?? [:]
    }

    /// Marks that a server change was skipped while the entity was processed here: the next save is sent even when
    /// nothing changed locally. The row keeps its system fields (the old change tag), so that save meets
    /// `serverRecordChanged` and merges, or `unknownItem` when the record was deleted elsewhere meanwhile (delete
    /// wins). It never goes out as a create, which would bring a deleted record back.
    func markMustMergeWithServer() {
        var d = storedBaseJSON
        d[Self.mustMergeKey] = "1"
        baseHashesJSON = SyncSchema.sortedJSON(d)
    }

    /// [field: uuidString] links whose target has not arrived yet.
    var unresolvedLinks: [String: String] {
        get { unresolvedLinksJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { unresolvedLinksJSON = newValue.isEmpty ? nil : SyncSchema.sortedJSON(newValue) }
    }

    /// Never acknowledged by the server and no agreed base: the row says nothing about the server.
    var isFresh: Bool { systemFields == nil && baseHashes.isEmpty }

    /// A server change was skipped while the entity was processed here (`markMustMergeWithServer`), so the next save is
    /// sent even when nothing changed locally. (A base with no system fields is the older form of the same mark.)
    var mustMergeWithServer: Bool {
        storedBaseJSON[Self.mustMergeKey] != nil || (systemFields == nil && !baseHashes.isEmpty)
    }
}

public extension TranscribeSchemaV4.SyncAccountState {
    var pausedReason: SyncPauseReason? {
        get { pausedReasonRaw.flatMap(SyncPauseReason.init(rawValue:)) }
        set { pausedReasonRaw = newValue?.rawValue }
    }
}
