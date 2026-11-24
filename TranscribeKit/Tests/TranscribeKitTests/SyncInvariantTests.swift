import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Deterministic repairs after a fetch (§8.4 flow 4, D13, D14) and caps on receive (D12).
    @Suite("Sync: invariants")
    @MainActor
    struct SyncInvariantTests {
        @Test func theOldestMeKeepsIt() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.setIsMe(profileID: t.liam)
            try t.b.store.setIsMe(profileID: t.karan)    // Karan is the older profile (named first)
            await t.settleBoth()
            for d in t.devices {
                #expect(d.profile(named: "Karan")?.isMe == true && d.profile(named: "Liam")?.isMe == false)
            }
            expectConverged(t.devices)
        }

        @Test func aMeTieGoesToTheSmallestID() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            // Same createdAt to the millisecond on both profiles.
            for d in t.devices {
                let karan = try #require(d.profile(named: "Karan")), liam = try #require(d.profile(named: "Liam"))
                karan.createdAt = liam.createdAt
                try d.context.save()
            }
            await t.settleBoth()
            try t.a.store.setIsMe(profileID: t.liam)
            try t.b.store.setIsMe(profileID: t.karan)
            await t.settleBoth()
            let winner = min(t.karan.uuidString, t.liam.uuidString)
            for d in t.devices {
                let mes = try d.context.fetch(FetchDescriptor<VoiceProfile>()).filter(\.isMe)
                #expect(mes.map(\.id.uuidString) == [winner])
            }
            expectConverged(t.devices)
        }

        @Test func foldersWithTheSameNameMerge() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let older = try t.a.store.createFolder(name: "Work")
            try t.a.store.move(recordingID: t.r1, toFolder: older)
            t.b.clock.advance(5)
            let newer = try t.b.store.createFolder(name: "work ")
            try t.b.store.move(recordingID: t.r2, toFolder: newer)
            await t.settleBoth()
            for d in t.devices {
                let folders = try d.context.fetch(FetchDescriptor<Folder>())
                #expect(folders.map(\.id) == [older])
                #expect(d.recording(t.r1)?.folder?.id == older && d.recording(t.r2)?.folder?.id == older)
            }
            expectConverged(t.devices)
        }

        @Test func duplicateNamesGiveABannerNotAMerge() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let a3 = try t.a.record([SyncVoices.stranger(37)])
            let b3 = try t.b.record([SyncVoices.stranger(38, 0.7)])
            _ = try t.a.store.nameSpeaker(recordingID: a3, key: "S1", as: .newPerson(name: "Sam"), remember: true)
            _ = try t.b.store.nameSpeaker(recordingID: b3, key: "S1", as: .newPerson(name: "sam"), remember: true)
            await t.settleBoth()
            for d in t.devices {
                let sams = try d.context.fetch(FetchDescriptor<VoiceProfile>()).filter { VoiceProfile.nameMatches($0.name, "Sam") }
                #expect(sams.count == 2)
                #expect(d.sync.duplicateNames.count == 1)
            }
            expectConverged(t.devices)
        }

        /// Two iPhones each add 8 samples to Karan's iPhone channel: every device keeps all 17 (no cap on receive).
        /// The Mac's own insert trims only the Mac channel; the next iPhone insert trims the iPhone channel to 12.
        @Test func capsAreNotEnforcedOnReceiveAndALocalInsertTrimsOnlyItsChannel() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let c = try FakeDevice("C", cloud: t.cloud, channel: CaptureChannel.iphone, clock: t.a.clock)
            defer { c.cleanup() }
            await c.sync.enable()
            await settle([t.a, t.b, c])
            func add(_ d: FakeDevice, variants: Range<Int>, channel: String) throws {
                let karan = try #require(d.profile(named: "Karan"))
                for v in variants {
                    #expect(d.store.insertSample(into: karan, vector: SyncVoices.karan(v, 0.8), modelKey: EmbeddingModelID.fake.key,
                                                 origin: .confirmed, speechSeconds: 12, sourceRecordingID: nil, sourceSpeakerID: nil,
                                                 clip: nil, quote: nil, channel: channel, input: "builtInMic"))
                    d.clock.advance(1)
                }
                try d.context.save()
            }
            try add(t.a, variants: 1..<9, channel: CaptureChannel.iphone)
            try add(c, variants: 11..<19, channel: CaptureChannel.iphone)
            await settle([t.a, t.b, c])
            for d in [t.a, t.b, c] {
                let karan = try #require(d.profile(named: "Karan"))
                #expect(karan.samples.filter { $0.captureChannel == CaptureChannel.iphone }.count == 17)
            }
            try add(t.b, variants: 20..<21, channel: CaptureChannel.mac)
            await settle([t.a, t.b, c])
            #expect(t.a.profile(named: "Karan")?.samples.filter { $0.captureChannel == CaptureChannel.iphone }.count == 17)
            try add(t.a, variants: 21..<22, channel: CaptureChannel.iphone)
            await settle([t.a, t.b, c])
            for d in [t.a, t.b, c] {
                let karan = try #require(d.profile(named: "Karan"))
                #expect(karan.samples.filter { $0.captureChannel == CaptureChannel.iphone }.count == 12)
                #expect(karan.samples.filter { $0.captureChannel == CaptureChannel.mac }.count == 1)
            }
            expectConverged([t.a, t.b, c])
        }
    }
}
