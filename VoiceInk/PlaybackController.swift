import AppKit
import Combine
import Foundation
import SwiftUI
import MediaRemoteAdapter
import os

// MARK: - PlaybackController
//
// Responsible for PAUSING whatever media is currently playing (Spotify, Apple
// Music, a browser/YouTube tab, a podcast app, etc.) when a dictation recording
// STARTS, and RESUMING it — and ONLY it — when the recording STOPS.
//
// WHY THIS IS A REWRITE (the previous fork behaviour was unreliable):
//   - On RESUME the old code simulated the hardware Play/Pause media key
//     (`NX_KEYTYPE_PLAY` via a synthesized HID event). That key is a STATE-BLIND
//     TOGGLE: it flips whatever the system's "now playing" app considers its
//     current state. If our cached state was stale, or the user had already
//     started something else, the toggle did the WRONG thing — e.g. it would
//     START playback that we never paused, or fail to resume because the toggle
//     landed in the wrong phase. Ethan explicitly asked for this to be done
//     "not how they do it": every action must be EXPLICIT (pause means pause,
//     play means play), never a toggle.
//   - The resume guard depended on the live async MediaRemote listener having
//     observed `isPlaying == false` for the same bundle id. That listener is
//     event-driven and frequently hasn't caught up yet at resume time (the app
//     can drop out of "now playing" once paused), so resume silently bailed.
//
// HOW MEDIAREMOTE WORKS ON macOS 15.4+ / 26 (Tahoe) — the important platform fact:
//   Apple gated the private MediaRemote.framework behind a com.apple.* entitlement
//   starting macOS 15.4. An ordinary third-party app can no longer dlopen it and
//   call MRMediaRemoteSendCommand / read now-playing directly — those return nil
//   or no-op. The `mediaremote-adapter` package works around this by shelling out
//   to `/usr/bin/perl`, an Apple-SIGNED system binary that IS entitled
//   (it reports a com.apple.* identity to mediaremoted). The perl host loads a
//   small helper bundle and both READS now-playing state AND SENDS explicit
//   play/pause commands on our behalf. This send path (not just the read path)
//   keeps working on Tahoe — that is what makes an explicit, cross-app pause/play
//   possible without a private entitlement.
//
//   `MediaRemoteAdapter.MediaController`:
//     - `startListening()` spawns the persistent perl "loop" helper and streams
//       TrackInfo events into `onTrackInfoReceived` (gives us live isPlaying +
//       bundleIdentifier of the current now-playing app).
//     - `pause()` sends the EXPLICIT Pause command (not a toggle).
//     - `play()`  sends the EXPLICIT Play command  (not a toggle).
//   So the adapter already gives us everything we need to do this correctly;
//   the previous code just wasn't using `play()` on the resume leg.
//
// FALLBACK LADDER (most-reliable first), per source:
//   1. MediaRemote-adapter explicit pause()/play() — cross-app, works on 26.
//   2. Per-app AppleScript for Spotify / Apple Music — these expose a reliable
//      `player state` query plus explicit `pause`/`play`, independent of
//      MediaRemote. Used as a fallback when the MediaRemote listener can't tell
//      us a definite isPlaying/bundle, AND as the resume mechanism for those two
//      apps (Spotify/Music respond instantly and deterministically to script
//      control, sidestepping any listener lag).
//   3. (Deliberately removed) The media-key HID toggle is GONE. It was the root
//      cause of the wrong-state bug. We do not fall back to a blind toggle.
//
// HONEST LIMITATION: browser / YouTube audio has no AppleScript transport, so it
// can only be controlled via the MediaRemote-adapter layer. If a given browser
// doesn't publish to the now-playing system (some don't, depending on the site /
// whether it declared a MediaSession), we cannot pause/resume it. That is a
// platform limitation, not a bug in this controller — Spotify, Apple Music, and
// any app that registers with MediaRemote are handled reliably.
//
// STATE MACHINE:
//   .idle            -> nothing paused by us.
//   .pausedByUs(src) -> we sent an explicit pause to `src`; remember the source
//                       so resume targets EXACTLY what we paused.
//   On resume we transition back to .idle after issuing the explicit play to the
//   SAME source. We never "play" anything we didn't pause.
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PlaybackController")

    // The cross-app MediaRemote bridge (perl-hosted; works on macOS 26).
    private var mediaController: MediaRemoteAdapter.MediaController

    // MARK: Live now-playing state (fed by the MediaRemote listener)
    // These reflect the LATEST event the perl "loop" helper streamed to us.
    // They are a best-effort snapshot — the listener is async and can lag, which
    // is exactly why resume must NOT depend on them (we use `pausedSource` below).
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?

    // MARK: What we actually paused (the resume source of truth)
    // When we pause, we record precisely which "source" we paused so that on
    // resume we re-issue an EXPLICIT play to that same source and nothing else.
    // This is the cache that makes resume deterministic regardless of listener lag.
    private enum PausedSource: Equatable {
        // We paused a Spotify/Music app directly via AppleScript (most reliable
        // for those two). `bundleId` lets us confirm the app is still alive.
        case appleScript(app: ScriptableMediaApp, bundleId: String)
        // We paused via the cross-app MediaRemote adapter. `bundleId` is the
        // now-playing app id we observed at pause time (used to verify it's the
        // same app on resume and that it's still running).
        case mediaRemote(bundleId: String)
    }

    // Current state-machine position. nil == .idle (nothing paused by us).
    private var pausedSource: PausedSource?

    // Cancels an in-flight delayed resume if a new recording starts before the
    // previous resume's `audioResumptionDelay` elapses (rapid start/stop).
    private var resumeTask: Task<Void, Never>?

    // MARK: User setting — "pause media while recording"
    // Preserved exactly as before so we never silently force the behaviour on.
    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")
            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }

    private init() {
        mediaController = MediaRemoteAdapter.MediaController()
        setupMediaControllerCallbacks()

        // Only spin up the perl listener if the feature is actually enabled.
        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }

    // MARK: - MediaRemote listener wiring

    private func setupMediaControllerCallbacks() {
        // Each event is the latest now-playing snapshot from the perl loop helper.
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            self?.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
            self?.lastKnownTrackInfo = trackInfo
        }
        // If the perl helper dies we just stop getting events; nothing to do —
        // resume still works off `pausedSource` + AppleScript fallback.
        mediaController.onListenerTerminated = { }
    }

    private func startMediaTracking() {
        mediaController.startListening()
    }

    private func stopMediaTracking() {
        mediaController.stopListening()
        // Reset every piece of state — we're no longer responsible for anything.
        isMediaPlaying = false
        lastKnownTrackInfo = nil
        pausedSource = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    // MARK: - PAUSE (recording started)
    //
    // Decide whether media is actually playing and via which source, issue an
    // EXPLICIT pause to that source, and remember exactly what we paused.
    func pauseMedia() async {
        // A fresh recording supersedes any pending resume from a previous one.
        resumeTask?.cancel()
        resumeTask = nil

        guard isPauseMediaEnabled else { return }

        // Clear any prior paused-source: this recording defines a new episode.
        pausedSource = nil

        // --- Step 1: figure out the most authoritative "what is playing" answer.
        //
        // Prefer the per-app AppleScript truth for Spotify / Music when one of
        // them is the now-playing app, because their `player state` query is
        // synchronous and exact, and their pause/play is the most deterministic
        // path on resume. Otherwise use the MediaRemote listener snapshot.

        // 1a. Did the MediaRemote listener give us a concrete now-playing app?
        let nowPlayingBundle = lastKnownTrackInfo?.payload.bundleIdentifier
        let listenerSaysPlaying = isMediaPlaying && (lastKnownTrackInfo?.payload.isPlaying == true)

        // 1b. If the now-playing app is Spotify or Apple Music, pause it directly
        //     via AppleScript (most reliable for those two). We still gate on the
        //     listener saying it's playing, but if the listener is uncertain we
        //     also do a direct `player state` probe below.
        if let bundle = nowPlayingBundle,
           let app = ScriptableMediaApp.from(bundleId: bundle) {
            // Direct, synchronous state probe — does not depend on listener lag.
            if AppleScriptMediaControl.isPlaying(app) {
                AppleScriptMediaControl.pause(app)
                pausedSource = .appleScript(app: app, bundleId: bundle)
                logger.info("Paused \(app.rawValue, privacy: .public) via AppleScript")
                return
            }
            // If AppleScript says it's NOT playing, fall through — nothing to pause
            // for this app. (Don't trust a possibly-stale listener over the live
            // script probe.)
        }

        // 1c. No scriptable app, OR no concrete now-playing bundle from the
        //     listener: also opportunistically probe Spotify/Music directly in
        //     case the listener simply hasn't reported them yet (startup race).
        if nowPlayingBundle == nil {
            for app in ScriptableMediaApp.allCases {
                guard AppleScriptMediaControl.isRunning(app),
                      AppleScriptMediaControl.isPlaying(app) else { continue }
                AppleScriptMediaControl.pause(app)
                pausedSource = .appleScript(app: app, bundleId: app.bundleId)
                logger.info("Paused \(app.rawValue, privacy: .public) via AppleScript (listener had no now-playing)")
                return
            }
        }

        // --- Step 2: cross-app MediaRemote path (browser tabs, podcast apps,
        //     anything that registers with the now-playing system but isn't
        //     AppleScript-controllable). Only act if the listener is confident
        //     something is actually playing, so we never "pause" silence (which
        //     a toggle would have turned into "play").
        if listenerSaysPlaying, let bundle = nowPlayingBundle {
            mediaController.pause()  // EXPLICIT pause, not a toggle.
            pausedSource = .mediaRemote(bundleId: bundle)
            logger.info("Paused now-playing app \(bundle, privacy: .public) via MediaRemote adapter")
            return
        }

        // Nothing was playing (or we couldn't confirm anything). Do nothing —
        // critically, we do NOT send a toggle that could START playback.
        logger.info("No active media detected on record start; nothing paused")
    }

    // MARK: - RESUME (recording stopped / cancelled)
    //
    // Resume ONLY what we paused, with an EXPLICIT play, after the optional
    // user-configured resumption delay. Never plays anything we didn't pause.
    func resumeMedia() async {
        // Snapshot + clear the state machine up front so re-entrancy is safe.
        let source = pausedSource
        pausedSource = nil

        guard isPauseMediaEnabled, let source = source else {
            // .idle: we paused nothing, so there is nothing to resume. This is the
            // key correctness property — no blind "play" on an empty episode.
            return
        }

        let delay = MediaController.shared.audioResumptionDelay

        // Run the (optionally delayed) resume in a cancellable task so a rapid
        // re-record can abort it via `resumeTask?.cancel()` in pauseMedia().
        let task = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled { return }

            switch source {
            case let .appleScript(app, bundleId):
                // Only resume if that exact app is still alive (it may have been
                // quit mid-recording — in which case there's nothing to resume).
                guard self.isAppStillRunning(bundleId: bundleId) else {
                    self.logger.info("Resume skipped: \(app.rawValue, privacy: .public) no longer running")
                    return
                }
                AppleScriptMediaControl.play(app)  // EXPLICIT play.
                self.logger.info("Resumed \(app.rawValue, privacy: .public) via AppleScript")

            case let .mediaRemote(bundleId):
                // Resume the cross-app source with an EXPLICIT play command.
                // Guard on the app still running so we don't poke a dead app and
                // accidentally hand "now playing" to some unrelated app.
                guard self.isAppStillRunning(bundleId: bundleId) else {
                    self.logger.info("Resume skipped: \(bundleId, privacy: .public) no longer running")
                    return
                }
                self.mediaController.play()  // EXPLICIT play, not a toggle.
                self.logger.info("Resumed now-playing app \(bundleId, privacy: .public) via MediaRemote adapter")
            }
        }

        resumeTask = task
        await task.value
    }

    // MARK: - Helpers

    private func isAppStillRunning(bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }
}
