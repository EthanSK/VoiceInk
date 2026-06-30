import Foundation
import os

/// AppNapGuard — keeps VoiceInk's main run loop alive while the Mac is idle so the
/// global record hotkey responds on the FIRST press.
///
/// ── THE BUG THIS GUARDS AGAINST ───────────────────────────────────────────────
/// VoiceInk runs as a background/menu-bar (accessory) app. macOS "App Nap" throttles
/// or suspends the main run loop of a background app once it has been idle for a while
/// (e.g. the user hasn't touched mouse/keyboard for ~30–60 min). Our global record
/// hotkey is delivered by a CGEventTap whose run-loop source lives on the MAIN run loop
/// (see ShortcutMonitor.installEventTap → CFRunLoopGetMain). When App Nap throttles that
/// run loop:
///   1. The tap callback stops being serviced promptly.
///   2. macOS disables the now-unresponsive tap (kCGEventTapDisabledByTimeout).
///   3. The first key press(es) after idle only wake the run loop / get consumed
///      re-enabling the tap — they do NOT start a recording.
/// Net symptom: "I have to press record ~4 times after the machine's been idle before it
/// actually starts, and it misses the start of my speech." ← exactly Ethan's report.
///
/// ── THE FIX ───────────────────────────────────────────────────────────────────
/// Hold a single, app-lifetime `ProcessInfo.beginActivity` assertion. The
/// `.userInitiatedAllowingIdleSystemSleep` option set tells macOS: "do NOT App-Nap this
/// process" (so our run loop keeps being serviced and the hotkey tap stays armed), while
/// STILL allowing the system to idle-sleep normally (we are not a media app — we must not
/// keep the Mac awake). We deliberately do NOT use `.latencyCritical`: that disables CPU
/// power management and is overkill for a hotkey listener.
///
/// This is the standard, documented approach for global-hotkey utilities that must stay
/// responsive in the background. The assertion is released automatically when the process
/// exits (and explicitly in deinit, which in practice never runs for this app-lifetime
/// singleton).
@MainActor
final class AppNapGuard {
    static let shared = AppNapGuard()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppNapGuard")

    /// The live activity token. Held for the entire app lifetime; releasing it would
    /// re-expose us to App Nap, so nothing clears it except process exit.
    private var activityToken: NSObjectProtocol?

    private init() {
        // Begin the activity immediately on first access (called from VoiceInkApp.init).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep the global record hotkey responsive while the Mac is idle (prevents App Nap from throttling the CGEventTap run loop)."
        )
        logger.notice("AppNapGuard active — App Nap disabled for the app lifetime (idle system sleep still allowed)")
    }

    deinit {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
    }
}
