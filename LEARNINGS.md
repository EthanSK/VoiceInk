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
**Date:** 2026-06-28T00:00:00Z
**Trigger:** Feature: record-while-transcribing (decoupled capture from transcription)
**Symptom:** Could not start a NEW dictation while the previous one was still transcribing; pressing record during .transcribing was ignored.
**Root cause:** VoiceInkEngine was SINGLE-FLIGHT — its toggleRecord STOP branch AWAITED runPipeline INLINE on the MainActor before the mic could be reused, and RecorderUIManager's re-entrancy guard ignored toggles during .transcribing/.enhancing (to protect that inline-awaited pipeline from a stray cancel).
**Fix:** Refactored engine to a @Published [RecordingSession] collection (new RecordingSession.swift). STOP now flips the session to .transcribing and ENQUEUES its pipeline on a SERIAL FIFO transcription queue (a chained Task<Void,Never> on the MainActor: each enqueue awaits the previous tail then runs runPipeline(for:)) instead of awaiting inline — mic frees instantly. Serial (NOT concurrent) is mandatory because whisperModelManager.whisperContext is a shared singleton actor + cleanupResources tears down the shared model; serial ⇒ completion order == recording order ⇒ FIFO delivery for free. Derived recordingState reflects ONLY the active recording session, falling back to .idle when none recording (CRITICAL: RecordingShortcutManager.canHandleShortcutAction blocks toggles when state is .transcribing, so reporting .idle keeps the record shortcut usable mid-transcription). RecorderUIManager guard now STARTS a new session on toggle-during-transcribing. UI: stacked recorder cards — Mini stacks transcribing cards UPWARD off a bottom-anchored base (offset y = -cardSpacing*indexFromBottom); Notch keeps the pill + stacks "transcribing…" chips beneath it. Per-card cancel via engine.cancelSession(id:); cancel poisoning keyed per-session by pipelineTranscriptionID.
**Commit:** PR #3 merged to main (squash 4133454). Fixup 9b1e48c removed a redundant RecorderStateProvider conformance on the VoiceInkEngine class line that broke the Mini build with "redundant conformance" — conformance already lived in VoiceInkEngine+Protocols.swift. Built + installed on MBP via Mini signing flow (Authority=VoiceInk Local Signing, CFBundleVersion 201).
**Guard:** one-active-recording invariant asserted in toggleRecord START branch; extensive comments on the serial-queue why-not-concurrent rationale, FIFO delivery, derived-state shortcut-gate safety, media resume-between-sessions nuance, and the RecorderUIManager guard transition. LESSON: don't re-declare a protocol conformance on the class line when an extension already declares it (Swift errors as redundant).
---

---
**Date:** 2026-06-26T18:06:00Z
**Trigger:** Feature request: add cancel button to abort recording
**Symptom:** Wanted a Cancel (X) button next to Stop in recorder panels to abort/discard a recording or in-flight transcription without pasting
**Root cause:** No cancel control existed in the UI, though mid-flight cancellation infra already existed in the engine
**Fix:** Added shared RecorderCancelButton (red xmark) to MiniRecorderView + NotchRecorderView via RecorderComponents.swift; wired closure through Mini/Notch WindowManager + RecorderUIManager.cancelRecording() -> VoiceInkEngine.cancelRecording(). Reused existing cancel path: in-flight transcription IDs go to canceledPipelineTranscriptionIDs and shouldCancel() gate discards text (no paste); runs same recorder.stopRecording() so playbackController.resumeMedia()+unmuteSystemAudio() resume paused media. Button hidden at idle/busy; idempotent.
**Commit:** PR#2 merged to main
**Guard:** Button only shown while recording/transcribing; engine idle branch makes cancel idempotent; reuses stop teardown so media-resume path is identical
---

