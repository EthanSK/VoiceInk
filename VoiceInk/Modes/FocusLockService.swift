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
// NOTE: ObservableObject conformance (added for the recorder-UI indicator).
// The recorder views (MiniRecorderView / NotchRecorderView) show a small caption
// — "Using input from voice start" — ABOVE the waveform whenever a long-press
// focus lock is armed for the CURRENT recording. SwiftUI needs to observe that
// state to update live, so we publish `isLockActive` and bump it in the two
// places the lock transitions (promoteToLock arms it, clearLock releases it).
// @MainActor keeps all mutation on the main thread, which is also where SwiftUI
// reads @Published — so no actor hops / threading issues for the observers.
@MainActor
final class FocusLockService: ObservableObject {
    static let shared = FocusLockService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FocusLock")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Surfaces which restore
    // branch runs at delivery (no lock / same-app no-op / real cross-app restore) so we
    // can confirm Feature A is NOT touching focus on a normal dictation.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

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
    // ORIGINAL field. ALSO drives the recorder-UI "Using input from voice start"
    // indicator above the waveform.
    //
    // This is a @Published STORED property (not a computed one) so SwiftUI's
    // ObservableObject machinery fires objectWillChange when it flips — a computed
    // `lockedTarget != nil` would never notify observers. It is kept perfectly in
    // sync with `lockedTarget` via the single mutation helper below: every place
    // that sets/clears `lockedTarget` goes through `setLockedTarget(_:)`, which is
    // the ONLY writer of both fields. Invariant: isLockActive == (lockedTarget != nil).
    @Published private(set) var isLockActive: Bool = false

    // Single chokepoint for mutating the lock so the @Published `isLockActive`
    // mirror can never drift from `lockedTarget`. MainActor-isolated, so the
    // @Published write happens on the main thread where SwiftUI observes it.
    private func setLockedTarget(_ newValue: Candidate?) {
        lockedTarget = newValue
        let active = newValue != nil
        if isLockActive != active {
            isLockActive = active
        }
    }

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
        // VIPPDebug: proves a candidate was successfully built at key-down (AX trusted,
        // a focused element existed, owning app resolved). bundleId wrapped with
        // ?? "nil" because it's a String? — os_log needs a non-optional interpolation.
        vippLog.info("focuslock: candidate captured pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
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
        // Route through setLockedTarget so the @Published isLockActive flips and
        // the recorder UI shows "Using input from voice start" for this recording.
        setLockedTarget(candidate)
        logger.notice("Focus lock ARMED on \(candidate.bundleId ?? "unknown", privacy: .public) (long-press)")
        // VIPPDebug: the long-hold threshold was crossed and we committed the lock —
        // isLockActive is now true so #785 frontmost-follow is suppressed for this
        // session. bundleId is String? → ?? "nil". This is the moment delivery will
        // later branch on (same-app no-op vs cross-app real restore).
        vippLog.info("focuslock: LONG-HOLD threshold crossed → ARM lock bundle=\(candidate.bundleId ?? "nil", privacy: .public) pid=\(candidate.pid, privacy: .public)")
    }

