# Transcribe

On-device conversation transcription for iPhone (iPhone 15 is the target device) and Mac. After a recording ends, the app separates the speakers. A voice shows as "Speaker 1 / Speaker 2" until it is named once; the app then saves a voice profile and auto-labels that person in later recordings.

Status: iPhone app in development (fake and FluidAudio engines); no Mac target yet.

## Design references

- **Screen mockups (iPhone + Mac, glass look):** https://claude.ai/artifact/U9phTarKM5eApPJm95PCjk
  Nine iPhone screens (library, recording, separating voices, transcript unnamed, name a speaker, transcript auto-labelled, voices, voice profile, settings) and two Mac windows.
- **C4 architecture (Level 1 system context, Level 2 containers):** https://claude.ai/artifact/JbF7QjWTjWrAEAbfocz1Et

Both artifacts are private to the owner's Claude account. Read them with the Artifact tool, not a web fetch.

## Product rules

- All audio processing runs on-device, and the app needs no network: the speech models ship inside the app.
- Speaker separation runs after the recording finishes, never live. Live text has no speaker labels.
- Naming a speaker once saves a voice profile; matching against saved profiles is automatic afterwards, and the user can correct a wrong match.
- Voice profiles stay on the device that recorded them. There is no iCloud sync and no sharing between iPhone and Mac; each device learns voices separately.

## Proposed architecture

- Native SwiftUI for both platforms, using Apple's Liquid Glass for the floating control layer only (toolbars, record dock, player bar, sheets, sidebar). Content sits on plain surfaces.
- Two thin app targets (iPhone, Mac) over one shared Swift package, `TranscribeKit`: capture, transcribe, separate speakers, match voices. `TranscribeKit` is built on FluidAudio (see Speech stack).
- On-device stores: recordings (transcripts and speaker turns), audio files, voice profiles (name + voice embeddings). Model files are read-only resources in the app bundle (`BundledModels/`).

## Design tokens used in the mockups

- Ground `#EEF1F5`, ink `#0E1116`, secondary text `#4A5361`.
- Accent blue `#2457F5` (recognised state, active playback); record red `#E5484D`.
- Speaker colours carry identity from "Speaker N" through to the named person: teal `#0E7C86`, rose `#C2255C`, amber `#B4530A` for unnamed, violet `#6741D9`.
- Unnamed speakers use a dashed outline chip; saved voices use a filled chip.

## Decisions

- **Voice profiles are per-device only** (decided 2026-11-23). Reason: a voice profile depends on the microphone it was recorded with, so a profile from the iPhone mic would not transfer cleanly to the Mac mic. Do not add iCloud or any cross-device sync for voices.
- **Minimum OS is iOS 27 and macOS 27** (decided 2026-11-23, the releases current on that date; iOS was at 27.2.1). Liquid Glass can be assumed everywhere, so write no fallback styling for older systems.
- **Models ship in the app** (decided 2026-11-23). Nothing is downloaded after install.
  - `scripts/models.lock` pins every file (repo, revision, size, sha256); `scripts/fetch-models.sh` (`make models`) fills the gitignored `BundledModels/` from it. Never commit model files.
  - No dotfiles in `BundledModels/` (no `.fluidaudio-revision` markers).
  - `FluidRuntime.lockDown()` (FluidAudio offline mode plus the diarizer revision override "main") runs at engine init.
  - Loaders: `AsrModels.load`, `OfflineDiarizerModels.load`, and `Nemotron3Models.load(directory:)` with a flat layout. Never `loadFromHuggingFace` or any download API in app code.
  - Release and archive builds fail without verified models (`scripts/check-models.sh`); Debug device builds warn; simulator builds leave the models out.
  - The old downloaded `Models/` folder in Application Support is deleted at launch.
  - A FluidAudio bump means `./scripts/fetch-models.sh --update-lock` and a green `swift test`.

## Speech stack (decided 2026-11-23)

Liam confirmed FluidAudio after three independent research passes all picked it. It is still unproven on a real iPhone 15.

- **One Swift package: FluidAudio** (`FluidInference/FluidAudio`, Apache-2.0, Core ML). It covers all three jobs:
  - Transcription: Parakeet TDT v3 via `AsrManager`.
  - Speaker separation after recording: Nemotron 3 fast128 is the primary separator; `OfflineDiarizerManager` (pyannote Community-1 pipeline) is the fallback and also the embedder.
  - Voice embeddings: WeSpeaker ResNet34, 256 numbers per voice, from `DiarizationResult.speakerDatabase` or `embedSpans(...)`.
