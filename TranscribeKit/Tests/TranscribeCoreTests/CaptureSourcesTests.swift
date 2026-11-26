import Foundation
import Testing
@testable import TranscribeCore

/// The step-0 contracts for Mac audio: what a recording captures, which stream a speaker was heard on, where the
/// stems go, the log-only `CaptureDetail` fields, the v3 trace fields and the shared millisecond rule.
@Suite("Capture sources and speaker sources")
struct CaptureSourcesTests {
    @Test func captureSourcesMapToTheDetailValues() {
        #expect(CaptureSources.allCases.map(\.rawValue) == ["microphone", "both", "macAudio"])
        #expect(CaptureSources.microphone.detailValue == "mic")
        #expect(CaptureSources.both.detailValue == "both")
        #expect(CaptureSources.macAudio.detailValue == "system")
        for s in CaptureSources.allCases { #expect(CaptureSources(detailValue: s.detailValue) == s) }
        #expect(CaptureSources(detailValue: nil) == .microphone)
        #expect(CaptureSources(detailValue: "somethingNew") == .microphone)
        #expect(CaptureSources.microphone.includesMicrophone && !CaptureSources.microphone.includesSystemAudio)
        #expect(CaptureSources.both.includesMicrophone && CaptureSources.both.includesSystemAudio)
        #expect(!CaptureSources.macAudio.includesMicrophone && CaptureSources.macAudio.includesSystemAudio)
        #expect(CaptureSources.microphone.detailInput == nil)
        #expect(CaptureSources.both.detailInput == "micAndSystem" && CaptureSources.macAudio.detailInput == "systemAudio")
    }

    @Test func speakerSourcesReadNilAndUnknownAsMic() {
        #expect(SpeakerSource.allCases.map(\.rawValue) == ["mic", "system", "mixed"])
        #expect(SpeakerSource(stored: nil) == .mic)
        #expect(SpeakerSource(stored: "mic") == .mic)
        #expect(SpeakerSource(stored: "system") == .system)
        #expect(SpeakerSource(stored: "mixed") == .mixed)
        #expect(SpeakerSource(stored: "fromTheFuture") == .mic)
        #expect(SpeakerSource.joined(.mic, .mic) == .mic && SpeakerSource.joined(.system, .system) == .system)
        #expect(SpeakerSource.joined(.mic, .system) == .mixed && SpeakerSource.joined(.system, .mixed) == .mixed)
    }

    @Test func stemsSitInAStemsFolderBesideTheMix() {
        let audio = URL(fileURLWithPath: "/tmp/lib/Audio/ABC.wav")
        let stems = CaptureStems.beside(audioURL: audio)
        #expect(stems.mic.path == "/tmp/lib/Audio/Stems/ABC.mic.wav")
        #expect(stems.system.path == "/tmp/lib/Audio/Stems/ABC.system.wav")
        #expect(stems.url(.mic) == stems.mic && stems.url(.system) == stems.system)
        #expect(CaptureStream.allCases.map(\.rawValue) == ["mic", "system"])
    }

    // MARK: CaptureDetail stays byte-identical for the microphone

    /// The JSON a 0.3.3 build wrote for these details, byte for byte.
    @Test func microphoneOnlyDetailEncodesAsBefore() {
        let mac = CaptureDetail(hardwareModel: "Mac16,5", input: CaptureDetail.Input.usbAudio, inputName: "Desk mic",
                                inputModelUID: "usb:1234")
        #expect(mac.json() == #"{"hardwareModel":"Mac16,5","input":"usbAudio","inputModelUID":"usb:1234","inputName":"Desk mic","routeChanged":false}"#)
        let phone = CaptureDetail(hardwareModel: "iPhone15,4", input: CaptureDetail.Input.builtInMic, routeChanged: true)
        #expect(phone.json() == #"{"hardwareModel":"iPhone15,4","input":"builtInMic","routeChanged":true}"#)
        #expect(mac.sources == nil && mac.outputRoute == nil && mac.captureSources == .microphone)
    }

    @Test func macAudioDetailRoundTripsAndOldReadersIgnoreTheNewKeys() throws {
        let both = CaptureDetail(hardwareModel: "Mac16,5", input: CaptureDetail.Input.micAndSystem, routeChanged: false,
                                 sources: CaptureSources.both.detailValue,
                                 outputRoute: CaptureDetail.OutputRoute.headphones)
        let json = both.json()
        #expect(json == #"{"hardwareModel":"Mac16,5","input":"micAndSystem","outputRoute":"headphones","routeChanged":false,"sources":"both"}"#)
        #expect(CaptureDetail.decode(json) == both && both.captureSources == .both)

        /// `CaptureDetail` as 0.3.3 declares it: the new keys must not stop it decoding.
        struct DetailV033: Codable { var hardwareModel: String; var input: String?; var inputName: String?
                                     var inputModelUID: String?; var routeChanged: Bool }
        let old = try JSONDecoder().decode(DetailV033.self, from: Data(json.utf8))
        #expect(old.hardwareModel == "Mac16,5" && old.input == "micAndSystem" && !old.routeChanged)
        // And a 0.3.3 detail decodes here with the new fields nil.
        let fromOld = try #require(CaptureDetail.decode(#"{"hardwareModel":"Mac16,5","input":"usbAudio","routeChanged":false}"#))
        #expect(fromOld.sources == nil && fromOld.outputRoute == nil && fromOld.captureSources == .microphone)
    }

    // MARK: MatchTrace v3 fields

    @Test func traceWithoutV3FieldsEncodesAsAV2Trace() throws {
        let evidence = ProfileEvidence(profileID: UUID(uuidString: "B3000000-0000-4000-8000-000000000001")!, score: 0.5,
                                       trustedTop: 0.6, trustedScore: 0.55, trustedCount: 1, untrustedCount: 0, askOnly: false,
                                       negativeMax: nil, blocked: false, cohortMax: nil, otherChannelTrustedCount: 0)
        let trace = MatchTrace(version: 2, key: "S1", cleanSeconds: 12, kind: .ask, profileID: evidence.profileID, reason: "belowAuto",
                               score: 0.5, runnerUp: nil, margin: nil, profiles: [evidence], cohortSize: 0, cohortTopMean: nil,
                               cohortTopStd: nil, autoLabelMin: 0.55, autoLabelMargin: 0.10, askMin: 0.40, probeChannel: "mac")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(trace), as: UTF8.self)
        for key in ["autoScore", "groupCount", "groupSize", "groupTrustedCount", "singletonBorrowShadow", "speakerSource", "systemShare"] {
            #expect(!json.contains(key), "\(key)")
        }
        #expect(MatchTrace.currentVersion == 2 && MatchTrace.groupsVersion == 3)
    }

