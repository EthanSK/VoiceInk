import Foundation
import AppKit
import ApplicationServices // AXUIElement* APIs — used to resolve the *keyboard-focused* app (see chatgpt-floating-window fix below)
import os

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private let browserURLService = BrowserURLService.shared

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.detection"
    )

    // Observer token for the NSWorkspace app-activation notification.
    // We keep it so the observer can (in principle) be torn down; in practice
    // this singleton lives for the whole app lifetime, so it's never removed.
    // Stored to avoid registering the observer more than once.
    private var didActivateObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Follow-the-frontmost-app support (issue #785)
    //
    // The bug: VoiceInk resolved the active Mode ONLY at record-start, from the
    // frontmost app at that exact instant. Ethan's workflow is "start recording
    // first, THEN click into the target app", so the wrong app's Mode was applied
    // (right paste target, but wrong auto-send behavior).
    //
    // The fix: observe NSWorkspace app-activation events and re-resolve the active
    // Mode every time the frontmost app changes — including switches DURING a
    // recording. Output mode + auto-send are read LIVE at delivery from
    // ModeManager.currentEffectiveConfiguration, so updating the active config as
    // the user moves between apps makes delivery match the app they actually end in.
    //
    // VoiceInk's recorder windows are .nonactivatingPanel, so they do NOT become
    // frontmost — genuine app switches still fire didActivateApplicationNotification
    // even while a recording is in progress. That's what makes this approach work.
    //
    // Call this exactly once, early in app launch. It's idempotent (guards against
    // double-registration) so a stray second call is harmless.
    func start() {
        guard didActivateObserver == nil else { return }

        didActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Pull the newly-activated app out of the notification's userInfo.
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            // The notification queue is .main, but the handler isn't statically
            // isolated to the main actor — hop on explicitly so we can safely touch
            // @Published state and main-actor-only ModeManager APIs.
            Task { @MainActor [weak self] in
                self?.handleFrontmostAppActivation(app)
            }
        }
    }

    // Re-resolve and apply the active Mode for a newly-activated app.
    // Mirrors the resolution in beginApplyingConfiguration (app config -> default
    // -> neutral nil) so record-start and live-follow behave identically.
    @MainActor
    private func handleFrontmostAppActivation(_ app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return }

        // Feature A (focus lock): if a long-press focus lock is active, the user has
        // DELIBERATELY pinned delivery to the field they started in. Suppress the
        // #785 frontmost-follow for this session — otherwise clicking into another
        // app mid-recording would re-resolve the Mode/auto-send to that other app,
        // which is exactly the behavior the lock is meant to override. The locked
        // session keeps whatever Mode was resolved at record-start.
        if FocusLockService.shared.isLockActive { return }

        // Ignore activations of VoiceInk itself — when the user clicks back into our
        // own window (e.g. settings, or the recorder if it ever takes focus) we must
        // NOT clobber the Mode resolved for their real target app.
        if bundleIdentifier == Bundle.main.bundleIdentifier { return }

        currentApplication = app

        // Same resolution order used at record-start. resolveAndApplyConfiguration
        // also handles the neutral-nil fallback (issue #784) and the async
        // browser-URL override.
        resolveAndApplyConfiguration(for: bundleIdentifier, shouldApply: { true })
    }

    // Shared resolution used by BOTH the record-start path and the live-follow
    // observer: app-config -> default-config -> neutral(nil). Applies the result and,
    // for browsers, kicks off the async URL-based override (identical to the prior
    // inline logic). `shouldApply` lets the record-start caller bail if the recording
    // was cancelled between resolution steps; the observer always passes { true }.
    @MainActor
    @discardableResult
    private func resolveAndApplyConfiguration(
        for bundleIdentifier: String,
        shouldApply: @escaping @MainActor () -> Bool
    ) -> Task<Void, Never> {
        let quickConfig = ModeManager.shared.getConfigurationForApp(bundleIdentifier)
            ?? ModeManager.shared.getDefaultConfiguration()

        if let quickConfig {
            ModeManager.shared.setActiveConfiguration(quickConfig)
        } else {
            // Issue #784: no app-specific Mode AND no default Mode -> apply a neutral
            // config (nil) instead of leaving the previously-active Mode in place.
            // Delivery treats nil as plain paste / no auto-send (ModeRuntimeConfiguration),
            // so a stale Mode from a prior app can't leak its auto-send behavior here.
            ModeManager.shared.setActiveConfiguration(nil)
        }

        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return Task {}
        }

        // Browser: asynchronously fetch the current tab URL and, if a URL-specific
        // Mode matches, override the app-level Mode chosen above.
        return Task { [weak self] in
            guard let self else { return }

            do {
                let currentURL = try await self.browserURLService.getCurrentURL(from: browserType)
                await MainActor.run {
                    guard shouldApply(),
                          let config = ModeManager.shared.getConfigurationForURL(currentURL) else {
                        return
                    }
                    ModeManager.shared.setActiveConfiguration(config)
                }
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Keyboard-focused-app resolution (ChatGPT floating-window fix)
    //
    // THE BUG this guards against:
    // The ChatGPT macOS app's floating "companion / quick-access" window (summoned
    // with a global hotkey, floats over whatever app you're in) is a
    // NON-ACTIVATING panel (.nonactivatingPanel, like Spotlight/an accessory window).
    // macOS deliberately lets such a panel take KEYBOARD focus WITHOUT changing
    // `NSWorkspace.shared.frontmostApplication` and WITHOUT firing
    // `didActivateApplicationNotification`. So when Ethan dictates into that floating
    // window, our two existing app-resolution paths both miss it:
    //   • record-start read of `frontmostApplication` (beginApplyingConfiguration) →
    //     still points at whatever real app was front BEHIND the panel, not ChatGPT.
    //   • the live-follow observer (didActivateApplicationNotification) → never fires
    //     for a non-activating panel, so it can't correct it either.
    // Net effect: the per-app "ChatGPT mode" never activates → no auto-Enter, and the
    // menu-bar "Mode:" indicator (MenuBarView reads currentEffectiveConfiguration)
    // stays on the wrong mode. It only worked when ChatGPT's MAIN window was front
    // (a normal window that DOES become frontmost).
    //
    // THE FIX:
    // Ask the Accessibility API which app actually owns KEYBOARD focus. Unlike
    // `frontmostApplication`, the system-wide AX focused element DOES follow into a
    // non-activating panel, so it correctly reports ChatGPT (com.openai.chat) while
    // that floating window is focused. We use this as the PRIMARY signal at
    // record-start and fall back to `frontmostApplication` whenever AX can't help.
    //
    // WHY THIS IS SAFE / ADDITIVE for ordinary apps:
    // For a normal window, the AX-focused app IS the frontmost app, so behavior is
    // unchanged. We only diverge from the old logic in exactly the broken case
    // (focus sitting in a non-activating panel). Reuses the same AX pattern already
    // proven in FocusLockService.captureCandidate (system-wide element → pid → app).
    //
    // FALLBACK CASES (return nil → caller uses frontmostApplication):
    //   • Accessibility not granted (AXIsProcessTrusted() == false).
    //   • No system-wide focused element, or no resolvable owning app.
    //   • The focused app is VoiceInk ITSELF — our own recorder windows are ALSO
    //     non-activating panels, so we must never attribute focus to ourselves and
    //     clobber the user's real target app's mode.
    // Cheap + only called once per record-start (not polled), so no AX hammering.
    private func accessibilityFocusedApplication() -> NSRunningApplication? {
        // No Accessibility permission → can't read system-wide focus. Bail to the
        // frontmost path. (VoiceInk already requests AX since it injects keystrokes.)
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        // Some focus contexts don't expose a focused AX element — fall back.
        guard result == .success, let focusedRef else { return nil }

        // Successful read of kAXFocusedUIElementAttribute always yields an AXUIElement.
        let element = focusedRef as! AXUIElement

        // Map the focused element → owning process → NSRunningApplication so we can
        // read its bundle id for per-app mode lookup.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleIdentifier = app.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              !app.isTerminated else {
            return nil
        }

        // Never attribute focus to VoiceInk itself (our recorder panels are also
        // non-activating). Guard by both PID and bundle id, then fall back so the
        // caller resolves the real target app via frontmostApplication instead.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier,
           bundleIdentifier == ownBundleIdentifier {
            return nil
        }

        return app
    }

    @MainActor
    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        if let modeId = modeId,
           let config = ModeManager.shared.getConfiguration(with: modeId) {
            guard shouldApply() else { return Task {} }
            ModeManager.shared.setActiveConfiguration(config)
            return Task {}
        }

        // Prefer the KEYBOARD-focused app (Accessibility) over the frontmost app, so
        // dictating into a non-activating panel like ChatGPT's floating companion
        // window correctly resolves to ChatGPT (com.openai.chat) and activates its
        // per-app mode (incl. auto-Enter). Falls back to frontmostApplication when AX
        // can't help (untrusted / no focused element / focus is VoiceInk itself).
        // For ordinary windows these two are the same app, so this is non-breaking.
        let activeApp = accessibilityFocusedApplication()
            ?? NSWorkspace.shared.frontmostApplication

        guard let activeApp,
              let bundleIdentifier = activeApp.bundleIdentifier else {
            return Task {}
        }

        guard shouldApply() else { return Task {} }
        currentApplication = activeApp

        // Delegate to the shared resolver (app-config -> default -> neutral nil, plus
        // the async browser-URL override). This is the SAME logic the live-follow
        // observer uses, so record-start and app-switch stay in sync. The neutral-nil
        // fallback (issue #784) now also applies here.
        return resolveAndApplyConfiguration(for: bundleIdentifier, shouldApply: shouldApply)
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        let task = await MainActor.run {
            beginApplyingConfiguration(modeId: modeId)
        }
        await task.value
    }
} 
