import Foundation
import AppKit
import ApplicationServices
import os

// MARK: - FocusLockService (Feature A: long-press → lock the start field)
//
// PROBLEM / WORKFLOW THIS SOLVES
// ------------------------------
// Default VoiceInk pastes the transcript into whatever app/field is frontmost at
// DELIVERY time (issue #785 "follow the frontmost app"). That's great for the
// common "start dictating, then click the target field" flow.
//
// But Ethan also wants the OPPOSITE flow sometimes: focus a specific text field,
// LONG-PRESS the record hotkey, then look away / click elsewhere while talking —
// and have the transcript land back in the ORIGINAL field he was in when he
// started, NOT wherever he happens to be at delivery.
//
// SOLUTION — "focus lock"
// -----------------------
// • A long-press (hold > threshold) of the record hotkey "locks" the system-wide
//   focused UI element captured at the START of the press as the delivery target.
// • While a lock is active we SUPPRESS the frontmost-app-follow (#785) for that
//   recording session — we deliberately want the start field, not the later one.
// • At delivery we re-activate the locked element's owning app and restore AX
//   focus to the stored element, THEN the normal paste + auto-send runs into it.
// • A normal/short press leaves no lock → fully default behavior (unchanged).
//
// LIFECYCLE (also see the inline comments at each method)
//   key-down            -> captureCandidate()  (remember focused element + app)
//   held past threshold -> promoteToLock()      (candidate becomes the active lock)
//   key released early  -> clearCandidate()     (short press: discard, default path)
//   delivery time       -> restoreFocusToLock() (re-activate app + set AX focus)
//   after delivery       -> clearLock()          (always, success or fail)
//
// ACCESSIBILITY DEPENDENCY
//   Capturing and restoring focus uses the Accessibility (AX) API. VoiceInk
//   ALREADY requires Accessibility to paste via simulated key events
//   (see CursorPaster), so this adds no new permission — if AX is denied, paste
//   wouldn't work anyway. Every AX call here degrades gracefully: if the system
//   doesn't return a focused element, or the stored element is gone/invalid at
//   delivery, we simply fall back to the default (frontmost) delivery path.
@MainActor
final class FocusLockService {
    static let shared = FocusLockService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FocusLock")

    // TUNABLE: how long the record hotkey must be HELD (from key-down) before we
    // treat the press as a "long press" and arm the focus lock. 450ms is long
    // enough to clearly distinguish a deliberate hold from an ordinary tap, but
    // short enough that Ethan doesn't have to wait awkwardly before talking.
    static let longPressThreshold: TimeInterval = 0.45

    // The element + app captured at key-down, BEFORE we know whether this will be
    // a long press. Held here until either promoted to `lockedTarget` (long press)
    // or discarded (short press / release before threshold).
    private struct Candidate {
        let element: AXUIElement
        let app: NSRunningApplication
        let pid: pid_t
        let bundleId: String?
    }
    private var candidate: Candidate?

    // The committed lock for the current recording session. Non-nil ONLY between a
    // confirmed long-press and the moment delivery clears it. While this is non-nil,
    // ActiveWindowService suppresses its frontmost-follow (see `isLockActive`).
    private var lockedTarget: Candidate?

    private init() {}

    // True while a long-press lock is committed. ActiveWindowService reads this to
    // SUPPRESS the #785 frontmost-app-follow for the locked session — otherwise an
    // app switch mid-recording would clobber the Mode/auto-send we want for the
    // ORIGINAL field.
    var isLockActive: Bool { lockedTarget != nil }

    // STEP 1 (key-down): snapshot the currently-focused UI element + its owning app.
    // We capture UNCONDITIONALLY on every record-start key-down because at this
    // instant we don't yet know if it's a long press — and this is the only moment
    // the ORIGINAL field is reliably still focused (the user may click away
    // immediately after). If it turns out to be a short press we just throw the
    // candidate away in clearCandidate().
    func captureCandidate() {
        // Reset any stale state from a prior session first.
        candidate = nil

        guard AXIsProcessTrusted() else {
            // No Accessibility permission -> can't read or restore focus. Bail
            // quietly; delivery will use the default frontmost path.
            logger.debug("captureCandidate skipped: Accessibility not trusted")
            return
        }

        // Ask the system-wide AX element for whatever UI element currently has focus.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            // Some apps (and some non-text focus contexts) don't expose a focused
            // AX element. Nothing to lock; default delivery will handle it.
            logger.debug("captureCandidate: no system-wide focused element (AX err \(result.rawValue))")
            return
        }

