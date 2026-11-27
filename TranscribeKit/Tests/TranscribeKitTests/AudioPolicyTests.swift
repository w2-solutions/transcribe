import Foundation
import Testing
@testable import TranscribeKit

/// Audio sync's fixed numbers and pure rules (§2 decisions 3–7).
@Suite("Audio policy")
struct AudioPolicyTests {
    static let now = Date(timeIntervalSince1970: 1_763_500_000)

    @Test func theNumbers() {
        #expect(AudioPolicy.iPhoneAutoWindow == 30 * 86_400)
        #expect(AudioPolicy.autoReserveBytes == 1_000_000_000)
        #expect(AudioPolicy.demandReserveBytes == 300_000_000)
        #expect(AudioPolicy.encodeReserveBytes == 300_000_000)
        #expect(AudioPolicy.bytesPerSecondEstimate == 4_000)
        #expect(AudioPolicy.maxUploadBytes == 200_000_000)
        #expect(AudioPolicy.quotaRetry == 86_400)
        #expect(AudioPolicy.orphanMinimumAge == 86_400)
        #expect(AudioPolicy.sweepInterval == 7 * 86_400)
        #expect(AudioPolicy.maxNotFoundMarkerDeletesPerLaunch == 25)
        #expect(AudioPolicy.maxUploadsPerRecordingPerLaunch == 3)
        #expect(AudioPolicy.batch == 200)
    }

    @Test func theMacDownloadsEverythingTheIPhoneTheLast30Days() {
        let day: TimeInterval = 86_400
        for days in [0.0, 29, 30, 31, 400] {
            #expect(AudioPolicy.autoDownloads(platform: .mac, createdAt: Self.now.addingTimeInterval(-days * day), now: Self.now))
        }
        for platform in [DevicePlatform.iPhone, .iPad] {
            #expect(AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now, now: Self.now))
            #expect(AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now.addingTimeInterval(-29 * day), now: Self.now))
            #expect(AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now.addingTimeInterval(-30 * day), now: Self.now))
            #expect(!AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now.addingTimeInterval(-30 * day - 1), now: Self.now))
            #expect(!AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now.addingTimeInterval(-40 * day), now: Self.now))
            // Another device's clock ahead of this one's.
            #expect(AudioPolicy.autoDownloads(platform: platform, createdAt: Self.now.addingTimeInterval(3_600), now: Self.now))
        }
    }

    @Test(arguments: [
        (NetworkKind.unmetered, false, nil),
        (.unmetered, true, AudioDownloadWait.lowPower),
        (.metered, false, .network),
        (.metered, true, .network),
        (.constrained, false, .network),
        (.constrained, true, .network),
        (.offline, false, .network),
        (.offline, true, .network),
    ] as [(NetworkKind, Bool, AudioDownloadWait?)])
    func automaticWorkNeedsAnUnmeteredNetworkAndNoLowPower(network: NetworkKind, lowPower: Bool, wait: AudioDownloadWait?) {
        #expect(AudioPolicy.automaticWait(network: network, lowPower: lowPower) == wait)
    }

    @Test func roomKeepsTheReserve() {
        let mb: Int64 = 1_000_000
        // Automatic: file + 1 GB.
        #expect(AudioPolicy.hasRoom(free: 14 * mb + 1_000 * mb, bytes: 14 * mb, userInitiated: false))
        #expect(!AudioPolicy.hasRoom(free: 14 * mb + 1_000 * mb - 1, bytes: 14 * mb, userInitiated: false))
        // Download Now: file + 300 MB.
        #expect(AudioPolicy.hasRoom(free: 14 * mb + 300 * mb, bytes: 14 * mb, userInitiated: true))
        #expect(!AudioPolicy.hasRoom(free: 14 * mb + 300 * mb - 1, bytes: 14 * mb, userInitiated: true))
        // The gap between them: Download Now works where automatic downloads stop.
        #expect(AudioPolicy.hasRoom(free: 500 * mb, bytes: 14 * mb, userInitiated: true))
        #expect(!AudioPolicy.hasRoom(free: 500 * mb, bytes: 14 * mb, userInitiated: false))
        // Unknown free space counts as room.
        #expect(AudioPolicy.hasRoom(free: nil, bytes: 14 * mb, userInitiated: false))
        #expect(AudioPolicy.hasRoom(free: nil, bytes: .max / 2, userInitiated: true))
    }

    @Test func backoffSteps() {
        #expect(AudioPolicy.backoff == [60, 600, 3_600, 21_600])
        #expect(AudioPolicy.backoffDelay(failures: 0) == 0)
        #expect(AudioPolicy.backoffDelay(failures: 1) == 60)
        #expect(AudioPolicy.backoffDelay(failures: 2) == 600)
        #expect(AudioPolicy.backoffDelay(failures: 3) == 3_600)
        #expect(AudioPolicy.backoffDelay(failures: 4) == 21_600)
        #expect(AudioPolicy.backoffDelay(failures: 40) == 21_600)
        #expect(AudioPolicy.backoffDelay(failures: -1) == 0)
    }

    @Test func theEstimateIsFourThousandBytesASecond() {
        #expect(AudioPolicy.estimatedBytes(duration: 0) == 0)
        #expect(AudioPolicy.estimatedBytes(duration: 1) == 4_000)
        #expect(AudioPolicy.estimatedBytes(duration: 3_600) == 14_400_000)
        #expect(AudioPolicy.estimatedBytes(duration: 2.5) == 10_000)
        #expect(AudioPolicy.estimatedBytes(duration: -5) == 0)
        #expect(AudioPolicy.estimatedBytes(duration: .nan) == 0)
    }

    @Test func theCapIsAboutFourteenHours() {
        // 200 MB at 4,000 bytes a second: 50,000 s, 13.9 h.
        #expect(AudioPolicy.estimatedBytes(duration: 50_000) == AudioPolicy.maxUploadBytes)
        #expect(AudioPolicy.estimatedBytes(duration: 50_000.5) > AudioPolicy.maxUploadBytes)
        #expect(AudioPolicy.estimatedBytes(duration: 13 * 3_600) < AudioPolicy.maxUploadBytes)
        #expect(AudioPolicy.estimatedBytes(duration: 14 * 3_600) > AudioPolicy.maxUploadBytes)
    }
}
