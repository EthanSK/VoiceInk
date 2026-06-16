import Foundation
import AppKit
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

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApp.bundleIdentifier else {
            return Task {}
        }

        guard shouldApply() else { return Task {} }
        currentApplication = frontmostApp

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