- **We write the voice matcher ourselves.** FluidAudio's `SpeakerManager` only works with its streaming diariser, not the offline one. Our matcher stores embeddings per named person and compares new speakers by cosine similarity after normalising the vectors.
- **Runner-up: sherpa-onnx** (Apache-2.0, ONNX Runtime). Also one package, with a ready-made enrol/search manager, but CPU by default and no published accuracy figures.
- **Ruled out:** Apple's Speech frameworks (no speaker separation), Argmax open tier (no Parakeet; Parakeet is paid with a 1,000-device minimum), Picovoice (needs online key validation), FluidAudio's CAM++ embedder (trained on Mandarin speakers).

Rules that follow from the research:

- Run transcription and speaker separation one after the other, never at once, and lower the diariser batch size (about 8) on iPhone to limit memory.
- Store the embedding model name and version with every voice profile. A model change means re-enrolling everyone. Models change only with an app update; a change to the speaker-diarization rows in `scripts/models.lock` requires bumping `EmbeddingModelID.revision`.
- Keep several embeddings per person (start with up to 8), not one average. Add one only when the user confirms a name or the match is very strong.
- Never name a single short turn on its own. Name the whole speaker for the recording; leave overlapping speech out of embeddings.
- Three outcomes for a match: auto-label, ask "Is this Karan?", or leave as Unknown. A wrong name is worse than Unknown.
- Starting thresholds (untested guesses to tune on real recordings): auto-label at cosine similarity 0.55 or more and 0.10 clear of the runner-up; ask between 0.40 and 0.55; need about 10 s of clean speech to create a profile and 3 s to identify.
- Live text while recording is display-only and uses `FluidLiveRecording.liveConfig`: a 2 s step with 1 s of lookahead (first words at about 3 s, then every 2 s; measured on a Mac, not yet on an iPhone 15). Do not use FluidAudio's `.streaming` preset: it decodes 11 s at a time, so the first words take 13 s. Each step is one model run, so check battery and heat on the iPhone before going below 2 s.
- Parakeet and community-1 are CC-BY-4.0, Nemotron 3 is OpenMDW-1.1; the app redistributes all three, so the attributions screen keeps their licences.

To check first on a real iPhone 15: that Parakeet TDT v3 loads (a different Parakeet variant fails on its A16 chip), and peak memory and speed of the offline diariser. No published figures exist for either. Also measure the install and download size with the bundled models, the first-launch prepare time, and the prepare time after an app update.

## Testing approach (decided 2026-11-23)

- **Logic tests:** Swift Testing on `TranscribeKit`, run with `swift test`. No simulator. Covers the matcher, thresholds and storage; the real FluidAudio engine is tested here against recorded audio files.
- **Flow tests:** XCUITest via `xcodebuild test`, one per mockup flow, on iPhone simulator and Mac.
- **Ad-hoc checks while building:** `xcrun simctl` (boot, install, launch, screenshot) plus `axe` (tap, type, read the screen). Third-party and disposable; nothing important depends on it. Needs `axe` 2.1.1 or later on Xcode 27 (1.2.1 fails).
- **The UI talks to `TranscribeKit` through a protocol** with a real engine (FluidAudio) and a fake engine (scripted results, no models, no microphone). A launch argument selects the fake engine and seeds app state. UI tests and ad-hoc checks use the fake engine.
- The Mac app needs no simulator: XCUITest runs it natively, taking over the screen and mouse for a few seconds. `axe` does not work on Mac.
- Shared UI tests need two per-platform helpers: `click()` on Mac versus `tap()` on iPhone, and a text's string is in `value` on Mac but `label` on iPhone.
- Every control gets an `accessibilityIdentifier` from the first screen.
- The simulator cannot stand in for the real iPhone 15 on model loading, memory, speed or microphone behaviour.
- Gated real-engine tests use the fetched folder: `cd TranscribeKit && TRANSCRIBE_MODELS_DIR=$PWD/../BundledModels swift test --filter FluidEngineTests`.

## Subagents

- **Every subagent runs on Opus 5.5** (`claude-opus-5-5`). Pass `model: "opus"` on every Agent tool call, and set the same model on every agent in a workflow script. This applies to all agent types (Explore, Plan, general-purpose, reviewers and the rest), even where the agent's own definition names a different model.
- Do not use `subagent_type: "fork"`: a fork always inherits the main session's model and ignores the override.

## Open decisions

- Match thresholds and minimum speech for a voice profile (tune on real recordings).
- App name ("Transcribe" is a working name).
