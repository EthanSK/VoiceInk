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

