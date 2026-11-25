import Foundation
import Testing
import TranscribeCore

@Suite("Attributions")
struct AttributionsTests {
    @Test func requiredEntriesArePresent() {
        let ids = Set(Attributions.all.map(\.id))
        #expect(Attributions.requiredIDs.isSubset(of: ids))
        #expect(ids.count == Attributions.all.count, "ids are unique")
    }

    @Test func everyCCBYEntryHasAURLNotesAndALicenceLink() {
        let ccBy = Attributions.all.filter { $0.licence == "CC-BY-4.0" }
        #expect(ccBy.map(\.id).sorted() == ["community-1", "parakeet"])
        for entry in ccBy {
            #expect(URL(string: entry.url)?.scheme == "https", "\(entry.id) url")
            #expect(!entry.notes.isEmpty)
            #expect(entry.notes.contains("Creative Commons Attribution 4.0"), "\(entry.id) names the licence")
            #expect(entry.notes.contains("Converted to Core ML by FluidInference"), "\(entry.id) states the change")
            #expect(Attributions.licenceURL(for: entry.licence) == Attributions.ccBy40URL)
        }
    }

    @Test func everyEntryHasAReadableLicenceLink() {
        for entry in Attributions.all {
            let link = Attributions.licenceURL(for: entry.licence)
            #expect(link.flatMap(URL.init(string:))?.scheme == "https", "\(entry.id)")
        }
        #expect(Attributions.licenceURL(for: "BSD-3-Clause") == nil)
    }

    /// The Mac app embeds Sparkle (MIT), whose notice must ship with it; the iPhone app does not.
    @Test func sparkleIsCreditedOnTheMacOnly() throws {
        #if os(macOS)
        #expect(Attributions.requiredIDs.contains("sparkle"))
        let sparkle = try #require(Attributions.all.first { $0.id == "sparkle" })
        #expect(sparkle.licence == "MIT")
        #expect(sparkle.url == "https://sparkle-project.org")
        #expect(sparkle.notes.contains("version 2.10.1"))
        #expect(Attributions.fullTextLicences.contains("MIT"))
        #expect(Attributions.licenceURL(for: "MIT") == "https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE")
        let text = try #require(sparkle.licenceText)
        #expect(!text.isEmpty)
        #expect(text.hasPrefix("Copyright (c) 2006-2013 Andy Matuschak."))
        #expect(text.contains("Permission is hereby granted, free of charge"))
        for external in ["EXTERNAL LICENSES", "bsdiff", "sais-lite", "Ed25519", "SUSignatureVerifier.m"] {
            #expect(text.contains(external), "keeps the external licence for \(external)")
        }
        // Libraries come after the models, and Sparkle (Mac only) last.
        #expect(Attributions.all.last?.id == "sparkle")
        #else
        #expect(!Attributions.all.contains { $0.id == "sparkle" })
        #endif
    }

    @Test func modelSourcesMatchTheBrief() throws {
        let parakeet = try #require(Attributions.all.first { $0.id == "parakeet" })
        #expect(parakeet.url == "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
        let community = try #require(Attributions.all.first { $0.id == "community-1" })
        #expect(community.url == "https://huggingface.co/pyannote/speaker-diarization-community-1")
        #expect(community.notes.contains("WeSpeaker ResNet34"))
    }

    /// The bundled speaker-diarization files carry a NOTICE.md (FluidInference/speaker-diarization-coreml at the commit
    /// pinned in scripts/models.lock) asking credit for pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference, and a
    /// statement that the files are modified Core ML conversions.
    @Test func communityOneFollowsItsNotice() throws {
        let community = try #require(Attributions.all.first { $0.id == "community-1" })
        for credit in ["pyannote", "WeSpeaker", "BUT Speech@FIT", "Brno University of Technology", "Fluid Inference"] {
            #expect(community.notes.contains(credit), "credits \(credit)")
        }
        for citation in ["Plaquet and Bredin", "Wang et al.", "Landini et al."] {
            #expect(community.notes.contains(citation), "keeps the README citation \(citation)")
        }
        #expect(community.notes.contains("modified files"))
        #expect(!community.notes.contains("unmodified"), "the files are modified conversions")
        #expect(community.notes.contains(
            "https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md"))
    }

    @Test func fluidAudioCarriesTheFullApacheLicence() throws {
        let fluid = try #require(Attributions.all.first { $0.id == "fluidaudio" })
        #expect(fluid.licence == "Apache-2.0")
        #expect(fluid.url == "https://github.com/FluidInference/FluidAudio")
        let text = try #require(fluid.licenceText)
        #expect(text.contains("Apache License"))
        #expect(text.contains("Version 2.0, January 2004"))
        #expect(text.contains("END OF TERMS AND CONDITIONS"))
        #expect(text.count > 10_000)
    }

    @Test func onlyFullTextLicencesCarryText() {
        for entry in Attributions.all {
            #expect((entry.licenceText != nil) == Attributions.fullTextLicences.contains(entry.licence), "\(entry.id)")
        }
    }

    @Test func nemotronCarriesTheOpenMDWAgreementAndItsSources() throws {
        let nemotron = try #require(Attributions.all.first { $0.id == "nemotron-3-diarization" })
        #expect(nemotron.licence == "OpenMDW-1.1")
        #expect(nemotron.url == "https://huggingface.co/nvidia/Nemotron-3-Diarization")
        #expect(nemotron.notes.contains("NVIDIA"))
        #expect(nemotron.notes.contains("Converted to Core ML by Fluid Inference"))
        #expect(nemotron.notes.contains("https://huggingface.co/FluidInference/nemotron-3-diarization-coreml"))
        #expect(nemotron.notes.contains("OpenMDW License Agreement, version 1.1"))
        #expect(Attributions.licenceURL(for: "OpenMDW-1.1") == "https://openmdw.ai/license/1-1/")
        let text = try #require(nemotron.licenceText)
        #expect(text.hasPrefix("OpenMDW License Agreement, version 1.1 (OpenMDW-1.1)"))
        #expect(text.contains("you shall retain in your distribution (1) a copy of this agreement"))
        #expect(text.contains("does not impose any restrictions or obligations with respect to any use, modification, or sharing of any outputs"))
        #expect(text.contains("IN NO EVENT SHALL THE PROVIDERS OF THE MODEL MATERIALS BE LIABLE"))
        // The model is credited before the library that runs it.
        let ids = Attributions.all.map(\.id)
        #expect(try #require(ids.firstIndex(of: "nemotron-3-diarization")) < (try #require(ids.firstIndex(of: "fluidaudio"))))
    }
}
