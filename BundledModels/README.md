# BundledModels

The speech models that ship inside Transcribe.app. The app reads them from here, read-only. It never downloads models.

This folder is filled by `./scripts/fetch-models.sh` (or `make models`) from the pins in `scripts/models.lock`. Add `--from ~/Library/Caches/transcribe-test-models` (or `make models FROM=…`) to copy files you already have instead of downloading them. About 700 MB.

- `parakeet-tdt-0.6b-v3/`: transcription (Parakeet TDT v3).
- `speaker-diarization/`: community-1 speaker separation and voice embeddings.
- `nemotron-3-diarization/`: Nemotron 3 fast128 speaker separation, stored flat.

Rules:

- Never commit model files. Git ignores everything here except this README.
- Never edit files here or add hidden files. `fetch-models.sh` deletes anything the lock does not list, including FluidAudio's `.fluidaudio-*` markers.
- `./scripts/check-models.sh` runs before every build of the Transcribe target. Release builds and archives fail unless every file matches the lock by size and sha256. Debug device builds only warn. Simulator builds leave this folder out.
- To change models (for example after a FluidAudio update), edit the pins in `fetch-models.sh`, run `./scripts/fetch-models.sh --update-lock`, and make `swift test` pass.