    @Test func v3TraceRoundTripsAndOlderTracesStillDecode() throws {
        var evidence = ProfileEvidence(profileID: UUID(), score: 0.6, trustedTop: 0.7, trustedScore: 0.65, trustedCount: 2,
                                       untrustedCount: 1, askOnly: false, negativeMax: 0.1, blocked: false, cohortMax: 0.2,
                                       otherChannelTrustedCount: 0, autoScore: 0.58, groupCount: 3, groupSize: 2,
                                       groupTrustedCount: 1, singletonBorrowShadow: 0.52)
        let trace = MatchTrace(version: 3, key: "S2", cleanSeconds: 20, kind: .auto, profileID: evidence.profileID, reason: "auto",
                               score: 0.6, runnerUp: 0.2, margin: 0.4, profiles: [evidence], cohortSize: 4, cohortTopMean: nil,
                               cohortTopStd: nil, autoLabelMin: 0.55, autoLabelMargin: 0.10, askMin: 0.40, probeChannel: "mac",
                               speakerSource: SpeakerSource.system.rawValue, systemShare: 0.93)
        let back = try JSONDecoder().decode(MatchTrace.self, from: try JSONEncoder().encode(trace))
        #expect(back == trace)
        evidence.autoScore = nil
        #expect(back.profiles[0] != evidence)

        let v1 = #"{"version":1,"key":"S1","cleanSeconds":12,"kind":"unknown","reason":"lowScore","profiles":[{"profileID":"B3000000-0000-4000-8000-000000000001","score":0.1,"trustedCount":1,"untrustedCount":0,"askOnly":false,"blocked":false}],"cohortSize":0,"autoLabelMin":0.55,"autoLabelMargin":0.1,"askMin":0.4}"#
        let decoded = try JSONDecoder().decode(MatchTrace.self, from: Data(v1.utf8))
        #expect(decoded.version == 1 && decoded.speakerSource == nil && decoded.systemShare == nil && decoded.probeChannel == nil)
        #expect(decoded.profiles[0].autoScore == nil && decoded.profiles[0].groupCount == nil)
    }

    // MARK: Matching inputs

    @Test func newMatchingInputsDefaultToTodaysBehaviour() {
        let policy = MatchPolicy.default
        #expect(policy.maxSamplesPerProfile == 12 && policy.sampleCeilingPerChannel == 20)
        #expect(policy.groupScoring && policy.groupJoinCosine == SampleGroupPolicy.default.joinCosine)
        let probe = SpeakerProbe(key: "S1", vector: nil, cleanSeconds: 10, rejectedProfileIDs: [])
        #expect(!probe.askOnly)
        let v = VoiceVector(raw: [1, 0, 0])!
        let legacy = ProfileCandidate(id: UUID(), name: "A", samples: [v], modelKey: "m", autoLabel: true, needsResample: false)
        #expect(legacy.sampleIDs == nil && legacy.addedAtMillis == nil)
        let id = UUID()
        let full = ProfileCandidate(id: UUID(), name: "B", samples: [v], trusted: [true], channels: ["mac"], negatives: [],
                                    modelKey: "m", autoLabel: true, needsResample: false, sampleIDs: [id], addedAtMillis: [1_000])
        #expect(full.sampleIDs == [id] && full.addedAtMillis == [1_000])
        let date = Date(timeIntervalSince1970: 1_794_873_600.0004)
        let sample = CuratedSample(id: id, vector: v, origin: .named, addedAt: date)
        #expect(sample.addedAtMillis == 1_794_873_600_000)
    }

    @Test func syncMillisRoundsToTheNearestMillisecondAndRoundTrips() {
        #expect(SyncMillis.millis(Date(timeIntervalSince1970: 1.0004)) == 1_000)
        #expect(SyncMillis.millis(Date(timeIntervalSince1970: 1.0006)) == 1_001)
        #expect(SyncMillis.millis(Date(timeIntervalSince1970: -1.5)) == -1_500)
        let ms: Int64 = 1_794_873_600_123
        #expect(SyncMillis.millis(SyncMillis.date(millis: ms)) == ms)
    }
}