    // SHORT-PRESS path: discard the candidate captured at key-down. Leaves any
    // already-committed lock untouched (there shouldn't be one for a short press,
    // but we never want a short press to drop a real lock).
    func clearCandidate() {
        // VIPPDebug: short-press discard of the key-down candidate. Pairs with the
        // captureCandidate line above to show a press that never armed a lock.
        vippLog.info("focuslock: clearCandidate (short-press discard, no lock)")
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
        // PROVABLE NO-OP WHEN NO LOCK IS ACTIVE (short-press / default path).
        // isLockActive is kept perfectly in sync with lockedTarget via the single
        // writer setLockedTarget(_:), so `lockedTarget == nil` ⇔ `isLockActive == false`.
        // On a normal short press the lock never arms (lockedTarget stays nil), so we
        // return here IMMEDIATELY having read nothing and touched NO focus — the paste
        // then goes to the live frontmost field exactly like upstream. This early
        // return is the load-bearing guarantee that Feature A can't affect the
        // non-locked paste path; do not move any focus-touching code above it.
        guard isLockActive, let target = lockedTarget else {
            vippLog.info("restoreFocusToLock: no lock active → no-op (normal frontmost paste)")
            return false
        }

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

        // ────────────────────────────────────────────────────────────────────────
        // REGRESSION GUARD (2026-06-20): "VoiceInk++ records but never pastes —
        // waveform just disappears". This BROADENS the 2026-06-17 guard (commit
        // 3733622), which was too narrow and itself REGRESSED on a real workflow.
        //
        // THE BUG: the default record mode is HYBRID, and the natural push-to-talk
        // gesture for an ordinary dictation is to HOLD the hotkey for the whole
        // utterance — which is almost always > longPressThreshold (450ms). That hold
        // PROMOTES a focus lock even though the user never moved to a DIFFERENT app.
        // At delivery we then ran the full restore dance (app.activate() +
        // AXUIElementSetAttributeValue of kAXFocusedUIElement to the element captured
        // 450ms+ earlier). By delivery that captured element is frequently STALE (the
        // field re-rendered, the app re-laid-out, the AX identity changed), so forcing
        // focus onto it — or simply re-activating + re-focusing immediately before the
        // Cmd+V CGEvent — created a focus race that swallowed the paste. Net effect for
        // a normal hold dictation: recorder shows "transcribing", waveform disappears,
        // and NOTHING is pasted.
        //
        // WHY THE OLD GUARD WASN'T ENOUGH: the 2026-06-17 guard only no-op'd when the
        // locked app was still frontmost AND the live focused element was CFEqual to
        // the element captured at key-down. But AXUIElement identity is NOT stable
        // across a record→click-into-a-field flow (the #785 case: start recording,
        // THEN click into the destination field in the SAME app). In that flow the
        // focused element at delivery is the CORRECT field but a DIFFERENT AXUIElement
        // ref than the one captured at key-down, so CFEqual fails → the code concluded
        // "focus moved" → ran activate() + AX-focus-set, re-focusing a STALE element
        // right before the Cmd+V → the paste was swallowed. The element-identity check
        // is the exact part that misfires.
        //
        // THE BROADENED GUARD: drop the CFEqual element-identity requirement. A lock
        // only NEEDS a restore when the user switched to a genuinely DIFFERENT app
        // (different frontmost pid). If the locked app is STILL frontmost — the
        // overwhelmingly common case, including the click-into-a-field-in-the-same-app
        // flow above — leave focus COMPLETELY alone and let the paste land in the live
        // focused field, EXACTLY like upstream/base VoiceInk did before Feature A. The
        // genuine "armed a lock, then switched to a DIFFERENT app" case (different
        // frontmost pid) still falls through to the real restore below.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if frontmostApp?.processIdentifier == target.pid {
            // Same app still frontmost => user never left it. Touch nothing; let the
            // normal paste path drop the transcript into whatever field is live now.
            logger.notice("restoreFocusToLock: same app frontmost — no-op, normal paste")
            vippLog.info("restoreFocusToLock: lock armed BUT same app frontmost (pid=\(target.pid, privacy: .public)) → no-op, normal paste")
            return true
        }
        vippLog.info("restoreFocusToLock: lock armed, DIFFERENT app frontmost (front=\(frontmostApp?.processIdentifier ?? -1, privacy: .public) target=\(target.pid, privacy: .public)) → performing real restore")

        // From here, focus HAS genuinely moved to a DIFFERENT app (different frontmost
        // pid): this is the real long-press → switch-to-another-app case the lock
        // exists for. Perform the restore so the transcript lands back in the
        // originally-focused field.

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
            // VIPPDebug: AX focus-set FAILED on the cross-app restore — paste may land
            // in the wrong field or rely on app-activation alone. setResult.rawValue is
            // an Int32; target is non-optional, bundleId is String? → ?? "nil".
            vippLog.info("focuslock: AX restore FAIL (err=\(setResult.rawValue)) target pid=\(target.pid, privacy: .public) bundle=\(target.bundleId ?? "nil", privacy: .public)")
        } else {
            logger.notice("Focus lock RESTORED to \(target.bundleId ?? "unknown", privacy: .public)")
            // VIPPDebug: AX focus-set SUCCEEDED — focus restored to the originally
            // locked element in the cross-app case before the paste keystroke.
            vippLog.info("focuslock: AX restore OK target pid=\(target.pid, privacy: .public) bundle=\(target.bundleId ?? "nil", privacy: .public)")
        }

        return true
    }

    // STEP 4 (always, after delivery): drop the committed lock so it can't leak into
    // the next recording. Also clears any leftover candidate. Idempotent.
    func clearLock() {
        if lockedTarget != nil {
            logger.debug("clearLock: releasing focus lock")
        }
        // VIPPDebug: lock lifecycle END — whatever lock (if any) existed is released
        // and isLockActive flips false. wasActive tells us whether this clear actually
        // tore down a live lock vs was a no-op. Pairs with the ARM line above.
        vippLog.info("focuslock: clearLock (lock lifecycle end) wasActive=\(lockedTarget != nil)")
        // Route through setLockedTarget so the @Published isLockActive flips back
        // to false and the recorder UI HIDES the indicator. This is what makes a
        // later short-press recording NOT still show "Using input from voice start".
        setLockedTarget(nil)
        candidate = nil
    }
}
