import CryptoKit
import Foundation
import TranscribeCore

/// The record mapping (§8.2): which fields each record type carries, grouped into the units that merge together.
///
/// Every record also carries `sv` (the record schema version), which belongs to no group. A group's hash is the
/// SHA-256 of the JSON of its `[field: SyncValue]`, encoded with sorted keys. A field missing from a record hashes
/// as `.null`, so an older record without a new optional field compares equal to one that has it as nil.
///
/// A field added to an existing group after that group's hashes were first agreed with the server
/// (`addedFields`) is left out of the group's values, and so out of its hash, while it is null. So every record that
/// does not use it (all of them, right after the upgrade) hashes exactly as the base hashes an older build agreed,
/// and the upgrade queues nothing. A value changes the hash as any field does.
public enum SyncSchema {
    /// The record schema version this build writes and understands. A fetched record with a higher `sv` pauses sync.
    public static let version: Int64 = 1
    public static let versionField = "sv"

    public enum Group {
        // Recording
        public static let meta = "meta", title = "title", fav = "fav", folder = "folder", result = "result"
        // Speaker
        public static let ident = "ident", stats = "stats", label = "label", rejected = "rejected"
        // VoiceProfile (meta is shared)
        public static let name = "name", me = "me", auto = "auto", colour = "colour", model = "model"
        // VoiceSample, VoiceNegative, VoiceGroupLabel
        public static let body = "body"
    }

    /// group → fields, per type.
    public static func groups(_ type: SyncRecordType) -> [String: [String]] {
        switch type {
        case .recording:
            [Group.meta: ["createdAt", "source", "captureChannel", "captureDetail", "language"],
             Group.title: ["title"],
             Group.fav: ["isFavourite"],
             Group.folder: ["folderID"],
             Group.result: ["duration", "noSpeech", "marks", "peaks", "asrModelID", "embeddingModelKey", "transcript"]]
        case .speaker:
            [Group.ident: ["recordingID", "key", "ordinal", "colourSlot", "cleanSeconds", "vector", "embeddingModelKey",
                           "vectorCoherence"],
             // `captureSource` (V5, Mac audio) is here because "Same as" changes it together with the turn counts.
             Group.stats: ["turnCount", "totalSeconds", "captureSource"],
             Group.label: ["label", "profileID", "suggestedProfileID", "nameSnapshot", "matchScore", "matchMargin"],
             Group.rejected: ["rejectedProfileIDs"]]
        case .profile:
            [Group.name: ["name", "namedAt"],
             Group.me: ["isMe"],
             Group.auto: ["autoLabel"],
             Group.colour: ["colourSlot"],
             Group.meta: ["createdAt"],
             Group.model: ["embeddingModelKey"]]
        case .sample:
            [Group.body: ["profileID", "vector", "embeddingModelKey", "origin", "addedAt", "speechSeconds",
                          "sourceRecordingID", "sourceSpeakerID", "clipStart", "clipEnd", "quote", "captureChannel",
                          "captureInput"]]
        case .negative:
            [Group.body: ["profileID", "vector", "embeddingModelKey", "addedAt", "speechSeconds", "sourceRecordingID",
                          "sourceSpeakerID", "captureChannel", "captureInput"]]
        case .folder:
            [Group.name: ["name"], Group.meta: ["createdAt"]]
        case .groupLabel:
            // One group: a Save writes the text, the date and the anchor together, so they never merge apart.
            [Group.body: ["profileID", "text", "createdAt", "editedAt", "embeddingModelKey", "captureChannel", "anchor",
                          "anchorDimension"]]
        }
    }

    /// Fields added to an existing group after its hashes were agreed (see the type's doc): omitted while null.
    public static func addedFields(_ type: SyncRecordType) -> Set<String> {
        switch type {
        case .speaker: ["captureSource"]   // V5 (2026-11-26)
        default: []
        }
    }

    /// Group names of a type, sorted (a stable order for merges and tests).
    public static func groupNames(_ type: SyncRecordType) -> [String] { groups(type).keys.sorted() }

    /// Link fields: a plain id string naming another record. A target that has not arrived is kept in
    /// `SyncRecordState.unresolvedLinks` and still projected, so a missing link is never uploaded as cleared.
    public static func linkFields(_ type: SyncRecordType) -> [String: SyncRecordType] {
        switch type {
        case .recording: ["folderID": .folder]
        case .speaker: ["recordingID": .recording, "profileID": .profile]
        case .sample, .negative, .groupLabel: ["profileID": .profile]
        case .profile, .folder: [:]
        }
    }

    /// The record's schema version (`sv`), 1 when absent.
    public static func recordVersion(_ record: SyncRecord) -> Int64 {
        if case .int(let v)? = record.fields[versionField] { return v }
        return 1
    }

    /// The values of one group (missing fields read as `.null`; an `addedFields` field that is null is left out).
    public static func values(_ fields: [String: SyncValue], group: String, type: SyncRecordType) -> [String: SyncValue] {
        var out: [String: SyncValue] = [:]
        let added = addedFields(type)
        for f in groups(type)[group] ?? [] {
            let value = fields[f] ?? .null
            if value == .null, added.contains(f) { continue }
            out[f] = value
        }
        return out
    }

    /// [group: hex sha256] for a record's fields.
    public static func hashes(_ fields: [String: SyncValue], type: SyncRecordType) -> [String: String] {
        var out: [String: String] = [:]
        for g in groups(type).keys { out[g] = hash(values(fields, group: g, type: type)) }
        return out
    }

