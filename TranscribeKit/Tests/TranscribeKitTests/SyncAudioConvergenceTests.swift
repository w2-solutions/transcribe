import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    @Suite("Sync: audio convergence")
    @MainActor
    struct SyncAudioConvergenceTests {
        /// Per seed: relaunches that held a transfer, injected failures thrown, blobs deleted.
        static let audioEffects = Mutex<[UInt64: (Int, Int, Int)]>([:])

        /// Five seeded runs of 100 random operations per device on three devices with audio sync (two iPhones and a
        /// Mac), mixed with audio operations: Sync audio switched, drains, transcripts opened, relaunches with a
        /// transfer held, audio requests failed once. After quiescence the libraries converge, every ready recording
        /// has its marker and its blob, every audio device holds its audio, the blobs are exactly the markers, no marker names a
        /// recording that is gone, and no device keeps an audio file of a recording it no longer has.
        @Test(arguments: Array(UInt64(1)...UInt64(5)))
        func randomRunWithAudioConverges(seed: UInt64) async throws {
            var run = try SyncRandomRun(seed: seed, operations: 300, audio: true)
            defer { run.cleanup() }
            await run.run()
            expectConverged(run.devices)
            await expectAudioConverged(run.devices, complete: true)
            // The audio operations took effect: across the five seeds (once all have run, in whatever order), relaunches
            // caught a transfer in flight, injected failures were thrown and blobs were deleted. How many in each run
            // depends on how far the devices' audio loops got between operations, so it is not checked per seed.
            let failures = await run.cloud.audioFailuresTaken, deletes = await run.cloud.audioDeletesDone
            let totals = Self.audioEffects.withLock { effects in
                effects[seed] = (run.heldRelaunches, failures, deletes)
                return effects.count == 5
                    ? effects.values.reduce((0, 0, 0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) } : nil
            }
            if let totals {
                #expect(totals.0 > 0, "no relaunch in five seeds caught a transfer in flight")
                #expect(totals.1 > 0, "no injected audio failure was thrown in five seeds")
                #expect(totals.2 > 0, "no blob was deleted in five seeds")
            }
            #expect(run.undetected.isEmpty, "fast path missed: \(run.undetected.prefix(5))")
            let fm = FileManager.default
            for d in run.devices {
                #expect(!d.sync.status.isPaused, "\(d.name) \(d.sync.status)")
                let present = Set(((try? d.context.fetch(FetchDescriptor<Recording>())) ?? []).map(\.id.uuidString))
                for dir in [d.paths.audioDirectory, d.paths.audioOutgoingDirectory, d.paths.audioIncomingDirectory] {
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                        let id = String(name.prefix { $0 != "." })
                        #expect(present.contains(id), "\(d.name) keeps \(dir.lastPathComponent)/\(name) of a gone recording")
                    }
                    #expect(!((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains {
                        $0.hasSuffix(".m4a") && !present.contains(String($0.prefix { $0 != "." }))
                    })
                }
                // Every marker's recording is on this device, and every audio row is settled.
                for row in d.stateRows() where row.isAudioRow {
                    #expect(row.audioFacts?.marker == .onServer, "\(d.name) \(row.recordName) \(String(describing: row.audioFacts?.marker))")
                }
            }
            if run.devices.contains(where: { $0.pending > 0 }) || !run.undetected.isEmpty {
                print("seed \(seed) log:\n" + run.log.suffix(60).joined(separator: "\n"))
            }
        }
    }
}
