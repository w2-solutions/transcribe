import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    @Suite("Sync: convergence")
    @MainActor
    struct SyncConvergenceTests {
        /// 20 seeded runs of 200 random operations on three devices, with random sync interleavings (one device joins
        /// late with its own library). After quiescence every device's projections are equal, nothing is pending, the
        /// invariants hold on every device, and the `didSave` fast path never missed a change a full scan would find.
        @Test(arguments: Array(UInt64(1)...UInt64(20)))
        func randomRunConverges(seed: UInt64) async throws {
            var run = try SyncRandomRun(seed: seed)
            defer { run.cleanup() }
            await run.run()
            expectConverged(run.devices)
            #expect(run.undetected.isEmpty, "fast path missed: \(run.undetected.prefix(5))")
            for d in run.devices {
                let profiles = (try? d.context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
                #expect(profiles.filter(\.isMe).count <= 1, "\(d.name) has more than one me")
                let folderNames = ((try? d.context.fetch(FetchDescriptor<Folder>())) ?? []).map { InvariantRepair.folderKey($0.name) }
                #expect(Set(folderNames).count == folderNames.count, "\(d.name) has duplicate folders \(folderNames)")
                #expect(d.sync.status == .idle(lastSync: d.clock.date), "\(d.name) \(d.sync.status)")
            }
            if !run.undetected.isEmpty || run.devices.contains(where: { $0.pending > 0 }) {
                print("seed \(seed) log:\n" + run.log.suffix(40).joined(separator: "\n"))
            }
        }
    }
}
