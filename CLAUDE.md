# Transcribe

On-device conversation transcription for iPhone (iPhone 15 is the target device) and Mac. After a recording ends, the app separates the speakers. A voice shows as "Speaker 1 / Speaker 2" until it is named once; the app then saves a voice profile and auto-labels that person in later recordings.

Status: iPhone and Mac apps in development (fake and FluidAudio engines). On a real iPhone 15 all three speech models load, and the one-off setup after each install or update takes about 20 s (measured 2026-11-25). Optional iCloud sync of transcripts and voice profiles is built and tested against a fake iCloud only; it has never run against real CloudKit (see "Not yet verified"). The Mac app ships outside the App Store as a Developer ID–signed, notarised DMG; the only one made so far (2026-11-24) is of the build before sync.

## Design references

- **Screen mockups (iPhone + Mac, glass look):** https://claude.ai/artifact/U9phTarKM5eApPJm95PCjk
  Nine iPhone screens (library, recording, separating voices, transcript unnamed, name a speaker, transcript auto-labelled, voices, voice profile, settings) and two Mac windows.
- **C4 architecture (Level 1 system context, Level 2 containers):** https://claude.ai/artifact/JbF7QjWTjWrAEAbfocz1Et

Both artifacts are private to the owner's Claude account. Read them with the Artifact tool, not a web fetch.

Both were drawn before the Mac app and sync, and still show voices kept per device with no sync. Still to update: the C4 Level 1 and 2 captions, the model host removed, the Mac footers, and "Saved on this iPhone only" made sync-aware. Where they disagree with this file, this file wins.

## Product rules

- All speech processing runs on-device and needs no network: the speech models ship inside the app. The only network use is optional iCloud sync.
- Speaker separation runs after the recording finishes, never live. Live text has no speaker labels.
- Naming a speaker once saves a voice profile; matching against saved profiles is automatic afterwards, and the user can correct a wrong match.
- Sync is optional and off by default. Each device has its own "Sync with iCloud" switch (Settings → iCloud). When it is on, transcripts, speaker labels, folders and voice profiles (names, samples, negatives) sync through the user's private iCloud database. Audio never syncs; a recording made on another device shows "Audio is on your iPhone/Mac" and has no player. Turning sync off never deletes local data. The iCloud copy is deleted only when the user chooses "Remove iCloud Copy…", or "Also Remove from iCloud" when turning sync off.
- Voices are matched per microphone: every recording, sample and negative carries a capture channel (`iphone`, `ipad`, `mac`), taken from the recording the voice was heard in. A voice learned only on another device is never auto-labelled: it is asked about ("Is this Karan?") until the user confirms it once on this device.

## Proposed architecture

- Native SwiftUI for both platforms, using Apple's Liquid Glass for the floating control layer only (toolbars, record dock, player bar, sheets, sidebar). Content sits on plain surfaces.
- Two thin app targets (`Transcribe` for iPhone, `TranscribeMac`) over one shared Swift package, `TranscribeKit`: capture, transcribe, separate speakers, match voices, sync. `TranscribeKit` is built on FluidAudio (see Speech stack). Its modules: `TranscribeCore`, `TranscribeKit`, `TranscribeDesign`, `TranscribeFluid`, `TranscribeFakes`, `TranscribeCloudKit`.
- On-device stores: recordings (transcripts and speaker turns), audio files, voice profiles (name + voice embeddings), and the sync bookkeeping, all in `Library.store` apart from the audio. Model files are read-only resources in the app bundle (`BundledModels/`).

## Design tokens used in the mockups

- Ground `#EEF1F5`, ink `#0E1116`, secondary text `#4A5361`.
- Accent blue `#2457F5` (recognised state, active playback); record red `#E5484D`.
- Speaker colours carry identity from "Speaker N" through to the named person: teal `#0E7C86`, rose `#C2255C`, amber `#B4530A` for unnamed, violet `#6741D9`.
- Unnamed speakers use a dashed outline chip; saved voices use a filled chip.

## Decisions

