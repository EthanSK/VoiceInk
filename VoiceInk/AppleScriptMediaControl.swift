import AppKit
import Foundation
import os

// MARK: - ScriptableMediaApp
//
// The set of media apps that expose a reliable AppleScript dictionary for
// querying playback state and issuing EXPLICIT pause/play. These are special-
// cased because — unlike browser tabs or arbitrary now-playing apps — they give
// us a synchronous, exact `player state` and deterministic control that does not
// depend on the async MediaRemote listener catching up. This is our per-app
// fallback/primary layer for these two apps.
enum ScriptableMediaApp: String, CaseIterable {
    case spotify = "Spotify"
    case appleMusic = "Music"   // Apple Music's scripting target is "Music".

    /// Map a now-playing bundle identifier (as reported by MediaRemote) to one
    /// of our scriptable apps, or nil if it isn't one we script.
    static func from(bundleId: String) -> ScriptableMediaApp? {
        switch bundleId {
        case "com.spotify.client":        return .spotify
        case "com.apple.Music":           return .appleMusic
        default:                          return nil
        }
    }

    /// The bundle identifier, used to check whether the app is still running.
    var bundleId: String {
        switch self {
        case .spotify:    return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }
}

// MARK: - AppleScriptMediaControl
//
// Thin, synchronous AppleScript wrapper around Spotify / Apple Music playback.
//
// WHY APPLESCRIPT (not MediaRemote) FOR THESE APPS:
//   Spotify and Apple Music publish a scripting dictionary with `player state`
//   (returns `playing` / `paused` / `stopped`) and explicit `play` / `pause`
//   verbs. This is the MOST reliable signal+control for them: it's synchronous
//   (no listener lag), it's per-app (no ambiguity about which app we touched),
//   and the verbs are EXPLICIT (pause means pause, play means play — never a
//   toggle). MediaRemote remains the cross-app lever for everything else
//   (browser tabs, podcast apps), but for these two AppleScript is strictly
//   better and immune to the macOS-15.4+ MediaRemote entitlement gating.
//
// IMPORTANT — do NOT auto-launch apps:
//   We only ever talk to an app that is ALREADY running. `isRunning` is checked
//   before any `player state` / control call. Sending raw AppleScript to a non-
//   running app would LAUNCH it (e.g. open Spotify), which is exactly the kind of
//   surprising side effect we must avoid when the user just wants to dictate.
//
// PERMISSIONS:
//   Driving another app via AppleScript requires the Automation (Apple Events)
//   TCC permission for that target app. The first call triggers the standard
//   macOS "VoiceInk wants to control Spotify" prompt; once granted it's silent.
//   If permission is denied, the script errors and we treat it as "couldn't
//   control" — we degrade gracefully (caller falls back to MediaRemote or does
//   nothing); we never crash and never block recording on a media action.
enum AppleScriptMediaControl {

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppleScriptMediaControl")

    /// True if the app is currently running. We never script a non-running app
    /// (that would launch it).
    static func isRunning(_ app: ScriptableMediaApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleId }
    }

    /// Returns true iff the app is running AND its `player state` is `playing`.
    /// Any scripting error (app not scriptable yet, Automation permission
    /// denied, app mid-launch) is treated as "not playing" so we stay safe.
    static func isPlaying(_ app: ScriptableMediaApp) -> Bool {
        guard isRunning(app) else { return false }
        // `player state` is an enum; comparing to the `playing` constant yields a
        // boolean we read back as "true"/"false".
        let script = "tell application \"\(app.rawValue)\" to return (player state is playing)"
        guard let result = runAppleScript(script) else { return false }
        return result.lowercased() == "true"
    }

    /// Issue an EXPLICIT pause. No-op (logged) if the app isn't running.
    static func pause(_ app: ScriptableMediaApp) {
        guard isRunning(app) else { return }
        _ = runAppleScript("tell application \"\(app.rawValue)\" to pause")
    }

    /// Issue an EXPLICIT play. No-op (logged) if the app isn't running.
    static func play(_ app: ScriptableMediaApp) {
        guard isRunning(app) else { return }
        _ = runAppleScript("tell application \"\(app.rawValue)\" to play")
    }

    // MARK: - Private

    /// Run a small AppleScript synchronously and return its trimmed string
    /// result, or nil on error. Synchronous is fine here: these scripts are tiny
    /// and the calls already happen off the main thread (pause/resume run inside
    /// async Tasks). On any error we log + return nil so callers degrade rather
    /// than throw.
    private static func runAppleScript(_ source: String) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            logger.error("Failed to construct NSAppleScript")
            return nil
        }
        let output = script.executeAndReturnError(&errorDict)
        if let errorDict = errorDict {
            // Common cause: Automation (Apple Events) permission not granted, or
            // the app not yet scriptable. We swallow it — media control is best-
            // effort and must never interrupt the dictation flow.
            logger.error("AppleScript error: \(errorDict, privacy: .public)")
            return nil
        }
        return output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
