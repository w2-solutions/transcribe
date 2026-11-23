import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Voices learned on one device's microphone reach the other through sync and are matched per channel (§7, §8.7).
    @Suite("Sync: cross-device matching")
    @MainActor
    struct SyncCrossDeviceMatchTests {
        @Test func karanNamedOnTheIPhoneIsAskedOnTheMacThenLearnedThere() async throws {
            let cloud = FakeCloud()
            let clock = TestClock()
            let a = try FakeDevice("iPhone", cloud: cloud, channel: CaptureChannel.iphone, clock: clock)
            let b = try FakeDevice("Mac", cloud: cloud, channel: CaptureChannel.mac, clock: clock)
            defer { a.cleanup(); b.cleanup() }

            // 1. Karan is named on the iPhone: one trusted 12 s sample heard on the iPhone.
            let first = try a.record([SyncVoices.karan(44)])
            let karan = try #require(try a.store.nameSpeaker(recordingID: first, key: "S1", as: .newPerson(name: "Karan"),
                                                              remember: true).profileID)
            await a.sync.enable()
            await b.sync.enable()
            await settle([a, b])
            let onMac = try #require(b.profile(named: "Karan"))
            #expect(onMac.samples.map(\.captureChannel) == [CaptureChannel.iphone])

            // 2. A Mac recording of Karan (0.81 to the iPhone sample) can only ask: "Is this Karan?".
            clock.advance(60)
            let macRecording = try b.record([SyncVoices.karan(45)])
            let s1 = try #require(b.recording(macRecording)?.speaker("S1"))
            #expect(s1.label == .suggested && s1.suggestedProfileID == karan)
            let trace = try JSONDecoder().decode(MatchTrace.self, from: try #require(s1.matchTraceData))
            #expect(trace.reason == "otherChannel" && trace.probeChannel == CaptureChannel.mac)

            // 3. Confirming on the Mac stores a Mac sample, which syncs back to the iPhone.
            _ = try b.store.confirmSuggestion(recordingID: macRecording, key: "S1")
            #expect(onMac.samples.filter { $0.captureChannel == CaptureChannel.mac }.count == 1)
            await settle([a, b])
            let onIPhone = try #require(a.profile(named: "Karan"))
            #expect(Set(onIPhone.samples.compactMap(\.captureChannel)) == [CaptureChannel.iphone, CaptureChannel.mac])
            #expect(a.recording(macRecording)?.speaker("S1")?.profile?.id == karan)   // the label synced too

            // 4. The Mac's next recording of Karan is auto-labelled.
            clock.advance(60)
            let next = try b.record([SyncVoices.karan(46)])
            let s = try #require(b.recording(next)?.speaker("S1"))
            #expect(s.label == .autoLabelled && s.profile?.id == karan)
            await settle([a, b])
            expectConverged([a, b])
        }

        /// Suggestions sync as the `label` group: the Mac sees the iPhone's open question, and arrivals never rematch.
        @Test func suggestionsSyncWithoutRematching() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let s1 = try #require(t.b.recording(t.r2)?.speaker("S1"))
            #expect(s1.label == .suggested && s1.suggestedProfileID == t.karan)
            #expect(s1.matchScore == t.a.recording(t.r2)?.speaker("S1")?.matchScore)
            #expect(s1.matchTraceData == nil)   // match traces stay on the device that matched
        }
    }
}
