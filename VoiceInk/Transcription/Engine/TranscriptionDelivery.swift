import Foundation
import AppKit   // NSWorkspace (frontmost-app pid for VIPPDebug paste logging)
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Tracks which delivery
    // branch runs and the actual paste (text length) so an empty/suppressed paste is
    // distinguishable from a real one in the unified log.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        // VIPP (skip-mode-processing feature): when true, THIS delivery must paste the RAW
        // transcript and run NO mode post-processing — no custom-command/script
        // (deliverCustomCommand), no `.respond` (deliverResponse). The pipeline already
        // forces `output.outputMode == .paste` when this is set, but we also branch on this
        // explicitly in deliver() so the raw-paste guarantee holds even if `output` were
        // ever wrong. Defaults to false (normal mode processing). One-shot, per-recording.
        var skipPostProcessing: Bool = false
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        vippLog.info("deliver: enter status=\(request.transcription.transcriptionStatus ?? "nil", privacy: .public) outputMode=\(String(describing: request.output.outputMode), privacy: .public) textChars=\(request.text?.count ?? -1, privacy: .public) followUp=\(request.isAssistantFollowUp, privacy: .public) skip=\(request.skipPostProcessing, privacy: .public)")

        // ── VIPP (skip-mode-processing feature) — RAW-PASTE GUARANTEE ────────────────
        // This is THE decision point the user's "skip script" button must control:
        // TranscriptionDelivery routes purely on request.output.outputMode below
        // (.respond → deliverResponse, .customCommand → deliverCustomCommand/script,
        // else → paste). If the one-shot skip flag is set, we DETERMINISTICALLY take the
        // raw-paste branch here — bypassing both deliverCustomCommand (the Mode's shell
        // script) and deliverResponse — regardless of what request.output.outputMode says.
        // This closes the reported bug where the mode's script still ran with skip engaged:
        // even if the upstream `.paste` override were ever lost, this branch forces raw paste.
        // (Assistant follow-ups are a different flow entirely and never carry skip.)
        if request.skipPostProcessing,
           !request.isAssistantFollowUp,
           request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            vippLog.info("deliver: skipPostProcessing ON → FORCING raw paste (bypassing custom-command/respond) outputModeWas=\(String(describing: request.output.outputMode), privacy: .public)")
            // The paste path consumes/clears the focus lock itself; nothing else to release.
            if let text = request.text {
                // Force a plain `.paste` config (strip any customCommand, keep autoSendKey)
                // so paste()'s autoSendKey handling still works on the raw text.
                let rawOutput = OutputRuntimeConfiguration(
                    mode: request.output.mode,
                    outputMode: .paste,
                    autoSendKey: request.output.autoSendKey,
                    customCommand: nil
                )
                await paste(text, output: rawOutput, actions: actions)
            } else {
                FocusLockService.shared.clearLock()
                await actions.dismiss()
            }
            return
        }

        // Feature A (focus lock): ONLY the paste path consumes a focus lock. Every
        // other delivery outcome below (incomplete transcription, assistant
        // follow-up, respond mode, custom command, or empty text) must release any
        // armed lock here so it can't leak into the next recording. The paste path
        // does its own restore+clear, so we leave the lock intact only for it.
        let isPlainPaste = !request.isAssistantFollowUp
            && request.output.outputMode == .paste
            && request.text != nil
            && request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue
        if !isPlainPaste {
            FocusLockService.shared.clearLock()
        }

        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
           request.responseConfig != nil || request.responseError != nil {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, output: request.output, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
                  item.responseConfig != nil {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
              let command = customCommand.trimmedCommand else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice("Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error("Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)")
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, output: OutputRuntimeConfiguration, actions: Actions) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        vippLog.info("paste: BEGIN len=\(pastedText.count, privacy: .public) lockActive=\(FocusLockService.shared.isLockActive, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        // ════════════════════════════════════════════════════════════════════════
        // Feature A — AUTOMATIC focus decision (2026-06-22). THIS is now the primary
        // mechanism; the manual long-press/stop-hold gesture is dead for Ethan because
        // his record trigger is a MOUSE BUTTON pulsing ⇧⌃⌥ as a ~0.1s tap he can't hold
        // (see FocusLockService header + LEARNINGS commits 71e6dc9 / 6add5a0).
        //
        // The field he was in when he STARTED dictating was captured at record-start
        // (FocusLockService.captureCandidate, persisted for the session). Now we decide
        // where the transcript goes by looking at what's focused NOW:
        //
        //   • An EDITABLE text element is focused right now → paste at the CURRENT cursor.
        //     (He moved to a real text field — honor it, exactly like upstream #785.)
        //   • NOTHING editable is focused right now (focus dropped, or it's on a button /
        //     non-text view / the desktop / an app with no text input) → restore focus to
        //     the START candidate and paste THERE.
        //
        // isEditableElementFocused() biases HARD toward "true" (paste at cursor) whenever
        // it's uncertain — we only hijack back to the start-field when CONFIDENT nothing
        // editable has focus. See its big comment for the role classification.
        //
        // WHY WE DECIDE + ARM HERE, BEFORE actions.dismiss():
        // The amber FocusLockIndicator ("Using input from voice start") lives INSIDE the
        // recorder panel, which actions.dismiss() orders out. To let Ethan SEE that the
        // auto path chose his original field, we must flip isLockActive (which drives the
        // indicator) WHILE the recorder is still on screen — i.e. before dismiss. The
        // recorder panel is a NON-ACTIVATING NSPanel, so reading focus here reflects the
        // real target app, not VoiceInk; isEditableElementFocused() also self-excludes
        // VoiceInk++ as a belt-and-braces guard. The actual AX focus-set + app-activate
        // (the focus MOVE) is deferred to just before the paste keystroke below so nothing
        // can steal focus in the gap.
        //
        // Legacy gesture override: if an explicit manual lock somehow IS already active
        // (isLockActive true from the old stop-hold path), honor it as before — that's now
        // the exception, not the rule.
        let useStartFieldRestore: Bool   // true ⇒ restore to START candidate before paste
        let honorExistingManualLock: Bool // true ⇒ old gesture lock is live, use its restore
        if FocusLockService.shared.isLockActive {
            // Old gesture path actually fired (rare for Ethan). The lock is already armed
            // so the indicator is already showing; we'll use the established same-pid-aware
            // restoreFocusToLock() below.
            let editableNow = FocusLockService.shared.isEditableElementFocused()
            vippLog.info("focuslock: AUTO-decide editableFocused=\(editableNow, privacy: .public) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public) → manual-lock already active, honoring existing lock (restore-to-locked-field)")
            honorExistingManualLock = true
            useStartFieldRestore = false
        } else {
            // PRIMARY AUTO PATH. Inspect what's focused right now and branch.
            let editableNow = FocusLockService.shared.isEditableElementFocused()
            if editableNow {
                // A real editable field has focus → leave focus alone, paste at cursor.
                vippLog.info("focuslock: AUTO-decide editableFocused=true frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public) → paste-at-cursor")
                honorExistingManualLock = false
                useStartFieldRestore = false
            } else {
                // Nothing editable focused → we will restore to the START field. ARM the
                // lock NOW (flips isLockActive → the amber FocusLockIndicator shows in the
                // still-visible recorder so Ethan SEES the original field was chosen). The
                // actual focus MOVE happens right before the keystroke below; the lock is
                // cleared after delivery in the Task at the end.
                let armed = FocusLockService.shared.armAutoLockToCandidate()
                vippLog.info("focuslock: AUTO-decide editableFocused=false frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public) → restore-to-start-field armed=\(armed, privacy: .public)")
                honorExistingManualLock = false
                useStartFieldRestore = armed
            }
        }

        SoundManager.shared.playStopSound()

        // If the AUTO path armed a restore-to-start-field lock, hold the recorder on
        // screen a brief beat so the amber FocusLockIndicator we just flipped on is
        // actually VISIBLE to Ethan before dismiss orders the panel out. ~280ms is enough
        // to read the "Using input from voice start" caption without feeling sluggish; we
        // only pay it on the (less common) restore branch, never on a normal paste-at-cursor.
        if useStartFieldRestore {
            try? await Task.sleep(nanoseconds: 280_000_000)
        }
        await actions.dismiss()

        // Feature A — NEW START→STOP model defensive grace-wait (2026-06-21).
        // In the new model the lock decision is made on the STOP press: a stop-hold
        // timer (threshold 450ms) promotes the persisted start-candidate to a lock if
        // the combo is still held. That timer normally fires BEFORE transcription
        // completes (~1–2s), so by the time we reach this paste the lock flag is
        // already settled. BUT if transcription is unusually fast, delivery could
        // arrive while the stop-hold decision is still PENDING — in which case we'd
        // read a not-yet-set lock flag and paste at the cursor instead of the original
        // field. To guard that race, if a stop-hold decision is still pending we wait a
        // tiny, bounded grace window (poll every 20ms, cap at ~longPressThreshold+a
        // little) for it to resolve. Cheap, only runs on the rare fast-transcription
        // path, and never blocks longer than the hold threshold could take to fire.
        if FocusLockService.shared.stopHoldDecisionPending {
            vippLog.info("paste: stop-hold decision still PENDING at delivery → grace-waiting for resolution")
            // Cap a little above the threshold so a borderline hold's timer can fire.
            let graceDeadlineNanos = UInt64((FocusLockService.longPressThreshold + 0.15) * 1_000_000_000)
            let pollStepNanos: UInt64 = 20_000_000 // 20ms
            var waitedNanos: UInt64 = 0
            while FocusLockService.shared.stopHoldDecisionPending && waitedNanos < graceDeadlineNanos {
                try? await Task.sleep(nanoseconds: pollStepNanos)
                waitedNanos += pollStepNanos
            }
            if FocusLockService.shared.stopHoldDecisionPending {
                // Still unresolved after the grace window (e.g. user is genuinely
                // holding past it). Proceed anyway and LOG — we'll paste with whatever
                // lock state exists now; the held combo will resolve to a lock shortly.
                vippLog.info("paste: stop-hold decision STILL pending after grace window → proceeding with current lock state (lockActive=\(FocusLockService.shared.isLockActive, privacy: .public))")
            } else {
                vippLog.info("paste: stop-hold decision resolved during grace-wait (lockActive=\(FocusLockService.shared.isLockActive, privacy: .public))")
            }
        }

        // Feature A — perform the actual focus MOVE now, immediately before the paste
        // keystroke (decided + armed above, pre-dismiss). Doing the move here (not above)
        // means nothing can steal focus between the restore and the Cmd+V.
        //   • honorExistingManualLock → the old gesture lock is live: use the established
        //     same-pid-aware restoreFocusToLock() (no-op if the locked app is still
        //     frontmost — see that method's regression-guard comment).
        //   • useStartFieldRestore → the AUTO path armed a lock to the START candidate: do
        //     the focus-set via performAutoRestoreToCandidate(), which moves focus to the
        //     captured element UNCONDITIONALLY (even if its app is already frontmost — the
        //     deliberate same-pid divergence, because focus may be on a non-editable
        //     element in the same app that we must move off of).
        //   • neither → editable field already focused: touch nothing, paste at cursor.
        let didRestore: Bool
        if honorExistingManualLock {
            didRestore = FocusLockService.shared.restoreFocusToLock()
        } else if useStartFieldRestore {
            didRestore = FocusLockService.shared.performAutoRestoreToCandidate()
        } else {
            didRestore = false
        }
        vippLog.info("paste: focus decision done didRestore=\(didRestore, privacy: .public); issuing paste keystroke now (frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public))")

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)

        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none
        // Feature B: capture transcript length now so the auto-send can scale its
        // redundant-Enter delay with how much text was pasted (longer paste => the
        // field settles slower under load, so the second Enter gets more headroom).
        let pastedLength = pastedText.count
        Task { @MainActor in
            _ = await pasteTask.value

            if autoSendKey.isEnabled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Feature B: robust auto-send. For plain Enter this posts Return
                // TWICE (with a length-scaled gap) to survive a lag-dropped first
                // keystroke; Shift/Cmd+Enter still post once. See performAutoSend.
                CursorPaster.performAutoSend(autoSendKey, transcriptLength: pastedLength)
            }

            // Feature A: delivery is done — always release the focus lock so the
            // next recording starts clean (default frontmost behavior). Safe/idempotent
            // even when no lock was ever armed.
            FocusLockService.shared.clearLock()
        }
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel().usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
