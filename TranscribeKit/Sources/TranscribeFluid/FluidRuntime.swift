import FluidAudio

/// Bundled, read-only models: FluidAudio must never download, purge or expect revision markers.
///
/// - `ModelHub.offlineMode = true`: FluidAudio's own advice for apps that bundle their models
///   (ModelHub.swift:25-33). Every download surface then throws instead of touching the network, and a failed
///   load rethrows at once instead of purging the folder and downloading it again.
/// - Every `ModelHub` load checks the folder against `ModelRegistry.mapRevision(repo.remotePath, default:
///   repo.revision)`. With no `.fluidaudio-revision` marker, `ModelCache.matchesRevision` accepts the folder only
///   when that revision is "main" (ModelCache.swift:21-31). FluidAudio pins some repos to a commit (the diarizer
///   today; others can opt in with any release), and the bundle carries no dotfiles, so every bundled repo is
///   overridden to "main" through the public `ModelRegistry.revisionOverrides`, not only the ones pinned today.
///   `scripts/models.lock` pins the real commits, and the "Bundled models lock" tests tie them to FluidAudio's.
///
/// Both settings are process-global. They are set once, before any loader runs (`FluidSpeechEngine.init`), and
/// nothing in the app sets them back.
enum FluidRuntime {
    /// Every repo whose files ship in `BundledModels/`: Parakeet TDT v3 and the community-1 diarizer load through
    /// `ModelHub`; Nemotron 3 loads straight from its folder, and is listed so the override covers it if that changes.
    /// The "Bundled models lock" tests require this to match the repos in `scripts/models.lock`.
    static let bundledRepos: [Repo] = [.parakeetV3, .diarizer, .nemotron3Diarization]

    private static let once: Void = {
        ModelHub.offlineMode = true
        var overrides = ModelRegistry.revisionOverrides
        for repo in bundledRepos {
            overrides[repo.remotePath] = "main"   // bundle has no .fluidaudio-revision; matchesRevision → true for "main"
        }
        ModelRegistry.revisionOverrides = overrides
    }()

    static func lockDown() { _ = once }
}