- **Voice profiles sync across devices, per microphone** (decided 2026-11-24 at Liam's request; this replaces the 2026-11-23 per-device-only decision). A profile depends on the microphone, so samples and negatives are tagged with the capture channel of their source recording. Auto-labelling needs a trusted sample from the probe's own channel. Caps apply per (profile, channel). Never add code that deletes voice data because the device or install id changed (the old device wipe is gone; `ChannelStamping` backfills channels instead).
- **Sync design** (decided 2026-11-24): `CKSyncEngine`, private database, container `iCloud.ai.w2solutions.transcribe`, one zone `Library`, over the local SwiftData store opened with `cloudKitDatabase: .none`. Never enable SwiftData's own CloudKit sync.
  - Sync state (`SyncRecordState`, `SyncAccountState`) lives in `Library.store` and is saved in the same save as the applied data.
  - Merges happen per field group, three-way against base hashes; the device saving now wins a group both sides changed, except a speaker's rejected names, which are united. Delete wins.
  - Only `.ready` recordings (and their speakers) sync. Processing state, audio, match traces and search text stay on the device.
  - Record fields go in `encryptedValues` (except the schema version `sv` and the transcript asset). A record with a newer `sv` pauses sync ("Paused: update Transcribe").
  - A full scan that would delete many records (more than 25 of a type and over 20% of them) pauses and asks before sending the deletes.
  - `TranscribeKit/Sync` has no CloudKit import; only `TranscribeCloudKit` imports CloudKit.
  - Changes arrive by iCloud push, with a check every 60 s as a safety net while the app is in front and none in the background (Liam, 2026-11-24, after pushes to the Mac proved late or missing; an earlier same-day decision of no timer at all was reversed). Do not shorten the interval or poll in the background without asking. iCloud pushes only to the app (bundle id) that created a subscription, and the two apps share the container under different bundle ids, so each app keeps its own silent `CKDatabaseSubscription` named `changes.<bundle id>` (`CloudKitTransport.ensureOwnSubscription`); the engine's single subscription only ever reached whichever app turned sync on first. A push runs `SyncCoordinator.remoteChangeNotified` through each app's `PushDelegate`. Sync also fetches when the app comes to the front (`setForeground`, at most once per 10 s) and when asked (the Sync Now toolbar button on both apps, pull down on the iPhone's Recordings list, Cmd-R on the Mac). `CloudKitTransport.fetchChanges` also catches up with its own `recordZoneChanges` token, because the engine's `fetchChanges` did not always reach the server.
  - A local change is sent 1 s after it is saved (`sendLocalChanges`); the engine's own scheduled send waited minutes on the iPhone.
  - After a send leaves work behind (a merged conflict, a retryable error, a failed send), the coordinator runs its own follow-up sync with backoff (3 s, 15 s, 60 s, then every 5 min); `CKSyncEngine` does not reliably send these again. `FakeTransport.setMaxAttemptsPerSend(1)` behaves like the engine.
  - Naming or confirming a saved voice never writes its `VoiceProfile` (`namedAt` is set once, when the profile is made), so two devices naming one person do not conflict on it.
  - Every send and fetch outcome is logged with record type, record name and CKError code as public (`/usr/bin/log show --predicate 'subsystem == "ai.w2solutions.transcribe"' --info`), never field values. The last problem shows under the Settings status line until a sync goes through.
- **Mac app** (decided 2026-11-24): bundle id `ai.w2solutions.transcribe.mac`, App Sandbox and Hardened Runtime in every configuration, models bundled in every configuration (`TRANSCRIBE_MODELS_DIR` does not work in the sandbox). Shared views live in `Apps/Shared/Sources`; each app has `PlatformServices`; iOS-only modifiers go through `PlatformCompat`; device wording goes through `DeviceCopy`.
- **Minimum OS is iOS 27 and macOS 27** (decided 2026-11-23, the releases current on that date; iOS was at 27.2.1). Liquid Glass can be assumed everywhere, so write no fallback styling for older systems.
- **Models ship in the app** (decided 2026-11-23). Nothing is downloaded after install.
  - `scripts/models.lock` pins every file (repo, revision, size, sha256); `scripts/fetch-models.sh` (`make models`) fills the gitignored `BundledModels/` from it. Never commit model files.
  - No dotfiles in `BundledModels/` (no `.fluidaudio-revision` markers).
  - `FluidRuntime.lockDown()` (FluidAudio offline mode plus a revision override of "main" for all three model repos) runs at engine init.
  - Loaders: `AsrModels.load`, `OfflineDiarizerModels.load`, and `Nemotron3Models.load(directory:)` with a flat layout. Never `loadFromHuggingFace` or any download API in app code.
  - Release and archive builds fail without verified models (`scripts/check-models.sh`, a pre-build phase of both app targets); Debug device and Mac builds warn; iPhone simulator builds leave the models out.
  - The old downloaded `Models/` folder in Application Support is deleted at launch.
  - A FluidAudio bump means `./scripts/fetch-models.sh --update-lock` and a green `swift test`.
- **Setup after install or update** (decided 2026-11-25, measured on the iPhone 15 with Debug builds installed over the top with devicectl).
  - iOS drops the compiled Neural Engine models on every install or update, wherever the model files live: a byte-identical copy in an App Group folder (same absolute path and inode) was still fully cold after an install over the top (76.0 s, 76.6 s), and a copy in Application Support moved with the data container. Apple DTS conceded this (developer forum thread 853157); another developer measured the same with TestFlight updates (LocalFlow PR 30). The stable-copy and App Group routes were built, measured and removed: do not rebuild them. An unused App Group `group.ai.w2solutions.transcribe` is left in the developer portal from that experiment.
  - Never hold a file lock (`flock`) in a shared (App Group) container: iOS kills an app that is suspended holding one (0xdead10cc).
  - Stage order (Liam, 2026-11-25): diarizer (community-1), nemotron (CPU), asr (Parakeet), warmup. `PrepareStage.allCases` is the order everywhere (engine, `PreparePlan`, fake engine, setup steps). Short steps first because iOS gives about 27 s after the user leaves and Parakeet's compile used all of it, so the steps after it waited for the return. The warm-up needs the loaded Parakeet, so it follows asr. The engine becomes ready once, when every stage is done: no staged readiness.
  - Background (rules in `FluidSpeechEngine`'s type doc): a prepare starts only in front and holds a short background task (`BackgroundTaskBridge.beginShortTask`) while it runs, begun again on each return. A Neural Engine stage starts in the background only with Background Inference and while that task is held; without Background Inference a Neural Engine stage that touched the background is dropped and setup pauses. The CPU stage (Nemotron) needs no Background Inference: in the background it starts while the short task is held, and is kept whenever it returns. A pause is never a failure; setup finishes on the next return, warm for every stage whose compile finished. Measured with Background Inference, leaving 5 s into a cold setup (old order, phone locked): Parakeet's compile carried on in the background (33.2 s against 18.8 s in front), ended about 1 s after the allowance ran out (27 s after leaving) and was kept; the next stage was not started (`startRefused`); on return the rest took 3.9 s.
  - Background Inference entitlement (`com.apple.developer.background-tasks.continued-processing.inference`) is in `Apps/iPhone/Transcribe.entitlements`, and the App ID `ai.w2solutions.transcribe` has the Background Inference capability (ticked by Liam on 2026-11-25). iOS has no runtime check for it, so the build setting `TRANSCRIBE_BACKGROUND_INFERENCE` (set to `$(TRANSCRIBE_SYNC)`, so it follows the entitlements file the build picks) is mirrored into Info.plist as `TranscribeBackgroundInference`; `TRANSCRIBE_SYNC=NO` builds have neither. `BackgroundInferenceConfigTests` pins the pairing. Never in the simulator or on the Mac. DEBUG launch arguments for device measurements: `-assumeNoBackgroundInference`, `-startStagesInBackground`.
  - Prepare log: every real-engine prepare appends one JSON line (per-stage seconds and verdicts, background facts, outcome, install stamp, OS build, hardware model, `nemotronUnits`) to `prepare-log.jsonl` next to `Library.store` (`AppPaths.prepareLogURL`; last 200 lines, left out of backups), and logs a summary at notice level (subsystem `ai.w2solutions.transcribe`, category `ModelPrep`). From the phone: `xcrun devicectl device copy from --device 00008120-000A40D12E000032 --domain-type appDataContainer --domain-identifier ai.w2solutions.transcribe --source "Library/Application Support/Transcribe/prepare-log.jsonl" --destination prepare-log.jsonl`. Lines with `"nemotronUnits":"cpuAndNeuralEngine"` come from the earlier Neural Engine builds (2026-11-25) and are never used for Nemotron's estimate.
  - Setup progress UI: the engine sends a `PreparePlan` and per-stage `PrepareEvent`s; `ModelManager.setup` (`SetupProgress`) turns them into a bar that never goes backwards and the running step's title (voice recognition, speaker separation, transcription; no "Step n of 3": the two short steps end before the card shows), shown by `SetupStatusView` on the Library card (only a cold setup, after 1.5 s), the Speech models screen and a waiting recording's panel ("Setup in progress"). A stage counts as done once a later one starts, so a Nemotron that fails to load (the community-1 fallback) does not hold the step or the bar. Expected seconds come from `PrepareEstimates`: this device's measured cold stages from the prepare log, else built-in numbers (iPhone 15 measured; Mac from the M4 Max gated tests, rounded up). A time left shows only from this device's numbers; otherwise "This can take a little while.", and only while at least a quarter of the expected work is still to come.
- **Voice learning** (decided 2026-11-23): learn from every naming, confirmation, correction and rejection, as above. Store schema V2 adds negatives and per-speaker match traces. Any schema change adds a new version, a migration stage and a fixture test.
- **Schema V3** (2026-11-24) adds capture channels and the sync models. `TranscribeSchemaV1` and `TranscribeSchemaV2` are frozen: never edit them. Builds from before V3 cannot open a V3 store.

## Speech stack (decided 2026-11-23)

Liam confirmed FluidAudio after three independent research passes all picked it. On a real iPhone 15 all three models load and the setup is measured (2026-11-25); speed, memory and accuracy on real recordings there are not measured yet.

- **One Swift package: FluidAudio** (`FluidInference/FluidAudio`, Apache-2.0, Core ML). It covers all three jobs:
  - Transcription: Parakeet TDT v3 via `AsrManager`.
  - Speaker separation after recording: Nemotron 3 fast128 is the primary separator, on the CPU; `OfflineDiarizerManager` (pyannote Community-1 pipeline) is the fallback and also the embedder.
  - Voice embeddings: WeSpeaker ResNet34, 256 numbers per voice, from `DiarizationResult.speakerDatabase` or `embedSpans(...)`.
- **We write the voice matcher ourselves.** FluidAudio's `SpeakerManager` only works with its streaming diariser, not the offline one. Our matcher stores embeddings per named person and compares new speakers by cosine similarity after normalising the vectors.
- **Runner-up: sherpa-onnx** (Apache-2.0, ONNX Runtime). Also one package, with a ready-made enrol/search manager, but CPU by default and no published accuracy figures.
- **Ruled out:** Apple's Speech frameworks (no speaker separation), Argmax open tier (no Parakeet; Parakeet is paid with a 1,000-device minimum), Picovoice (needs online key validation), FluidAudio's CAM++ embedder (trained on Mandarin speakers).

Rules that follow from the research:

- Run transcription and speaker separation one after the other, never at once, and lower the diariser batch size (about 8) on iPhone to limit memory.
- **Nemotron 3 runs on the CPU only** (decided by Liam on 2026-11-25): `NemotronSeparation.computeUnits = .cpuOnly`, pinned by `presetIsTheFullPrecisionFast128Bundle`. Parakeet and community-1 stay on the Neural Engine (`.cpuAndNeuralEngine`). Nothing uses the GPU (iOS forbids it in the background). Why: on the iPhone 15 (A16, iOS 27 build 24B156) Nemotron's Neural Engine compile took 55–58 s of a 76–83 s cold setup, after every install; on the CPU its cold load is 0.89 s and the cold setup 20.7 s (Parakeet 18.8 s, diarizer 0.98 s, warm-up 0.06 s). A relaunch of the same build sets up in 0.4–1.1 s. On an M4 Max (indicative only): cold load 0.5–0.65 s on the CPU against about 30 s on the Neural Engine, 46 ms against 24 ms per 10.24 s chunk, outputs within 0.0002 on random input. Smaller or quantised exports did not compile faster, compiles run one at a time, and a compile at `.background` QoS was 7x slower. Setup still loads Nemotron once (about 1 s) to check it loads; a failure there makes separation use community-1 for the process. Not yet measured: CPU separation time and battery cost on a real recording on the iPhone, and speaker-label parity with the Neural Engine on real speech. Do not move it back to the Neural Engine without asking Liam.
- Store the embedding model name and version with every voice profile. A model change means re-enrolling everyone. Models change only with an app update; a change to the speaker-diarization rows in `scripts/models.lock` requires bumping `EmbeddingModelID.revision`.
- Keep several embeddings per person, not one average: up to 12 per capture channel. A sample's channel is its source recording's, never the device where the user clicked, and a new sample never evicts one from another channel. Store one whenever the user names, confirms or corrects a saved person (5 s of clean speech or more; under 10 s it is a "short" sample). Store one automatically only when the person's user-confirmed samples from the probe's channel alone match at 0.70 or more, 0.20 clear of the runner-up, from 10 s of coherent speech (span coherence ≥ 0.5).
- Score = mean of the two best sample cosines. The best one must be a user-confirmed sample of 10 s or more **from the probe's channel**. Samples from other channels, automatic samples and short samples can only fill second place. Without such a sample the voice can only be asked about, never auto-labelled.
- When the user says a voice is not P (No on a suggestion, naming a suggested voice as someone else, or correcting a wrong label), store that voice as a negative for P (5 s or more, up to 8 per person per channel). Negatives from every channel count. P is not offered for a voice at least as close to a negative as to P itself. A blocked P still counts as runner-up. Naming that voice as P later deletes the conflicting negatives. With Remember off, nothing is stored.
- The auto-label margin also counts unnamed voices that do not score as P (the cohort), so a recurring never-named person cannot be auto-labelled as P. The window is the last 100 recordings (and at most 300 voices) per capture channel, so recordings synced from another device never push this device's voices out; every channel's voices count.
- A speaker's vector is the weighted mean of its span embeddings after dropping spans under 0.35 cosine to the weighted medoid, as long as at least half the speech remains.
- No per-person thresholds. Thresholds change only after reading real numbers from Settings → Copy voice matching log (version 2: samples and trusted samples per channel, and each recording's channel and input route).
- Never name a single short turn on its own. Name the whole speaker for the recording; leave overlapping speech out of embeddings.
- Three outcomes for a match: auto-label, ask "Is this Karan?", or leave as Unknown. A wrong name is worse than Unknown.
- Starting thresholds (untested guesses to tune on real recordings): auto-label at cosine similarity 0.55 or more and 0.10 clear of the runner-up; ask between 0.40 and 0.55; need about 10 s of clean speech to create a profile, 5 s to add a sample or a negative to an existing person, and 3 s to identify.
- Live text while recording is display-only and uses `FluidLiveRecording.liveConfig`: a 2 s step with 1 s of lookahead (first words at about 3 s, then every 2 s; measured on a Mac, not yet on an iPhone 15). Do not use FluidAudio's `.streaming` preset: it decodes 11 s at a time, so the first words take 13 s. Each step is one model run, so check battery and heat on the iPhone before going below 2 s.
- Parakeet and community-1 are CC-BY-4.0, Nemotron 3 is OpenMDW-1.1; the app redistributes all three, so the attributions screen keeps their licences.

Measured on the real iPhone 15 (2026-11-25): Parakeet TDT v3 loads on its A16 chip (a different Parakeet variant fails there), and the setup times above; the setup after an app update is as long as the first, since iOS drops the compiled models on every install. Still to check there: peak memory and speed of the offline diariser and of CPU Nemotron on real recordings (no published figures exist), battery and heat, speaker labels on real speech, and the install and download size with the bundled models.

## Testing approach (decided 2026-11-23)

- **Logic tests:** Swift Testing on `TranscribeKit`, run with `swift test`. No simulator. Covers the matcher, thresholds, storage and sync; the real FluidAudio engine is tested here against recorded audio files.
- **Flow tests:** XCUITest via `xcodebuild test`, one per mockup flow. iPhone simulator: `./scripts/test-ui.sh` (`make test-ui`). Mac: `make test-ui-mac`.
- **Ad-hoc checks while building:** `xcrun simctl` (boot, install, launch, screenshot) plus `axe` (tap, type, read the screen). Third-party and disposable; nothing important depends on it. Needs `axe` 2.1.1 or later on Xcode 27 (1.2.1 fails).
- **The UI talks to `TranscribeKit` through a protocol** with a real engine (FluidAudio) and a fake engine (scripted results, no models, no microphone). A launch argument selects the fake engine and seeds app state. UI tests and ad-hoc checks use the fake engine.
- The Mac app needs no simulator: XCUITest runs it natively, taking over the screen and mouse for a few seconds. It needs an unlocked screen, and two Mac UI runs must never run at once. `axe` does not work on Mac.
- Shared UI tests need two per-platform helpers: `click()` on Mac versus `tap()` on iPhone, and a text's string is in `value` on Mac but `label` on iPhone.
- Every control gets an `accessibilityIdentifier` from the first screen.
- The simulator cannot stand in for the real iPhone 15 on model loading, memory, speed or microphone behaviour.
- Gated real-engine tests use the fetched folder: `cd TranscribeKit && TRANSCRIBE_MODELS_DIR=$PWD/../BundledModels swift test --filter FluidEngineTests`.
- Migrations are tested against a committed store written by the previous schema: `Fixtures/V1Library` (`MigrationTests`) and `Fixtures/V2Library` (`MigrationV3Tests`), in `TranscribeKit/Tests/TranscribeKitTests`.
- Sync logic is tested in `swift test` with `FakeCloud` / `FakeTransport` (several in-memory devices on one fake server); `TranscribeCloudKitTests` round-trips the `CKRecord` codec. UI tests select a fake sync scenario with the environment variable `TRANSCRIBE_SYNC=fake:<scenario>` and a capture channel with `TRANSCRIBE_CHANNEL` (both read only with the fake engine or in UI tests). UI-test and fake-engine runs never create a CloudKit transport, so they never touch CloudKit.
- The cross-device voice flow is `MacCrossDeviceTests`: seed `karanFromIPhone`, script `newVoices` (not `knownVoices`: Karan speaks under 5 s there, too little to add a sample), channel `mac`. `ChannelAwareStoreTests` runs the same flow in `swift test`.

## Building and installing on the iPhone

The phone is "Liam's iPhone" (iPhone 15), device ID `00008120-000A40D12E000032`. It must be paired with this Mac. Check with `xcrun devicectl list devices`: it should say `available (paired)`.

Run from the repo root. `$DD` is any folder outside the repo for build output (a temp folder is fine).

1. **Fetch the models and generate the project.** The models ship inside the app but are not in git, and `Transcribe.xcodeproj` is not committed:
   `make models && xcodegen generate`
   A Debug device build without the models only warns, and the app then cannot load them.
2. **Build for the device.** `project.yml` leaves the signing team empty on purpose, so pass it on the command line. Xcode then creates the signing profile itself. The Mac has two signing identities. Use team `53FBF5CS9U`; the app on the phone is signed with it. If the phone is new to the team, add `-allowProvisioningDeviceRegistration`. Choose one:
   - **With iCloud (the default, `TRANSCRIBE_SYNC=YES`):**
     `xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -configuration Debug -destination 'id=00008120-000A40D12E000032' -derivedDataPath $DD DEVELOPMENT_TEAM=53FBF5CS9U -allowProvisioningUpdates build`
     This signs with `Apps/iPhone/Transcribe.entitlements` (container `iCloud.ai.w2solutions.transcribe`, CloudKit, push, Background Inference). It needs an Apple account for the team signed in to Xcode (Settings → Accounts), so Xcode can register the App ID `ai.w2solutions.transcribe` with iCloud, Push, Background Inference and the container. Check the result with `codesign -d --entitlements - $DD/Build/Products/Debug-iphoneos/Transcribe.app`: it must list the container and `com.apple.developer.background-tasks.continued-processing.inference`.
   - **Without iCloud:** the same command with `TRANSCRIBE_SYNC=NO` added. This signs with `Apps/iPhone/Transcribe.local.entitlements` (empty: no iCloud, no push, no Background Inference), which the wildcard team profile covers, and sets `TranscribeICloud` and `TranscribeBackgroundInference` = NO in Info.plist, so the app never opens CloudKit, sync reads "Not signed in to iCloud", and setup pauses soon after the user leaves the app. Use this while Xcode has no Apple account signed in.
3. **Install.** This replaces the app and keeps its recordings and voices:
   `xcrun devicectl device install app --device 00008120-000A40D12E000032 $DD/Build/Products/Debug-iphoneos/Transcribe.app`
4. **Launch** (the phone must be unlocked):
   `xcrun devicectl device process launch --device 00008120-000A40D12E000032 ai.w2solutions.transcribe`

To check the result without touching the phone:

- Still running (no crash on launch): `xcrun devicectl device info processes --device 00008120-000A40D12E000032 | grep Transcribe.app`
- Store files: `xcrun devicectl device info files --device 00008120-000A40D12E000032 --domain-type appDataContainer --domain-identifier ai.w2solutions.transcribe --subdirectory "Library/Application Support"`
  The library is `Transcribe/Library.store`. After the first launch of a V3 build there is also `Library.schema-v3` (a marker) and `Library.pre-v3-backup.store` (the copy taken before the upgrade). The V2 marker and backup from earlier upgrades are left as they are.

Rules:

- A plain launch uses the real engine and the real library in `Transcribe/`. The fake engine (`-useFakeEngine`) keeps its data apart in `Transcribe-Fake/`.
- A build with a newer store schema upgrades the library on first launch, and older builds cannot open it afterwards. Run the migration fixture test before installing such a build (for V3: `cd TranscribeKit && swift test --filter MigrationV3Tests`).
- Never delete the app from the phone to fix an install problem: that deletes the recordings and voices.

## Building and releasing the Mac app

- Debug: `make models && xcodegen generate && make build-mac`. With no team this is signed to run locally with `Apps/Mac/TranscribeMac.local.entitlements` (sandbox and microphone, no iCloud: macOS refuses to launch a locally signed app that claims iCloud), and sync reads "Not signed in to iCloud". `make test-ui-mac` builds the same way.
- With `DEVELOPMENT_TEAM=53FBF5CS9U -allowProvisioningUpdates` on the xcodebuild line, the Mac app is signed with Apple Development and `Apps/Mac/TranscribeMac.entitlements` (iCloud and push). That needs the App ID `ai.w2solutions.transcribe.mac` with iCloud and Push and the container, as for the iPhone.
- Release: `make release-mac` (`scripts/release-mac.sh`) archives (Release, team `53FBF5CS9U`), exports with Developer ID (`scripts/ExportOptions-DeveloperID.plist`), checks the signature, hardened runtime, entitlements and the models inside the app, builds `dist/Transcribe-<version>.dmg` (version from `MARKETING_VERSION` in `project.yml`), notarises with the keychain profile `transcribe-notary`, staples and runs Gatekeeper. `make release-mac SKIP_NOTARIZE=1` stops after the signed DMG; without the profile the script stops there and exits 3. The profile exists on this Mac; a person creates it (`xcrun notarytool store-credentials transcribe-notary --apple-id … --team-id 53FBF5CS9U`), never an agent.
- Since sync, the entitlements ask for iCloud, so `make release-mac` also requires the iCloud container with environment Production, `aps-environment` production, an embedded provisioning profile listing the container, and a CloudKit link. It cannot pass until the portal has the Mac App ID with iCloud and the container. If the export does not embed iCloud, a "Developer ID" provisioning profile for `.mac` with iCloud is needed.
- The sandboxed Mac data is in `~/Library/Containers/ai.w2solutions.transcribe.mac/Data/Library/Application Support/Transcribe` (`Transcribe-Fake` for the fake engine).
- CloudKit environments (`TRANSCRIBE_ICLOUD_ENV`, both apps): Debug builds use Development; Release builds and the Developer ID export use Production. To test the phone against the Developer ID Mac, build the iPhone with `TRANSCRIBE_ICLOUD_ENV=Production` on the xcodebuild line.
- Push (`TRANSCRIBE_APS_ENV`) stays `development` in every configuration of both apps, because builds and archives are signed with a development profile, which allows nothing else. The Developer ID export sets `production` from its profile (`release-mac.sh` checks it). It picks the push gateway, not the CloudKit environment.
- New record types or fields must be deployed to Production in the CloudKit Console before a release can sync. This cannot be undone. The schema was first deployed on 2026-11-24 (six record types).
- Before any deploy, make the Development schema complete: Development only defines a type or field when a record with it is first saved, so fields that were always empty on our devices are missing (on 2026-11-24: `VoiceNegative`, a recording's `title`, `language` and `marks`, a speaker's `rejectedProfileIDs`). Run the Debug Mac app once with `open /Applications/Transcribe.app --args -seedCloudSchema` (`CloudSchemaSeeder` saves one record of every type with every field of `CKRecordCodec.kinds`, in a zone of its own, then deletes it), check the log for "Schema seed finished", then deploy and compare the field counts in the console's diff.
- Development and Production are separate databases. A build for the other environment forgets its sync state and joins again (`SyncCoordinator.resetIfCloudEnvironmentChanged`, from the Info.plist key `TranscribeICloudEnvironment`); without that, sync state from one would read as "deleted on the server" in the other and delete local data. Never remove this guard.

## "Ship it"

When Liam says "ship it", merge the work to `main`: commit, push the branch, open a pull request, and merge it once the checks pass. `main` is what gets released:

- iPhone: the merge uploads a TestFlight build through CI (see below). Watch the run; if the runner is offline, say so.
- Mac: not automatic. Only when the Mac app changed and Liam wants a new public download: `make release-mac`, upload the DMG to the R2 bucket `w2-downloads` under a new key, and update `TRANSCRIBE` in the `w2-website` repo's `src/index.js`.

Run `swift test` before merging. A merge that changes the store schema or CloudKit record types needs the checks in "Building and installing on the iPhone" and the Production schema deploy first.

## Releasing the iPhone app to TestFlight

- The App Store Connect app is "W2 Transcribe" (Apple ID 6838568557, bundle id `ai.w2solutions.transcribe`, SKU `w2-transcribe-ios`). The internal tester group "W2 Team" gets every build automatically.
- `make testflight` (`scripts/testflight.sh`) archives Release and uploads. It signs in with the App Store Connect API key "Transcribe CI" (key id `93Y2L9PKNY`, file `~/.appstoreconnect/private_keys/AuthKey_93Y2L9PKNY.p8`), never the Apple account in Xcode, whose sign-in expires mid-upload. Never read, print or commit the key file.
- `BUILD_NUMBER` must be higher than the last upload of the same version (default: UTC date and time). An interrupted upload keeps its build number reserved; use the next one. Builds 1 (stuck) and 2 were used on 2026-11-24.
- CI: `.github/workflows/testflight.yml` runs on every merge to `main` that touches `Apps/`, `TranscribeKit/`, `project.yml`, `scripts/` or the workflow (and by hand). It needs the repo secret `ASC_KEY_P8` and the variables `ASC_KEY_ID` and `ASC_ISSUER_ID` (all set on 2026-11-24).
- CI runs on a self-hosted runner on Liam's Mac (`liam-mac`, label `transcribe-mac`, installed in `~/actions-runner-transcribe` as a launch agent; the repo variable `TESTFLIGHT_RUNNER` names the label). GitHub's hosted Mac images had no Xcode 27 on 2026-11-24. The runner only works while that Mac is on, awake and logged in; a merge made while it is off waits in the queue. If a ship cannot wait, run `make testflight` from `main` instead.
- TestFlight builds use the Production CloudKit environment, like the Developer ID Mac build.

## Not yet verified (as of 2026-11-25)

- Sync has run between the real iPhone and Mac in the Development environment only. Production (TestFlight plus the Developer ID Mac app) had not been tested when this was written.
- Pushes to the Mac were unreliable in Development (none, or one after 99 s), although the iPhone got them at once. Whether Production is better is the open question.
- The manual two-device checklist has only been partly run: recordings and a speaker's name reach the other device. Not yet checked: deletes reaching the other device, turning sync off with Keep, signing out.
- Speaker separation with Nemotron 3 on the CPU on the iPhone: its time on a real recording, its battery cost, and whether its speaker labels match the Neural Engine's on real speech. (On an M4 Max it separates 22.7 s of audio in about 0.45 s.)
- The app's own setup on a Mac. A cold prepare on an M4 Max in the gated tests (fresh model path) took diarizer 0.66 s, Nemotron 0.51 s, Parakeet 13.4 s; slower Macs are unmeasured.
- Setup in TestFlight and Production builds: every setup measurement so far is from Debug builds installed over the top with devicectl.
- Mac UI tests have not been rerun since the push, polling and environment changes of 2026-11-24, nor since the setup progress UI (2026-11-25). The iPhone simulator UI tests passed (50 of 50) on 2026-11-25.

## Subagents

- **Every subagent runs on Opus 5.5** (`claude-opus-5-5`). Pass `model: "opus"` on every Agent tool call, and set the same model on every agent in a workflow script. This applies to all agent types (Explore, Plan, general-purpose, reviewers and the rest), even where the agent's own definition names a different model.
- Do not use `subagent_type: "fork"`: a fork always inherits the main session's model and ignores the override.

## Open decisions

- Match thresholds and minimum speech (tune from the matching log on real recordings; also decide whether short probes, under 8 s, should be limited to asking).
- App name ("Transcribe" is a working name).
- Whether channels should split by input route (AirPods, USB, Continuity) as well as by device class. `captureDetail` and `captureInput` are logged for this, so read the matching log (v2, per-channel counts) first.
- Whether imported audio should be ask-only (today it counts as recorded on the importing device).
- Optional audio sync (off by default) and the CloudKit schema for it.