        // CFTypeRef -> AXUIElement. force-cast is safe: a successful read of
        // kAXFocusedUIElementAttribute always yields an AXUIElement.
        let element = focusedRef as! AXUIElement

        // Find the owning app via the element's pid, so we can re-activate it at
        // delivery (NSRunningApplication.activate) and match it back up.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else {
            logger.debug("captureCandidate: couldn't resolve owning app for focused element")
            return
        }

        candidate = Candidate(
            element: element,
            app: app,
            pid: pid,
            bundleId: app.bundleIdentifier
        )
        logger.debug("captureCandidate: stored focus in \(app.bundleIdentifier ?? "unknown", privacy: .public)")
    }

    // STEP 2 (held past threshold): promote the candidate to the committed lock.
    // Called only after we've confirmed the hotkey was held longer than
    // longPressThreshold. From here, isLockActive == true so the frontmost-follow
    // is suppressed and delivery will restore to the stored element.
    func promoteToLock() {
        guard let candidate else {
            // No candidate (e.g. AX denied, or no focused element at key-down).
            // Nothing to lock — default behavior remains in effect.
            logger.debug("promoteToLock: no candidate to promote")
            return
        }
        lockedTarget = candidate
        logger.notice("Focus lock ARMED on \(candidate.bundleId ?? "unknown", privacy: .public) (long-press)")
    }

    // SHORT-PRESS path: discard the candidate captured at key-down. Leaves any
    // already-committed lock untouched (there shouldn't be one for a short press,
    // but we never want a short press to drop a real lock).
    func clearCandidate() {
        candidate = nil
    }

    // STEP 3 (delivery): if a lock is active, bring its app forward and restore AX
    // focus to the stored element so the subsequent paste + auto-send land in the
    // ORIGINAL field. Returns true if a lock existed and we attempted a restore
    // (regardless of whether every AX step succeeded), false if there was no lock
    // (caller should just use the default frontmost delivery).
    //
    // We do BOTH: activate the owning app (so it's frontmost for the Cmd+V paste)
    // AND set kAXFocusedUIElementAttribute on the app element to the stored element
    // (so the caret is in the right field, not just the right app).
    @discardableResult
    func restoreFocusToLock() -> Bool {
        guard let target = lockedTarget else { return false }

        guard AXIsProcessTrusted() else {
            // Permission was revoked mid-session. Can't restore — fall back to
            // default delivery (paste wherever we are). Clear so we don't leak the
            // lock into the next session.
            logger.error("restoreFocusToLock: Accessibility no longer trusted; default delivery")
            return true
        }

        // Guard against the app having quit between record-start and delivery.
        if target.app.isTerminated {
            logger.error("restoreFocusToLock: locked app terminated; default delivery")
            return true
        }

        // (a) Re-activate the owning app so it's frontmost for the paste keystroke.
        // Brings it forward even though VoiceInk (or whatever Ethan clicked into) is
        // currently frontmost. macOS 14 deprecated the options-based
        // NSRunningApplication.activate(options:) (the .activateIgnoringOtherApps
        // option in particular) — the no-arg activate() is the supported replacement
        // and already implies "bring this app forward". (NSApplication's separate
        // activate(ignoringOtherApps:) is a different API and stays as-is elsewhere.)
        target.app.activate()

        // (b) Restore AX focus to the exact element. We set kAXFocusedUIElement on
        // the APP-level AX element (the documented way to move focus to a child
        // element). If the stored element is stale/invalid the API returns an
        // error code — we log it and continue; app activation alone often lands the
        // paste in the right place, and worst case it's the same as default.
        let appElement = AXUIElementCreateApplication(target.pid)
        let setResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            target.element
        )
        if setResult != .success {
            // Common when the field no longer exists (page navigated, sheet closed,
            // doc reloaded). Not fatal: the app is at least frontmost now.
            logger.error("restoreFocusToLock: AX setFocused failed (err \(setResult.rawValue)); relying on app activation")
        } else {
            logger.notice("Focus lock RESTORED to \(target.bundleId ?? "unknown", privacy: .public)")
        }

        return true
    }

    // STEP 4 (always, after delivery): drop the committed lock so it can't leak into
    // the next recording. Also clears any leftover candidate. Idempotent.
    func clearLock() {
        if lockedTarget != nil {
            logger.debug("clearLock: releasing focus lock")
        }
        lockedTarget = nil
        candidate = nil
    }
}