---
**Date:** 2026-06-26T00:00:00Z
**Trigger:** Cancel-recording-button task 2026-06-26
**Symptom:** No user-facing way to ABORT/discard a running recording or in-flight transcription without it pasting text; only Stop (finish+transcribe+paste) existed.
**Root cause:** A clean cancel teardown already existed in the codebase (RecorderUIManager.cancelRecording → VoiceInkEngine.cancelRecording) but was only reachable via Esc / the conditional grey close button — there was no dedicated cancel control in the recorder panels.
**Fix:** Added red `RecorderCancelButton` (xmark) in RecorderComponents.swift next to Stop in BOTH MiniRecorderView and NotchRecorderView, wired via a new `onCancelTapped` closure threaded through MiniWindowManager/NotchWindowManager to the EXISTING cancelRecording() path. That path poisons the in-flight pipeline (result discarded, never pasted), calls recorder.stopRecording() — the SAME stop path normal Stop uses, which resumes paused media (playbackController.resumeMedia()) + unmutes — clears state, dismisses the panel. Commit 3837de4 (PR #2).
**Guard:** `shouldShowCancelButton` only renders the button for .starting/.recording/.transcribing/.enhancing (hidden at .idle/.busy, idempotent if pressed); reuses the already-tested cancel teardown instead of a new one; thorough inline comments explain discard-not-deliver + media-resume.
---
**Date:** 2026-06-23T23:35:07Z
**Trigger:** Deep-research task on VoiceInk++ media pause/resume reliability (2026-06-23)
**Symptom:** Media (Spotify/Music/browser/podcast) doesn't reliably pause on dictation record-start or resumes wrong on stop; sometimes STARTS playback that wasn't playing
**Root cause:** resumeMedia() simulated the NX_KEYTYPE_PLAY HID media key = a STATE-BLIND TOGGLE; with stale async-MediaRemote-listener state it toggled the wrong way (started unpaused media, or failed to resume). Resume guard also depended on the live listener observing isPlaying==false which lags, so resume silently bailed.
**Fix:** Rewrote PlaybackController as a state machine (idle -> pausedByUs(source) -> idle) that records EXACTLY what it paused and re-issues an EXPLICIT play to only that source. Fallback ladder: (1) Spotify/Apple Music via AppleScript player-state + explicit pause/play (new AppleScriptMediaControl.swift); (2) cross-app MediaRemote-adapter explicit pause()/play() via the entitled /usr/bin/perl host (works on macOS 26 where direct framework access is gated since 15.4); (3) removed the HID toggle entirely. Nothing-playing => do nothing.
**Commit:** efbdd85
**Guard:** Inline comments document the state machine + macOS-26 perl-host rationale; no-toggle invariant; isAppStillRunning guards resume against quit-mid-recording
---

---
**Date:** 2026-06-21T23:06:52Z
**Trigger:** Ethan task 2026-06-22: make focus-lock automatic (no gesture) — mouse-button ⇧⌃⌥ pulse can't be held
**Symptom:** Manual stop-hold focus-lock gesture (long-press ⇧⌃⌥) never engages for Ethan because his record trigger is a MOUSE BUTTON that pulses the modifier combo as a ~0.1s tap he physically cannot hold, so the start-field restore never fired.
**Root cause:** The whole focus-lock 'paste into the field I started in' feature was gated behind a HOLD gesture (stop-hold timer crossing longPressThreshold). A mouse-button modifier pulse always reads as a short tap → lock never armed → restoreFocusToLock() always a no-op.
**Fix:** Made the decision AUTOMATIC at paste time, no gesture. captureCandidate() at record-start still persists the start field. In TranscriptionDelivery.paste(), new FocusLockService.isEditableElementFocused() reads the frontmost app's AX focused element role/subrole: editable role (AXTextField/AXTextArea/AXComboBox/AXSearchField) or settable-string kAXValue → paste at cursor; ambiguous (AXWebArea/AXGroup/AXScrollArea/AXUnknown/web/Electron) → bias TRUE (paste at cursor, never hijack); clearly non-text (AXButton/AXMenuItem/AXImage/AXStaticText/AXCheckBox/AXRadioButton/AXLink/AXList/AXRow/AXCell/AXWindow/AXApplication/etc.) or NO focused element → restore to start candidate. Self-excludes com.ethansk.VoiceInkPlusPlus (falls back to next regular app). Auto path arms the lock pre-dismiss (flips @Published isLockActive → amber FocusLockIndicator shows ~280ms) then performAutoRestoreToCandidate() does the AX focus-set UNCONDITIONALLY (same-pid divergence from restoreFocusToLock's no-op, since focus may be on a non-editable element in the same app). Any AX failure → ambiguous → true (safe, no hijack). Old gesture plumbing left intact but secondary.
**Commit:** 659c9f8
**Guard:** isEditableElementFocused biases hard to true on uncertainty (only hijacks when CONFIDENT nothing editable focused); performAutoRestoreToCandidate documented same-pid divergence; VIPPDebug 'focuslock: AUTO-decide editableFocused=<bool> ...' log line at the decision; os_log type-safety self-checked (all interpolations local vars or ?? wrapped, role bridged CFString→String?→unwrapped). MBP cannot build (codesign) — Mini builds.
---

