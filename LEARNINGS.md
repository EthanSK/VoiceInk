# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix.

Maintained by the `learnings` skill — see `~/.claude/skills/learnings/skill.md`.

## Format

Each entry looks like:

```
---
**Date:** YYYY-MM-DDTHH:MM:SSZ
**Trigger:** <voice N / message snippet / null>
**Symptom:** <what was visible>
**Root cause:** <what we actually found>
**Fix:** <file:line + short prose + commit SHA>
**Guard:** <test / lint / watchdog / comment that prevents regression — or 'none'>
---
```

## Entries

(newest first)

---
**Date:** 2026-06-20T23:11:34Z
**Trigger:** nope it just failed exactly same again check (2026-06-21)
**Symptom:** VoiceInk++ records, bar shows 'transcribing' briefly then hides without pasting; nothing inserted
**Root cause:** Local Deepgram proxy (127.0.0.1:51337) returned HTTP 500 'Deepgram API key is not configured' — the keychain item 'voiceink-deepgram-tuned-proxy/deepgramAPIKey' it resolves the key from was MISSING (deleted/lost), and config.json deepgram_api_key + plist env were empty, so transcribe failed → empty text → deliver status=failed → dismissRecorderPanel HIDE. NOT the Swift cancel-while-transcribing path (that rebuild chased the wrong bug).
**Fix:** Wrote the valid Deepgram key into the proxy config.json 'deepgram_api_key' (proxy reloads config every request → instant, no restart, avoids flaky launchd→keychain read), chmod 600; also restored the keychain item with -T /usr/bin/security. Confirmed via curl probe: 'key not configured' 500 gone.
**Commit:** a7cb2f3
**Guard:** VIPPDebug os_log across the deliver path (subsystem com.ethansk.VoiceInkPlusPlus) — 'cloud upload END status=500' + 'transcribe FAILED' pinpoint a proxy/key failure instantly; live-capture with: log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus"' --level debug
---

---
**Date:** 2026-06-20T22:45:55Z
**Trigger:** Ethan task 2026-06-20: VoiceInk++ records → transcribing briefly → bar hides → nothing pastes, mixed 200/500-BrokenPipe at proxy
**Symptom:** VoiceInk++ records → 'transcribing' shows for a blink → recorder bar hides instantly → NOTHING pasted. Proxy (127.0.0.1:51337) logs a MIX of 200 (real text returned) and 500 BrokenPipeError (client closed conn early). bf2347e focus-lock broadened guard already shipped yet bug persisted → focus lock NOT the live cause.
**Root cause:** Re-entrancy in the recorder state machine. HYBRID key-up stops recording via RecorderUIManager.toggleRecorderPanel → engine.toggleRecord → runPipeline awaits the cloud upload INLINE on the MainActor. The await frees the MainActor, so a stray record-shortcut event (key-repeat / quick re-press for the next dictation / hybrid key-up re-dispatch / modifier-combo interruption) re-enters toggleRecorderPanel while state==.transcribing and hit 'case .starting,.transcribing,.enhancing: await cancelRecording()'. That ran requestRecordingCancellation() → inserted the active pipeline id into canceledPipelineTranscriptionIDs → the pipeline's post-transcribe shouldCancel() gate threw away the already-returned 200 text via finishCanceledTranscription() and dismissed the bar; the in-flight URLSession upload (child of the cancelled Task) was torn down → proxy saw BrokenPipe 500. Clean runs (no stray event in the brief window) → 200 + paste. Hence the observed mix.
**Fix:** RecorderUIManager.toggleRecorderPanel: split the '.starting,.transcribing,.enhancing → cancelRecording' case. .starting still cancels (genuine pre-record cancel); .transcribing/.enhancing now IGNORE the re-entrant toggle (return) so an in-flight transcription can't be aborted by a stray event — explicit cancel still works via Esc/close (handleDismissRecorderPanelNotification, onCloseTapped). Defensive guard in TranscriptionPipeline: the post-transcribe + pre-delivery shouldCancel() gates now only discard when the returned/final text is EMPTY; a late cancel that races in after a finished 200 delivers the text instead of eating it. Added VIPPDebug os_log (subsystem com.ethansk.VoiceInkPlusPlus category VIPPDebug) across the whole path.
**Commit:** uncommitted (Mini builds)
**Guard:** Big comment block at RecorderUIManager fix site naming the re-entrancy + inline-await window; pipeline non-empty-text guard commented as defensive sibling; VIPPDebug logging at every stage (stop, transcribe start/success/fail+isCancelled, requestRecordingCancellation poison point, deliver branch, paste len+restore decision, every bar HIDE) so the next build reveals the exact sequence. Filter: log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
---

