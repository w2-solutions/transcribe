import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Group labels sync as `VoiceGroupLabel` records. A label is placed by its anchor, so what matters on the other
    /// device is that the anchor and the samples arrive byte for byte: then it shows on the same group there.
    @Suite("Sync: group labels")
    @MainActor
    struct SyncGroupLabelTests {
        static let account = "account-1"

        /// The label test helpers (`tom()`, `groupRef`, `drawn`) over a sync device's own store.
        func harness(_ d: FakeDevice) throws -> WP3Harness {
            try WP3Harness(container: d.container, paths: d.paths, channel: d.channel)
        }

        /// The label records the cloud holds, by record name.
        func cloudLabels(_ cloud: FakeCloud) async -> [String: [String: SyncValue]] {
            await cloud.records(account: Self.account).filter { $0.key.hasPrefix("vg.") }
        }

        /// The key of the drawn group that holds `sample`.
        func groupKey(_ h: WP3Harness, _ p: VoiceProfile, holding sample: UUID) throws -> UUID {
            try #require(h.drawn(p).groups.first { $0.memberIDs.contains(sample) }).key
        }

        func sample(_ p: VoiceProfile, _ id: UUID) throws -> VoiceSample {
            try #require(p.samples.first { $0.id == id })
        }

        @Test func aLabelReachesTheOtherDeviceOnTheSameGroup() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let ha = try harness(t.a), hb = try harness(t.b)
            let tom = try ha.tom()
            await t.settleBoth()
            #expect(await cloudLabels(t.cloud).isEmpty)

            let id = try #require(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(await cloudLabels(t.cloud).keys.sorted() == ["vg.\(id.uuidString)"])

            // Every field arrived, the anchor as the very bytes that were saved.
            let onA = try #require(try ha.label(id)), onB = try #require(try hb.label(id))
            let tomB = try #require(t.b.profile(named: "Tom"))
            #expect(onB.text == "Close" && onB.profile?.id == tomB.id && tomB.id == tom.profile.id)
            #expect(onB.anchorVectorData == onA.anchorVectorData && onB.anchorDimension == onA.anchorDimension)
            #expect(onB.captureChannel == CaptureChannel.iphone && onB.embeddingModelKey == onA.embeddingModelKey)
            #expect(SyncValue.millis(onB.createdAt) == SyncValue.millis(onA.createdAt))
            #expect(SyncValue.millis(onB.editedAt) == SyncValue.millis(onA.editedAt))

            // The samples hold the sender's bytes too, so the Mac draws the same groups and the label matches its
            // group exactly (all three anchor vectors present), not just by similarity.
            let bytesA = Dictionary(tom.profile.samples.map { ($0.id, $0.vectorData) }, uniquingKeysWith: { a, _ in a })
            let bytesB = Dictionary(tomB.samples.map { ($0.id, $0.vectorData) }, uniquingKeysWith: { a, _ in a })
            #expect(bytesB == bytesA && bytesB.count == 6)
            let drawnA = ha.drawn(tom.profile), drawnB = hb.drawn(tomB)
            #expect(drawnB.groups == drawnA.groups && drawnB.placement == drawnA.placement)
            let close = try groupKey(hb, tomB, holding: tom.close[0].id)
            #expect(drawnB.placement.placed == [close: id])
            let split = GroupingInput.split(tomB, localChannel: t.b.channel)
            let vectors = Dictionary(split.items.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
            let group = try #require(drawnB.groups.first { $0.key == close })
            let anchor = try #require(GroupingInput.anchors(tomB).first)
            #expect(GroupLabelResolver.fit(anchor, group, memberVectors: vectors)?.present == 3)
        }

        @Test func anEditAndARemoveReachTheOtherDevice() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let ha = try harness(t.a), hb = try harness(t.b)
            let tom = try ha.tom()
            let id = try #require(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            await t.settleBoth()
            let tomB = try #require(t.b.profile(named: "Tom"))

            // The Mac renames it: the same label, edited.
            t.a.clock.advance(60)
            let ref = try hb.groupRef(tomB, holding: try sample(tomB, tom.close[0].id))
            #expect(ref.shownLabelID == id)
            #expect(try t.b.store.setGroupLabel(ref, text: "Near") == id)
            await t.settleBoth()
            expectConverged(t.devices)
            let onA = try #require(try ha.label(id)), onB = try #require(try hb.label(id))
            #expect(onA.text == "Near" && SyncValue.millis(onA.editedAt) == SyncValue.millis(onB.editedAt))
            #expect(onA.editedAt > onA.createdAt)
            #expect(t.a.count(VoiceGroupLabel.self) == 1 && t.b.count(VoiceGroupLabel.self) == 1)

            // The iPhone removes it: gone everywhere, and nothing else is touched.
            let samples = t.b.count(VoiceSample.self)
            try t.a.store.removeGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]))
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(t.a.count(VoiceGroupLabel.self) == 0 && t.b.count(VoiceGroupLabel.self) == 0)
            #expect(await cloudLabels(t.cloud).isEmpty)
            #expect(t.b.count(VoiceSample.self) == samples && hb.drawn(tomB).placement == LabelPlacement())
        }

        @Test func aLabelThatArrivesBeforeItsVoiceWaits() async throws {
            let cloud = FakeCloud()
            let source = try FakeDevice("S", cloud: cloud)   // never syncs: its records are injected one at a time
            let b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac)
            defer { source.cleanup(); b.cleanup() }
            let hs = try harness(source), hb = try harness(b)
            let tom = try hs.tom()
            let id = try #require(try source.store.setGroupLabel(try hs.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            let projector = RecordProjector(context: source.context)
            func record(_ type: SyncRecordType, _ entity: UUID) throws -> SyncRecord {
                RecordProjector.record(try #require(projector.entity(SyncRecordID(type: type, entityID: entity))))
            }

            // Only the label is there: it is kept without a voice, shown nowhere, and nothing is sent back for it.
            await cloud.inject(account: Self.account, try record(.groupLabel, id))
            await b.sync.enable()
            let label = try #require(try hb.label(id))
            let row = SyncRecordID(type: .groupLabel, entityID: id)
            #expect(label.profile == nil && label.text == "Close")
            #expect(b.stateRow(row)?.unresolvedLinks == ["profileID": tom.profile.id.uuidString])
            #expect(b.stateRow(row)?.pending == SyncPending.none && b.pending == 0)
            let sent = await cloud.record(account: Self.account, recordName: row.recordName)
            #expect(sent?.fields["profileID"] == .string(tom.profile.id.uuidString))

            // The voice arrives without its samples: the label joins it and still shows nowhere.
            await cloud.inject(account: Self.account, try record(.profile, tom.profile.id))
            await b.sync.syncNow()
            let tomB = try #require(b.profile(named: "Tom"))
            #expect(label.profile?.id == tomB.id && b.stateRow(row)?.unresolvedLinks.isEmpty == true)
            #expect(hb.drawn(tomB).groups.isEmpty && hb.drawn(tomB).placement == LabelPlacement(unplaced: [id]))

            // The samples arrive: the label shows on its group, exactly as on the device that made it.
            for s in tom.close + tom.far { await cloud.inject(account: Self.account, try record(.sample, s.id)) }
            await b.sync.syncNow()
            #expect(hb.drawn(tomB).placement == hs.drawn(tom.profile).placement)
            #expect(hb.drawn(tomB).placement.placed == [try groupKey(hb, tomB, holding: tom.close[0].id): id])
            #expect(b.pending == 0)
            #expect(try hb.label(id)?.anchorVectorData == hs.label(id)?.anchorVectorData)
        }

        @Test func twoDevicesLabellingOneGroupShowTheSameLabel() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let ha = try harness(t.a), hb = try harness(t.b)
            let tom = try ha.tom()
            await t.settleBoth()
            let tomB = try #require(t.b.profile(named: "Tom"))

            // Before either has synced its label: the iPhone says "Close", the Mac says "Near" five seconds later.
            let fromA = try #require(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            t.a.clock.advance(5)
            let fromB = try #require(try t.b.store.setGroupLabel(try hb.groupRef(tomB, holding: try sample(tomB, tom.close[0].id)),
                                                                 text: "Near"))
            #expect(fromA != fromB)
            await t.settleBoth()
            expectConverged(t.devices)

            // Both labels are kept on both devices. Both show the later one; the earlier waits behind it.
            #expect(t.a.count(VoiceGroupLabel.self) == 2 && t.b.count(VoiceGroupLabel.self) == 2)
            let close = try groupKey(ha, tom.profile, holding: tom.close[0].id)
            let expected = LabelPlacement(placed: [close: fromB], contenders: [close: [fromA]])
            #expect(ha.drawn(tom.profile).placement == expected)
            #expect(hb.drawn(tomB).placement == expected)

            // Removing the one that shows (on either device) brings the other back, on both.
            try t.a.store.removeGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]))
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(ha.drawn(tom.profile).placement == LabelPlacement(placed: [close: fromA]))
            #expect(hb.drawn(tomB).placement == LabelPlacement(placed: [close: fromA]))
            #expect(try hb.label(fromA)?.text == "Close" && t.b.count(VoiceGroupLabel.self) == 1)
        }

        @Test func labelsMadeBeforeSyncWasOnAreSent() async throws {
            let cloud = FakeCloud()
            let clock = TestClock()
            let a = try FakeDevice("A", cloud: cloud, channel: CaptureChannel.iphone, clock: clock)
            let b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock)
            defer { a.cleanup(); b.cleanup() }
            let ha = try harness(a), hb = try harness(b)
            let tom = try ha.tom()
            let close = try #require(try a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            let far = try #require(try a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.far[0]), text: "Far"))

            await a.sync.enable()
            await b.sync.enable()
            await settle([a, b])
            expectConverged([a, b])
            let tomB = try #require(b.profile(named: "Tom"))
            #expect(try hb.label(close)?.text == "Close" && hb.label(far)?.text == "Far")
            #expect(hb.drawn(tomB).placement == ha.drawn(tom.profile).placement)
            #expect(hb.drawn(tomB).placement.placed.count == 2)
        }

        @Test func mergingAndForgettingAVoiceCarryItsLabels() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let ha = try harness(t.a), hb = try harness(t.b)
            let tom = try ha.tom()
            let original = try #require(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            await t.settleBoth()
            #expect(t.b.count(VoiceGroupLabel.self) == 1)

            // Tom turns out to be Karan. The label is copied to Karan under a new id; the original goes with Tom.
            try t.a.store.mergeProfiles(source: tom.profile.id, into: t.karan)
            await t.settleBoth()
            expectConverged(t.devices)
            let karanA = try #require(t.a.profile(named: "Karan")), karanB = try #require(t.b.profile(named: "Karan"))
            #expect(t.b.profile(named: "Tom") == nil)
            let copies = try hb.labels()
            #expect(copies.count == 1 && copies.first?.id != original)
            let copy = try #require(copies.first)
            #expect(copy.text == "Close" && copy.profile?.id == karanB.id)
            #expect(await cloudLabels(t.cloud).keys.sorted() == ["vg.\(copy.id.uuidString)"])
            // It still sits on the three Close samples, which kept their bytes through the merge and the sync.
            #expect(hb.drawn(karanB).placement == ha.drawn(karanA).placement)
            #expect(hb.drawn(karanB).placement.placed.values.sorted { $0.uuidString < $1.uuidString } == [copy.id])
            #expect(hb.drawn(karanB).placement.unplaced.isEmpty && hb.drawn(karanB).placement.contenders.isEmpty)

            // Forgetting Karan on the Mac removes the label everywhere.
            try t.b.store.forgetProfile(t.karan)
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(t.a.count(VoiceGroupLabel.self) == 0 && t.b.count(VoiceGroupLabel.self) == 0)
            #expect(await cloudLabels(t.cloud).isEmpty)
        }

        @Test func turningSyncOffKeepsLabelsAndRemovingTheCloudCopyKeepsThemHere() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let ha = try harness(t.a), hb = try harness(t.b)
            let tom = try ha.tom()
            let id = try #require(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
            await t.settleBoth()

            // Off, keeping the iCloud copy: the label stays here, in iCloud and on the Mac.
            try await t.a.sync.disable(removeCloudCopy: false)
            #expect(try ha.label(id)?.text == "Close" && hb.label(id)?.text == "Close")
            #expect(await cloudLabels(t.cloud).count == 1)

            // An edit made while sync is off goes out when it is turned on again.
            t.a.clock.advance(60)
            #expect(try t.a.store.setGroupLabel(try ha.groupRef(tom.profile, holding: tom.close[0]), text: "Near") == id)
            await t.a.sync.enable()
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(try hb.label(id)?.text == "Near" && t.b.count(VoiceGroupLabel.self) == 1)

            // Off, removing the iCloud copy: local data is never deleted.
            try await t.a.sync.disable(removeCloudCopy: true)
            #expect(t.a.stateRows().isEmpty)
            #expect(try ha.label(id)?.text == "Near" && t.a.count(VoiceGroupLabel.self) == 1)
            #expect(try ha.label(id)?.profile?.id == tom.profile.id)
        }
    }
}