    public static func hashes(_ record: SyncRecord) -> [String: String] { hashes(record.fields, type: record.id.type) }

    static func hash(_ values: [String: SyncValue]) -> String {
        hex(SHA256.hash(data: canonicalJSON(values)))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in bytes { out.append(hexDigits[Int(b >> 4)]); out.append(hexDigits[Int(b & 0xF)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The JSON of a group's values with sorted keys, written by hand so hashing is fast and its bytes never depend on
    /// an encoder's formatting choices. It is the same document `SyncValue`'s `Codable` form describes: each value is a
    /// one-key object (`{"s":…}`, `{"d":"<bit pattern hex>"}`, …), strings escaped as JSON requires.
    static func canonicalJSON(_ values: [String: SyncValue]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        out.append(UInt8(ascii: "{"))
        for (i, key) in values.keys.sorted().enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            writeString(key, into: &out)
            out.append(UInt8(ascii: ":"))
            writeValue(values[key]!, into: &out)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    private static func writeValue(_ v: SyncValue, into out: inout [UInt8]) {
        // Tags, digits, hex and base64 never need escaping, so they are appended as they are.
        func open(_ tag: StaticString) {
            out.append(UInt8(ascii: "{"))
            out.append(UInt8(ascii: "\""))
            out.append(contentsOf: UnsafeBufferPointer(start: tag.utf8Start, count: tag.utf8CodeUnitCount))
            out.append(UInt8(ascii: "\""))
            out.append(UInt8(ascii: ":"))
        }
        func plain(_ s: String) {
            out.append(UInt8(ascii: "\""))
            out.append(contentsOf: s.utf8)
            out.append(UInt8(ascii: "\""))
        }
        switch v {
        case .null: open("n"); out.append(contentsOf: "true".utf8)
        case .string(let s): open("s"); writeString(s, into: &out)
        case .int(let i): open("i"); out.append(contentsOf: String(i).utf8)
        case .double(let d): open("d"); plain(String(d.bitPattern, radix: 16))
        case .dateMillis(let t): open("t"); out.append(contentsOf: String(t).utf8)
        case .bytes(let d): open("b"); plain(d.base64EncodedString())
        case .strings(let a):
            open("ss")
            out.append(UInt8(ascii: "["))
            for (i, s) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(s, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .doubles(let a):
            open("ds")
            out.append(UInt8(ascii: "["))
            for (i, d) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                plain(String(d.bitPattern, radix: 16))
            }
            out.append(UInt8(ascii: "]"))
        case .asset(let d): open("a"); plain(d.base64EncodedString())
        }
        out.append(UInt8(ascii: "}"))
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        let utf8 = s.utf8
        if !utf8.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) {
            out.append(contentsOf: utf8)
        } else {
            for b in utf8 {
                switch b {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "\\"))
                case 0..<0x20:
                    out.append(contentsOf: "\\u00".utf8)
                    out.append(hexDigits[Int(b >> 4)])
                    out.append(hexDigits[Int(b & 0xF)])
                default: out.append(b)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    static func sortedJSON<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}

// MARK: - Canonical conversions

extension SyncValue {
    static func date(_ d: Date) -> SyncValue { .dateMillis(millis(d)) }
    static func date(_ d: Date?) -> SyncValue { d.map(date) ?? .null }
    static func bool(_ b: Bool) -> SyncValue { .int(b ? 1 : 0) }
    static func int(_ i: Int) -> SyncValue { .int(Int64(i)) }
    static func string(_ s: String?) -> SyncValue { s.map(SyncValue.string) ?? .null }
    static func double(_ d: Double?) -> SyncValue { d.map(SyncValue.double) ?? .null }
    static func uuid(_ u: UUID?) -> SyncValue { u.map { .string($0.uuidString) } ?? .null }
    static func bytes(_ d: Data?) -> SyncValue { d.map(SyncValue.bytes) ?? .null }
    /// A set of ids, sorted so that order never counts as a change.
    static func uuids(_ ids: [UUID]) -> SyncValue { .strings(Array(Set(ids.map(\.uuidString))).sorted()) }
    static func floats(_ values: [Float]) -> SyncValue { .bytes(packFloats(values)) }

    /// Milliseconds since 1970, rounded to the nearest millisecond (so `Date(ms)` round-trips exactly).
    static func millis(_ d: Date) -> Int64 { SyncMillis.millis(d) }
    static func dateFrom(millis: Int64) -> Date { SyncMillis.date(millis: millis) }

    static func packFloats(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func unpackFloats(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        var out: [Float] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 3 < bytes.count {
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            out.append(Float(bitPattern: bits)); i += 4
        }
        return out
    }

    // Readers: `.null` (or a mismatched case) reads as nil.
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var intValue: Int64? { if case .int(let i) = self { i } else { nil } }
    var doubleValue: Double? { if case .double(let d) = self { d } else { nil } }
    var dateValue: Date? { if case .dateMillis(let ms) = self { Self.dateFrom(millis: ms) } else { nil } }
    var bytesValue: Data? { if case .bytes(let d) = self { d } else { nil } }
    var assetValue: Data? { if case .asset(let d) = self { d } else { nil } }
    var stringsValue: [String]? { if case .strings(let s) = self { s } else { nil } }
    var doublesValue: [Double]? { if case .doubles(let d) = self { d } else { nil } }
    var boolValue: Bool? { intValue.map { $0 != 0 } }
    var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }
}