---
**Date:** 2026-06-21T20:42:37Z
**Trigger:** Ethan task 2026-06-21: stop-hold focus-lock doesn't work for modifier-only ⇧⌃⌥ (live-log confirmed STOP short-tap dur=0.10..0.14)
**Symptom:** Stop-hold focus-lock never engaged for Ethan's modifier-only ⇧⌃⌥ toggle shortcut; every stop logged as a ~0.10s short-tap → no lock, so 'paste into the field I started in' never triggered.
**Root cause:** For a modifier-only shortcut the monitor synthesises a key-up almost immediately (~0.1s) regardless of how long the keys are physically held. That spurious early key-up took the short-tap branch and CANCELLED the 0.45s stop-hold threshold timer before it could fire, so promoteToLock() never ran.
**Fix:** RecordingShortcutModeHandler now captures whether the active record Shortcut is modifierOnly + its modifier mask at STOP key-down (via new shortcutForAction closure). For modifier-only shortcuts the STOP key-up is IGNORED for the lock decision (does NOT cancel the timer); the threshold timer fires at longPressThreshold and decides by LIVE NSEvent.modifierFlags (new FocusLockService.requiredModifiersStillHeld(required:) isSuperset check) — required modifiers still held ⇒ promoteToLock, released ⇒ clearCandidate. KEY shortcuts keep the old reliable-key-up timing path. UI: FocusLockIndicator now shows a lock.fill glyph + amber tint when isLockActive so the locked mode is visibly distinct.
**Commit:** 6add5a0
**Guard:** Big modifier-only ~0.1s key-up comment blocks at the STOP key-down timer + STOP key-up branch + requiredModifiersStillHeld(); reset clears currentStopIsModifierOnly/currentStopRequiredModifiers; START press also clears them to prevent leak. New VIPPDebug line: 'focuslock: STOP threshold reached → modifiers still held=<bool> (required=<raw>, current=<raw>) → promoteToLock|tap'. MBP cannot build (codesign) — Mini builds.
---

---
**Date:** 2026-06-21T00:02:09Z
**Trigger:** Ethan task 2026-06-21: move focus-lock decision from start to stop press for toggle+tap gesture
**Symptom:** Focus-lock 'paste into the field I started in' never triggered for Ethan because the long-press lock decision was on the START press, but his gesture is a modifier-only TOGGLE (⇧⌃⌥, toggle mode): TAP to start, TAP to stop. The start tap never crossed longPressThreshold so the lock never armed.
**Root cause:** OLD model armed the promote-timer on the START key-down. In toggle+tap usage the start press is a quick tap → timer cancelled at start key-up → lock never armed → restoreFocusToLock() always a no-op.
**Fix:** Moved the lock decision from START to STOP. START press: ALWAYS captureCandidate() and PERSIST it for the whole session (do NOT clearCandidate on start key-up). STOP press (key-down, where startsFreshRecording==false): arm a stop-hold threshold timer; if combo still held at longPressThreshold → promoteToLock() (paste into original field); short tap → clearCandidate (normal cursor paste). Added currentPressStartedRecording flag so handleKeyUp knows start-vs-stop side. Added FocusLockService.stopHoldDecisionPending + a bounded grace-wait in TranscriptionDelivery.paste() for the rare fast-transcription race. Mirrored the old promote-timer pattern (weak self + isShortcutPressed/activeRecordingShortcutAction guards). Did NOT touch the same-pid no-op regression guard in restoreFocusToLock().
**Commit:** 71e6dc9
**Guard:** Big START→STOP model comment blocks at every changed site (handler longPressLockTask doc, handleKeyDown start+stop branches, handleKeyUp start-vs-stop resolve, FocusLockService captureCandidate persist note, TranscriptionDelivery grace-wait). New VIPPDebug lines: RECORD START captured candidate (persisting), STOP press arming stop-hold timer, STOP long-hold→promoteToLock, STOP short-tap→clearCandidate. Filter: subsystem==com.ethansk.VoiceInkPlusPlus category==VIPPDebug. MBP cannot build (codesign) — Mini builds.
---

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