---
**Date:** 2026-06-20T21:56:32Z
**Trigger:** Ethan task 2026-06-20: VoiceInk++ records but never pastes, waveform disappears
**Symptom:** VoiceInk++ records but never pastes — waveform disappears, transcribes fine but NOTHING inserted (esp. record-then-click-into-a-field-in-same-app, the #785 flow). REGRESSION of the 3733622 fix.
**Root cause:** FocusLockService.restoreFocusToLock() no-op guard from 3733622 was too NARROW: it only skipped the restore dance when locked app still frontmost AND CFEqual(liveElement, capturedElement). But AXUIElement identity is NOT stable across record->click-into-field: at delivery the focused element is the CORRECT field but a DIFFERENT AXUIElement ref than captured at key-down, so CFEqual fails -> code concludes 'focus moved' -> runs target.app.activate() + AXUIElementSetAttributeValue(kAXFocusedUIElement, staleElement) right before Cmd+V -> paste swallowed. Base VoiceInk lacks this code so base works.
**Fix:** Broadened the guard in restoreFocusToLock(): early-return no-op whenever the SAME app is still frontmost (NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid), WITHOUT the CFEqual element-identity check. Dropped the element check entirely (it is the misfiring part). Restore dance now runs ONLY when a genuinely DIFFERENT app is frontmost (real long-press->switch-app case). Also: gave OpenAICompatibleTranscriptionService a dedicated URLSession with timeoutIntervalForRequest=180 / timeoutIntervalForResource=300 (was URLSession.shared default 60s) to stop intermittent BrokenPipe/500 mid-proxy-retry.
**Commit:** ff011b3
**Guard:** Big comment block at fix site naming this as a regression of 3733622, citing the record->click-in / #785 workflow and why the CFEqual element check was dropped (AX identity unstable). Verifiable log line preserved: 'restoreFocusToLock: same app frontmost — no-op, normal paste' fires on next normal-dictation test.
---

---
**Date:** 2026-06-16T23:52:08Z
**Trigger:** Ethan task 2026-06-17 (rebrand fork to VoiceInk++ standalone)
**Symptom:** Fork shared bundle id com.prakashjoshipax.VoiceInk with official VoiceInk → TCC permission + UserDefaults/prefs + Application Support + keychain collisions; couldn't install both apps side-by-side with separate permissions
**Root cause:** Forked app kept upstream identity: PRODUCT_BUNDLE_IDENTIFIER, CFBundleDisplayName, and hardcoded App Support / keychain identity strings all pointed at com.prakashjoshipax.VoiceInk, so macOS treated the fork and the official app as the SAME app for TCC/prefs/storage
**Fix:** Rebranded to standalone app VoiceInk++: bundle id -> com.ethansk.VoiceInkPlusPlus (tests .Tests/.UITests), PRODUCT_NAME -> VoiceInkPlusPlus (build-path-safe, builds VoiceInkPlusPlus.app), CFBundleDisplayName -> VoiceInk++ (user-visible). Moved self-storage identity to new id: App Support dir + Recordings subdir (VoiceInk.swift, VoiceInkEngine, TranscriptionAutoCleanupService, AudioFileTranscriptionService/Manager) and keychain service (KeychainService). Updated TEST_HOST, product PBXFileReference path, xcscheme BuildableName, Makefile local/run app paths. User-facing titles: window title + 'Quit VoiceInk++' menu items; system app menu/About/Dock auto-derive from CFBundleDisplayName.
**Commit:** 962339b
**Guard:** Comments at every changed identity site explaining the standalone-fork split; UPDATING.md documents new id + DR (identifier com.ethansk.VoiceInkPlusPlus) for Mini resign-local.sh; iCloud container + lowercase OSLog subsystems DELIBERATELY left as upstream id (CloudKit inert under LOCAL_BUILD; logger labels are cosmetic) with inline comments
---

---
**Date:** 2026-06-16T23:09:30Z
**Trigger:** Ethan task 2026-06-17: short-press dictation pastes nothing regression
**Symptom:** Normal short/hold dictation transcribes fine but pastes NOTHING — recorder shows 'transcribing', disappears, no text inserted. Accessibility + Input Monitoring both granted (not a permissions issue).
**Root cause:** Default record mode is HYBRID; natural push-to-talk = HOLD the hotkey for the whole utterance, almost always >450ms longPressThreshold. That hold PROMOTED a Feature-A focus lock even for ordinary single-field dictation where the user never moved focus. At delivery restoreFocusToLock() ran the full restore dance (NSRunningApplication.activate() + AXUIElementSetAttributeValue kAXFocusedUIElement to the element captured 450ms+ earlier). By delivery that captured element is often STALE (field re-rendered / AX identity changed), so forcing focus + re-activating right before the Cmd+V CGEvent created a focus race that SWALLOWED the paste.
**Fix:** VoiceInk/Modes/FocusLockService.swift restoreFocusToLock(): (1) hardened top guard to a provable no-op 'guard isLockActive, let target = lockedTarget else { return false }'. (2) Added regression guard: read LIVE system-wide focused element + frontmost app; if locked app still frontmost AND live focused element == captured element (CFEqual), user never moved -> do NOTHING and let normal paste run. activate()+AX-focus-set now fires ONLY when focus genuinely moved away (real long-press->click-elsewhere flow).
**Commit:** 3733622
**Guard:** Big inline comment block at the fix site naming the bug + why touching focus when unmoved is pure downside; CFEqual identity check (not Swift == on AXUIElement); early-return no-op documented as load-bearing ('do not move focus-touching code above it'). captureCandidate() only READS focus (AXUIElementCopyAttributeValue), never moves it. Could NOT build on MBP (codesign dialogs) — Mini builds + re-signs.
---

---
**Date:** 2026-06-17T00:00:00Z
**Trigger:** Ethan task — recorder-UI indicator for long-press focus-lock mode
**Symptom:** No on-screen signal that the CURRENT recording is in the long-press "lock the start field" capture mode (Feature A). Ethan wanted a caption above the waveform that reads exactly "Using input from voice start" when the lock is on, and nothing when it's a normal short-press recording.
**Root cause:** FocusLockService exposed lock state only as a COMPUTED `isLockActive { lockedTarget != nil }` — not observable from SwiftUI, so the recorder views couldn't react to it.
**Fix:** Made FocusLockService an ObservableObject with a `@Published private(set) var isLockActive` STORED mirror (computed props never fire objectWillChange). All lock mutation now routes through one chokepoint `setLockedTarget(_:)` (only writer of both `lockedTarget` + `isLockActive`), called from promoteToLock()/clearLock() — invariant isLockActive == (lockedTarget != nil). New reusable `FocusLockIndicator` view in RecorderComponents.swift (`@ObservedObject FocusLockService.shared`) renders a small footnote-weight white-opacity-0.55 caption only when active, collapses to nothing otherwise. Wired ABOVE the waveform in BOTH recorders: MiniRecorderView (extra row above `controlBar`, which holds the AudioVisualizer) and NotchRecorderView (new `focusLockIndicatorRow` above `mainRow`; pillHeight grows by `focusLockIndicatorHeight` only while active + non-collapsed so it never forces the hidden notch open). Clears automatically because clearLock() at delivery/end flips isLockActive false.
**Commit:** 1b0ab77
**Guard:** Single-writer setLockedTarget invariant + thorough comments; indicator gated to active-only so short-press recordings show nothing; @MainActor keeps @Published writes on the SwiftUI-observed thread. NOTE: could not build on MBP (codesign dialogs) — Mac Mini builds + verifies.
---
**Date:** 2026-06-16T21:47:32Z
**Trigger:** RecordingShortcutManager compile-error fix task
**Symptom:** Code analyzer flagged 'Cannot find ShortcutStore/VoiceInkEngine/RecorderUIManager/ShortcutMonitor etc.' + 'canHandleShortcutAction cannot be used on type Self' in RecordingShortcutManager.swift after Feature A focus-lock landed
**Root cause:** SourceKit single-file analysis false positives — those types all exist elsewhere in the module (ShortcutStore.swift, VoiceInkEngine.swift, etc.) and resolve fine at module-compile time. The static-func-vs-computed-property 'canHandleShortcutAction' is also unambiguous to swiftc. Only genuine issue was a real macOS-14 deprecation.
**Fix:** Ignore the per-file Cannot-find/Self false positives (do NOT redefine those symbols). The one real fix: replace deprecated NSRunningApplication.activate(options: [.activateIgnoringOtherApps]) with no-arg .activate() in FocusLockService.swift line ~186.
**Commit:** aef078b
**Guard:** Inline comment at the activate() call site explaining the macOS-14 deprecation + why NSApplication.activate(ignoringOtherApps:) elsewhere is a different API
---

---
**Date:** 2026-06-16T00:00:00Z
**Trigger:** Ethan task 2026-06-16 (long-press focus lock + robust double-Enter)
**Symptom:** (B) On a lagging Mac the single auto-Enter sometimes doesn't register so the dictated message never submits — worse on longer transcripts.
**Root cause:** TranscriptionDelivery posted exactly ONE Return via CGEvent after paste; under load (esp. while the field is still settling a long pasted string) that keystroke can be dropped, so nothing submits.
**Fix:** CursorPaster.performAutoSend now posts Return once, then a SECOND Return after a length-scaled delay (base 120ms + 0.4ms/char, capped 600ms) for plain `.enter` only. Safe because after the first Enter submits the field is empty so the 2nd is a no-op, but if the 1st was dropped the 2nd still submits. Shift/Cmd+Enter stay single-fire. In-process CGEvent (key code 36/0x24), re-checks AXIsProcessTrusted before retry. Commit fae3930.
**Guard:** Tunable named constants (doubleEnterBaseDelay/PerCharDelay/MaxDelay) with rationale comments; second fire gated to `key == .enter`.
---
**Date:** 2026-06-16T00:00:00Z
**Trigger:** Ethan task 2026-06-16 (long-press focus lock + robust double-Enter)
**Symptom:** (A) Wanted: focus a field, long-press record, look away while talking, have the transcript land back in the ORIGINAL field — but #785 frontmost-follow always pastes into wherever you end up.
**Root cause:** By design #785 re-resolves the target at delivery from the frontmost app; there was no way to pin delivery to the field you started in.
**Fix:** New FocusLockService (@MainActor). At record-start key-down, capture AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElement) + owning app. If the hotkey is held > 450ms (longPressThreshold) the capture is promoted to a lock; short press discards it (default path). While locked, ActiveWindowService suppresses the #785 follow. At delivery, re-activate the app (NSRunningApplication.activate) + AXUIElementSetAttributeValue(appElement, kAXFocusedUIElement, stored) before paste, then clear the lock. Wired in RecordingShortcutModeHandler (key-down capture+timer, key-up resolve, reset() teardown) and TranscriptionDelivery (restore before paste, clear after incl. non-paste outcomes). Commit 718a720.
**Guard:** Graceful fallback to default delivery when AX denied / app terminated / element stale (each logged). Reuses existing Accessibility grant (paste needs it anyway). reset()/deliver() clear the lock so it can't leak across sessions. Edge case: apps that don't expose a focused AX element simply never arm a lock.
---
**Date:** 2026-06-15T23:56:32Z
**Trigger:** Ethan task 2026-06-16 (issues #785/#784)
**Symptom:** VoiceInk pastes into the right app but applies the WRONG Mode's auto-send key (issue #785); also nil-resolution left a stale Mode active (issue #784)
**Root cause:** Active Mode was resolved ONLY at record-start from NSWorkspace.frontmostApplication; Ethan starts recording then switches apps, so the Mode never followed the real target app. nil branch had no else, retaining the prior Mode.
**Fix:** Added NSWorkspace.didActivateApplicationNotification observer in ActiveWindowService.start() (wired from VoiceInk.swift app init) that re-runs the same app-config->default->neutral resolution on every frontmost change, including mid-recording (recorder is .nonactivatingPanel so it doesn't steal frontmost). Added else { setActiveConfiguration(nil) } for the neutral fallback. Refactored shared logic into resolveAndApplyConfiguration.
**Commit:** 570a6fa
**Guard:** Thorough comments at start()/handleFrontmostAppActivation/resolveAndApplyConfiguration; ignores own bundle id + nil bundle id; [weak self] in observer + async hop to avoid retain cycle / actor violation
---

