import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// SplitMix64: a small seeded generator, so a failing run can be replayed from its seed.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A seeded random run of user operations on three devices with random sync interleavings (§8.7).
@MainActor
struct SyncRandomRun {
    let seed: UInt64
    let operations: Int
    var rng: SeededRNG
    let cloud = FakeCloud()
    let devices: [FakeDevice]
    var log: [String] = []
    /// Fast-path misses found after an operation (a change only a full scan would have found).
    var undetected: [String] = []

    init(seed: UInt64, operations: Int = 200) throws {
        self.seed = seed
        self.operations = operations
        rng = SeededRNG(seed: seed)
        let clock = TestClock()
        devices = [try FakeDevice("A", cloud: cloud, channel: CaptureChannel.iphone, clock: clock),
                   try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock),
                   try FakeDevice("C", cloud: cloud, channel: CaptureChannel.iphone, clock: clock)]
    }

    func cleanup() { for d in devices { d.cleanup() } }

    mutating func run() async {
        await devices[0].sync.enable()
        await devices[1].sync.enable()
        for step in 0..<operations {
            await Task.yield()   // other tests share the main actor
            if step == operations / 4 {
                // C has been used offline; it joins now with its own library.
                await devices[2].sync.enable()
                log.append("\(step) C joins")
            }
            let d = devices[Int.random(in: 0..<devices.count, using: &rng)]
            devices[0].clock.advance(Double(Int.random(in: 1...90, using: &rng)))
            let roll = Int.random(in: 0..<100, using: &rng)
            if roll < 18 {
                let full = Bool.random(using: &rng)
                await d.sync.sync(fullScan: full)
                log.append("\(step) \(d.name) sync\(full ? " full" : "")")
                continue
            }
            if roll == 99 {
                // The switch: off (keeping the iCloud copy) or on again.
                if d.settings.syncEnabled {
                    try? await d.sync.disable(removeCloudCopy: false)
                    log.append("\(step) \(d.name) sync off")
                } else {
                    await d.sync.enable()
                    log.append("\(step) \(d.name) sync on")
                }
                continue
            }
            let op = operate(on: d, roll: roll)
            log.append("\(step) \(d.name) \(op)")
            if d.sync.running {
                await d.sync.flushAndEnqueue()
                let misses = Self.undetectedChanges(d)
                if !misses.isEmpty { undetected.append("\(step) \(d.name) \(op): \(misses)") }
            }
        }
        // Everything finishes processing and every switch is on before the devices must agree.
        for d in devices {
            for r in processing(d) { log.append("end \(d.name) \(finishProcessing(d, r))") }
            if !d.settings.syncEnabled { await d.sync.enable() }
        }
        await settle(devices, rounds: 16)
    }

    private func processing(_ d: FakeDevice) -> [Recording] {
        ((try? d.context.fetch(FetchDescriptor<Recording>())) ?? []).filter { $0.stage == .separating }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Re-separation finishes: new speakers replace the old ones, then matching makes it ready.
    private func finishProcessing(_ d: FakeDevice, _ r: Recording) -> String {
        do {
            let drafts = [WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .karan, cosine: 0.8,
                                                                                          variant: Int(r.id.uuidString.utf8.first! % 20) + 30))]
            try d.store.checkpointSeparation(id: r.id, document: WP3Docs.speakers(SeedContent.conversationB), speakers: drafts)
            try d.matchLikeThePipeline(r.id)
            return "reprocessed \(r.id.uuidString.prefix(4))"
        } catch {
            d.context.rollback()
            return "reprocess failed: \(error)"
        }
    }

    /// What a full scan would find that the fast path left behind.
    static func undetectedChanges(_ d: FakeDevice) -> [String] {
        let projector = RecordProjector(context: d.context)
        let rows = Dictionary(d.stateRows().map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a })
        var misses: [String] = []
        var present: Set<String> = []
        for type in SyncRecordType.allCases {
            for e in (try? projector.all(type)) ?? [] {
                present.insert(e.recordID.recordName)
                guard e.isSyncable else { continue }
                guard let row = rows[e.recordID.recordName] else { misses.append("no row \(e.recordID)"); continue }
                if row.pending == .none, RecordProjector.hashes(e, unresolved: row.unresolvedLinks) != row.baseHashes {
                    misses.append("unsent change \(e.recordID)")
                }
            }
        }
        let holding = (try? d.sync.detector.syncedRecordingIsProcessing()) ?? false
        for (name, row) in rows where !present.contains(name) && row.pending != .delete {
            if row.typeRaw == SyncRecordType.speaker.rawValue && holding { continue }
            misses.append("unsent delete \(name)")
        }
        return misses.sorted()
    }

    // MARK: Operations

    private mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[Int.random(in: 0..<items.count, using: &rng)]
    }

    private mutating func vector() -> VoiceVector {
        let person = pick(SyntheticPerson.allCases)!
        let cosine = Float.random(in: 0.55...0.95, using: &rng)
        return SyntheticVoices.vector(near: person, cosine: cosine, variant: Int.random(in: 30..<56, using: &rng))
    }

    private mutating func operate(on d: FakeDevice, roll: Int) -> String {
        let store = d.store
        let ready = ((try? d.context.fetch(FetchDescriptor<Recording>())) ?? [])
            .filter { $0.stage == .ready }.sorted { $0.id.uuidString < $1.id.uuidString }
        let profiles = ((try? d.context.fetch(FetchDescriptor<VoiceProfile>())) ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
        let folders = ((try? d.context.fetch(FetchDescriptor<Folder>())) ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
        let names = ["Karan", "Liam", "Sam", "Ana", "Mia", "Tom", "karan"]
        var label = ""
        do {
            switch roll {
            case 18..<26:
                let count = Int.random(in: 1...2, using: &rng)
                let vs = (0..<count).map { _ in vector() }
                let id = try d.record(vs, clean: Double.random(in: 6...14, using: &rng))
                label = "record \(id.uuidString.prefix(4))"
            case 26..<38:
                guard let r = pick(ready), let s = pick(r.sortedSpeakers) else { return "name (none)" }
                let remember = Int.random(in: 0..<5, using: &rng) > 0
                if Bool.random(using: &rng), let p = pick(profiles) {
                    _ = try store.nameSpeaker(recordingID: r.id, key: s.key, as: .existing(profileID: p.id), remember: remember)
                    label = "name \(s.key) as \(p.name)"
                } else {
                    let n = pick(names)!
                    _ = try store.nameSpeaker(recordingID: r.id, key: s.key, as: .newPerson(name: n), remember: remember)
                    label = "name \(s.key) new \(n)"
                }
            case 38..<43:
                let suggested = ready.flatMap { r in r.sortedSpeakers.filter { $0.label == .suggested }.map { (r, $0) } }
                guard let (r, s) = pick(suggested) else { return "confirm (none)" }
                _ = try store.confirmSuggestion(recordingID: r.id, key: s.key)
                label = "confirm"
            case 43..<47:
                let suggested = ready.flatMap { r in r.sortedSpeakers.filter { $0.label == .suggested }.map { (r, $0) } }
                guard let (r, s) = pick(suggested) else { return "reject (none)" }
                try store.rejectSuggestion(recordingID: r.id, key: s.key)
                label = "reject"
            case 47..<52:
                guard let r = pick(ready), let doc = r.transcript, let turn = pick(doc.turns) else { return "reassign (none)" }
                if Bool.random(using: &rng), let other = pick(r.sortedSpeakers) {
                    try store.reassignTurn(recordingID: r.id, turnID: turn.id, to: .speaker(other.key))
                } else if Bool.random(using: &rng), let p = pick(profiles) {
                    try store.reassignTurn(recordingID: r.id, turnID: turn.id, to: .profile(p.id))
                } else {
                    try store.reassignTurn(recordingID: r.id, turnID: turn.id, to: .newName("Guest"))
                }
                label = "reassign"
            case 52..<56:
                let pairs = ready.filter { $0.speakers.count >= 2 }
                guard let r = pick(pairs) else { return "same as (none)" }
                let sp = r.sortedSpeakers
                try store.moveAllTurns(recordingID: r.id, from: sp[1].key, to: sp[0].key)
                label = "same as"
            case 56..<62:
                guard let r = pick(ready) else { return "fav (none)" }
                try store.setFavourite(id: r.id, !r.isFavourite)
                label = "fav"
            case 62..<67:
                guard let r = pick(ready) else { return "move (none)" }
                let f = Bool.random(using: &rng) ? pick(folders) : nil
                try store.move(recordingID: r.id, toFolder: f?.id)
                label = "move"
            case 67..<70:
                _ = try store.createFolder(name: pick(["Work", "work", "Home", "Ideas"])!)
                label = "folder"
            case 70..<76:
                guard let r = pick(ready) else { return "rename (none)" }
                try store.rename(id: r.id, title: pick(["Standup", "Call", "Notes", ""])!)
                label = "rename"
            case 76..<79:
                guard let p = pick(profiles) else { return "rename voice (none)" }
                try store.renameProfile(profileID: p.id, name: pick(names)!)
                label = "rename voice"
            case 79..<82:
                guard profiles.count >= 2, let a = pick(profiles), let b = pick(profiles.filter { $0.id != a.id }) else {
                    return "merge (none)"
                }
                try store.mergeProfiles(source: a.id, into: b.id)
                label = "merge"
            case 82..<84:
                guard let p = pick(profiles) else { return "forget (none)" }
                try store.forgetProfile(p.id)
                label = "forget"
            case 84..<87:
                guard let r = pick(ready) else { return "delete (none)" }
                try store.delete(id: r.id)
                label = "delete"
            case 87..<89:
                guard let f = pick(folders) else { return "delete folder (none)" }
                try store.deleteFolder(id: f.id)
                label = "delete folder"
            case 89..<91:
                guard let f = pick(folders) else { return "rename folder (none)" }
                try store.renameFolder(id: f.id, name: pick(["Work", "Later", "Ideas"])!)
                label = "rename folder"
            case 91..<94:
                try store.setIsMe(profileID: pick(profiles)?.id)
                label = "me"
            case 94..<96:
                guard let p = pick(profiles) else { return "auto (none)" }
                try store.setAutoLabel(profileID: p.id, !p.autoLabel)
                label = "auto"
            case 96..<97:
                let samples = profiles.flatMap(\.samples).sorted { $0.id.uuidString < $1.id.uuidString }
                guard let s = pick(samples) else { return "remove sample (none)" }
                try store.removeSample(id: s.id)
                label = "remove sample"
            case 98:
                // Re-separation of a synced recording: start one, or finish one that is processing.
                if let r = pick(processing(d)) { return finishProcessing(d, r) }
                guard let r = pick(ready) else { return "reprocess (none)" }
                try store.setStage(.separating, queueReason: nil, for: r.id)
                label = "reprocess start \(r.id.uuidString.prefix(4))"
            default:
                guard let p = pick(profiles) else { return "add sample (none)" }
                let candidates = (try? store.sampleCandidates(for: p.id)) ?? []
                guard let c = pick(candidates) else { return "add sample (none)" }
                _ = try store.addSample(profileID: p.id, fromSpeaker: c.id)
                label = "add sample"
            }
        } catch {
            d.context.rollback()
            return "\(label) failed: \(error)"
        }
        return label
    }
}
