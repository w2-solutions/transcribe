import AVFoundation
import Foundation
import Observation
import TranscribeCore

/// Transcript playback and "Listen" clips (§6.4, §6.5, §9 "Playback bar").
///
/// - `currentTime` is refreshed about every 50 ms while playing, so the now-playing highlight follows within 100 ms.
/// - Speed cycles 1 → 1.5 → 2 → 0.75 and is kept across loads.
/// - A clip plays `range` once and then stops; `playingClipID` is non-nil only while it plays.
/// - Reaching the end of the file rewinds to 0 so the next Play starts from the top.
/// - On iOS, an audio-session interruption (a call) or losing the output route (headphones unplugged) pauses.
@MainActor @Observable
public final class PlaybackController {
    public static let rates: [Float] = [1, 1.5, 2, 0.75]
    public private(set) var loadedURL: URL?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0     // updated ~20 Hz while playing
    public private(set) var duration: TimeInterval = 0
    public private(set) var rate: Float = 1
    public private(set) var playingClipID: String?            // non-nil while a clip plays

    /// Seconds between position updates while playing.
    static let tickInterval: Duration = .milliseconds(50)

    @ObservationIgnored private let makeBackend: @MainActor (URL) throws -> any PlaybackBackend
    @ObservationIgnored private var backend: (any PlaybackBackend)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var clipEnd: TimeInterval?
    @ObservationIgnored private var sessionObservers: [any NSObjectProtocol] = []
    /// True while microphone capture owns the audio session. Playback then leaves the session alone, since
    /// changing its category or deactivating it would stop the recording. `AppEnvironment` wires it to the recorder.
    @ObservationIgnored public var isCaptureActive: @MainActor () -> Bool = { false }
    /// Session calls, injectable so tests can see them (iOS only in the app).
    @ObservationIgnored var sessionActions: PlaybackSessionActions = .system

    public init() {
        self.makeBackend = { url in try AVPlaybackBackend(url: url) }
        observeAudioSession()
    }

    /// Tests inject a scripted backend.
    init(backend makeBackend: @escaping @MainActor (URL) throws -> any PlaybackBackend) {
        self.makeBackend = makeBackend
    }

    isolated deinit {
        ticker?.cancel()
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Loading

    /// No-op if already loaded.
    public func load(url: URL) throws {
        if loadedURL == url, backend != nil { return }
        stop()
        let b = try makeBackend(url)
        b.rate = rate
        backend = b
        loadedURL = url
        duration = b.duration
        currentTime = 0
    }

    // MARK: Transport

    public func play() {
        clearClip()
        startPlayback()
    }

    public func pause() {
        backend?.pause()
        isPlaying = false
        clearClip()
        stopTicker()
        if let backend { currentTime = backend.currentTime }
        deactivateSessionIfIdle()
    }

    public func toggle() { isPlaying ? pause() : play() }

    public func seek(to time: TimeInterval) {
        clearClip()
        setPosition(time)
    }

    public func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
        backend?.rate = rate
    }

    /// Plays [range] of url once, then stops; `id` identifies the clip row.
    public func playClip(url: URL, range: TimeRange, id: String) {
        do { try load(url: url) } catch { return }
        guard range.duration > 0, range.start < duration else { return }
        setPosition(range.start)
        clipEnd = Swift.min(range.end, duration)
        playingClipID = id
        startPlayback()
    }

    public func stop() {
        let wasPlaying = isPlaying
        backend?.stop()
        isPlaying = false
        clearClip()
        stopTicker()
        if wasPlaying { deactivateSessionIfIdle() }
    }

    // MARK: Internals

    private func startPlayback() {
        guard let backend else { return }
        if duration > 0, currentTime >= duration - 0.05 { setPosition(0) }
        activatePlaybackSession()
        backend.rate = rate
        guard backend.play() else { isPlaying = false; return }
        isPlaying = true
        startTicker()
    }

    private func setPosition(_ time: TimeInterval) {
        let t = Swift.max(0, Swift.min(time, duration))
        backend?.currentTime = t
        currentTime = t
    }

    private func clearClip() {
        clipEnd = nil
        playingClipID = nil
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func stopTicker() { ticker?.cancel(); ticker = nil }

    /// One position update. Internal so tests can drive time deterministically.
    func tick() {
        guard let backend, isPlaying else { return }
        currentTime = backend.currentTime
        if let end = clipEnd, currentTime >= end {
            backend.pause()
            setPosition(end)
            isPlaying = false
            clearClip()
            stopTicker()
            deactivateSessionIfIdle()
            return
        }
        if !backend.isPlaying {
            // Reached the end of the file: rewind so the next Play starts again.
            isPlaying = false
            clearClip()
            stopTicker()
            setPosition(0)
            deactivateSessionIfIdle()
        }
    }

    // MARK: Audio session (iOS)

    /// Sets the spoken-audio playback category unless capture is running. The test is "is capture running",
    /// not "is the category .playAndRecord": the category outlives a recording, and keeping it would route
    /// playback to the earpiece.
    private func activatePlaybackSession() {
        let capturing = isCaptureActive()
        if !capturing { sessionActions.setPlaybackCategory() }
        sessionActions.activate()
    }

    /// Lets other apps' audio (music, podcasts) resume once playback has stopped, unless capture holds the session.
    private func deactivateSessionIfIdle() {
        guard !isPlaying, !isCaptureActive() else { return }
        sessionActions.deactivate()
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        // iOS 27 reports an interruption as the session becoming inactive (source other than the app itself).
        let interruption = center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            let byApp = context?.source == .app
            MainActor.assumeIsolated {
                if !byApp { self?.pauseIfPlaying() }
            }
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            MainActor.assumeIsolated {
                if raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable { self?.pauseIfPlaying() }
            }
        }
        sessionObservers = [interruption, route]
        #endif
    }

    private func pauseIfPlaying() { if isPlaying { pause() } }
}

// MARK: - Session actions

/// The three audio-session calls playback makes. `.system` uses AVAudioSession on iOS and does nothing elsewhere.
struct PlaybackSessionActions {
    var setPlaybackCategory: @MainActor () -> Void
    var activate: @MainActor () -> Void
    var deactivate: @MainActor () -> Void

    @MainActor static let system = PlaybackSessionActions(
        setPlaybackCategory: {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            #endif
        },
        activate: {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
        },
        deactivate: {
            #if os(iOS)
            // Its own didBecomeInactive has source .app, which observeAudioSession ignores.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        })
}

// MARK: - Backend

/// The audio player behind `PlaybackController` (AVAudioPlayer in the app; scripted in tests).
@MainActor
protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    /// Returns false when playback could not start.
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class AVPlaybackBackend: PlaybackBackend {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        let p = try AVAudioPlayer(contentsOf: url)
        p.enableRate = true          // must be set before prepareToPlay
        p.prepareToPlay()
        player = p
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
}
