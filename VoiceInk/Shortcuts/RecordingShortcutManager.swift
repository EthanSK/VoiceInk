import Foundation
import AppKit
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing &&
        recordingState != .enhancing &&
        recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            // Feature A (2026-06-21): lets the handler look up the ACTIVE Shortcut for a
            // given action so it can tell whether the shortcut is MODIFIER-ONLY (⇧⌃⌥) and
            // read its required modifier mask. The handler needs this to robustly decide a
            // STOP-hold focus-lock for modifier-only shortcuts, whose key-up fires at
            // ~0.1s and can't be timed (see RecordingShortcutModeHandler for the full why).
            shortcutForAction: { action in
                switch action {
                case .primaryRecording, .secondaryRecording:
                    return ShortcutStore.shortcut(for: action)
                default:
                    return nil
                }
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }
    
    private func refreshShortcutMonitoring() {
        removeAllMonitoring()
        
        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut = secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        shortcutModeHandler.reset()
    }
    
    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured = primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured = secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }
    
    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }
    
    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    // Feature A (2026-06-21): resolve the active Shortcut for an action so we can read
    // whether it's modifier-only + its required modifier mask. See the STOP-hold logic.
    private let shortcutForAction: @MainActor (ShortcutAction) -> Shortcut?

    // VIPPDebug: VoiceInk++-only diagnostic logger (NOT the base voiceink logger).
    // Surfaces the press lifecycle — key-down capture, long-press timer arm/fire,
    // key-up short-vs-long resolution — so we can correlate the shortcut handler's
    // view of the press against FocusLockService's lock lifecycle in one stream.
    // Subsystem matches FocusLockService.vippLog so a single predicate catches both.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?

    // Feature A (new START→STOP model): remembers whether the CURRENTLY-held press
    // was the one that STARTED the recording (true) or the one STOPPING it (false).
    // Computed once on key-down (from startsFreshRecording) and read on key-up so the
    // key-up handler knows which side it is:
    //   • START key-up  → leave the captured candidate ALONE (it must persist).
    //   • STOP  key-up  → resolve short-tap (clearCandidate) vs long-hold (keep; the
    //                     stop-hold timer already promoted it).
    private var currentPressStartedRecording = false

    // Feature A (modifier-only STOP-hold, 2026-06-21): captured at the STOP key-down so
    // the threshold timer + the key-up handler know how to resolve the gesture.
    //   • currentStopIsModifierOnly: is the active record shortcut modifier-only (⇧⌃⌥)?
    //     If so, the ~0.1s spurious key-up must NOT cancel the timer or decide the
    //     gesture — the timer decides by LIVE modifier state instead.
    //   • currentStopRequiredModifiers: the required modifier mask of that shortcut, read
    //     from its Shortcut definition (so we don't hardcode ⇧⌃⌥). Used at threshold to
    //     ask NSEvent.modifierFlags "are these still physically held?".
    private var currentStopIsModifierOnly = false
    private var currentStopRequiredModifiers: NSEvent.ModifierFlags = []

    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var lastShortcutPressTime: Date?

    // Feature A (focus lock) — NEW START→STOP DECISION MODEL (2026-06-21).
    //
    // WHY THIS CHANGED: Ethan's actual gesture is a modifier-only TOGGLE (⇧⌃⌥ in
    // toggle mode): he TAPS to start recording and TAPS again to stop. He does NOT
    // push-to-talk hold. Under the OLD model the long-press "lock the start field"
    // decision was made on the START press — but in toggle+tap usage the start press
    // is a quick tap, so the lock NEVER armed and his "paste into the field I started
    // in" workflow was impossible to trigger.
    //
    // NEW MODEL: the lock decision moves to the STOP press.
    //   • START press: ALWAYS captureCandidate() (snapshot the focused field) and
    //     KEEP that candidate alive for the whole recording. No lock armed yet, no
    //     timer on start. The candidate persists — it is NOT cleared on start key-up.
    //   • STOP press: decide long-hold vs short-tap.
    //       - long-hold (combo held ≥ longPressThreshold) → promoteToLock() so
    //         delivery restores focus to the captured candidate (paste into original).
    //       - short-tap → clearCandidate(), no lock, normal paste at cursor.
    //
    // TIMING SUBTLETY (toggle mode): the STOP fires on key-DOWN — recording stops and
    // transcription begins IMMEDIATELY on the stop key-down, before we know whether
    // it's a hold or a tap (the hold is only known later, at the stop key-up, or when
    // the threshold timer fires). So on the STOP key-down we ARM this timer; if the
    // combo is still held at longPressThreshold it fires and calls promoteToLock().
    // Transcription takes ~1–2s and the paste waits for it, so this timer normally
    // fires BEFORE delivery → the lock flag is set in time for restoreFocusToLock().
    // This same Task field is reused for that stop-side timer (only one is ever live).
    private var longPressLockTask: Task<Void, Never>?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        shortcutForAction: @escaping @MainActor (ShortcutAction) -> Shortcut?
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.shortcutForAction = shortcutForAction
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        currentPressStartedRecording = false
        currentStopIsModifierOnly = false
        currentStopRequiredModifiers = []

        // Feature A (focus lock): a full reset (monitor restart, accidental-start
        // cancel) must tear down any pending stop-hold timer AND any captured/locked
        // focus so a stale lock can't leak into the next recording.
        longPressLockTask?.cancel()
        longPressLockTask = nil
        FocusLockService.shared.setStopHoldDecisionPending(false)
        FocusLockService.shared.clearLock()
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if let lastTrigger = lastShortcutPressTime,
           Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = Date()
        shortcutPressStartTime = eventTime

        // Feature A (focus lock): does THIS key-down START a fresh recording?
        // Only a key-down that begins recording (recorder not currently visible,
        // and we're not toggling-off a hands-free session) is the START press.
        // The STOP press has startsFreshRecording == false (recorder is visible /
        // we're toggling off a hands-free session) and is handled further down.
        let startsFreshRecording = !isRecorderVisible() && !isHandsFreeRecording
        // Remember which side this press is, for the matching key-up resolution.
        currentPressStartedRecording = startsFreshRecording
        // Clear the STOP-side modifier-only flags up-front so a prior STOP's values can
        // never leak into a fresh START press; the STOP branch recomputes them below.
        currentStopIsModifierOnly = false
        currentStopRequiredModifiers = []
        if startsFreshRecording {
            // START PRESS (new model): ALWAYS snapshot the currently-focused field and
            // KEEP it alive for the whole recording. This is the only instant the
            // original field is reliably still focused — Ethan may click away
            // immediately after starting. We do NOT arm any lock or timer here; the
            // long-hold-vs-tap decision is deferred to the STOP press (see below).
            // We also do NOT clear this candidate on the start key-up — it must
            // persist through the entire recording so the STOP press can promote it.
            FocusLockService.shared.captureCandidate()

            // VIPPDebug: START press routed here and triggered captureCandidate(). The
            // detailed "RECORD START → captured candidate …" line (with pid+bundle) is
            // emitted inside FocusLockService.captureCandidate(); this line just marks
            // that the shortcut handler took the start path. No lock/timer armed here.
            vippLog.info("shortcut: START press → captureCandidate() (candidate will persist for session) action=\(String(describing: action), privacy: .public)")

            // Defensive: if a stale stop-timer somehow survived from a prior session,
            // tear it down so it can't fire against this new recording.
            longPressLockTask?.cancel()
            longPressLockTask = nil
        } else {
            // STOP PRESS (new model): this key-down ENDS the recording. In toggle mode
            // recording stops + transcription begins right now, on this key-down —
            // before we know whether Ethan is doing a quick TAP-to-stop or a deliberate
            // long-HOLD-to-stop. The hold is only known later (at this press's key-up,
            // or when the threshold timer below fires).
            //
            // So we ARM a threshold timer here on the STOP key-down: if the combo is
            // STILL held when longPressThreshold elapses, we promoteToLock() — pinning
            // delivery to the field captured back at the START press. Because
            // transcription takes ~1–2s and the paste waits for it, this timer normally
            // fires BEFORE delivery, so the lock flag is set in time for
            // restoreFocusToLock().
            //
            // ── THE MODIFIER-ONLY ~0.1s KEY-UP PROBLEM (2026-06-21 fix) ──────────────
            // Ethan's shortcut is MODIFIER-ONLY (⇧⌃⌥, toggle mode). For a bare modifier
            // combo there is no real key press — the monitor synthesises a "key-up"
            // almost IMMEDIATELY (~0.1s) regardless of how long he physically keeps the
            // keys down. Under the old code that spurious early key-up always took the
            // "short-tap" branch in handleKeyUp and CANCELLED this timer before it could
            // reach 0.45s — so the lock NEVER engaged. Every stop logged as
            // `STOP short-tap (dur≈0.10) → no lock`.
            //
            // FIX: capture whether the active shortcut is modifier-only + its required
            // modifier mask NOW (at STOP key-down). If it IS modifier-only, the key-up
            // handler will NOT cancel this timer or decide the gesture — instead the
            // timer is allowed to fire at the threshold and decides by LIVE PHYSICAL
            // MODIFIER STATE (NSEvent.modifierFlags): required modifiers still held ⇒
            // genuine long-hold ⇒ lock; released ⇒ real tap ⇒ no lock. For a normal
            // KEY shortcut the OS key-up IS reliable, so we keep the old timing path
            // (key-up cancels the timer for a sub-threshold tap) — the same timer just
            // additionally re-checks live modifier state when it fires, which is correct
            // either way.
            //
            // Mirrors the OLD start-side promote-timer pattern: [weak self] + the
            // isShortcutPressed / activeRecordingShortcutAction race guards so a key-up
            // that lands exactly as the timer fires can't promote a released press
            // (these guards apply to the KEY-shortcut path; for modifier-only we
            // deliberately don't rely on isShortcutPressed since the synthetic key-up
            // already cleared it — see below).
            longPressLockTask?.cancel()

            // Resolve the active shortcut so we know how to interpret the upcoming
            // key-up. shortcutForAction reads the live Shortcut definition from storage.
            let activeShortcut = shortcutForAction(action)
            currentStopIsModifierOnly = activeShortcut?.isModifierOnly ?? false
            // Required modifier mask for the live-state check (for Ethan: ⇧⌃⌥). Falls
            // back to empty if we can't resolve the shortcut — the live-state check then
            // safely refuses to lock (requiredModifiersStillHeld returns false on empty).
            currentStopRequiredModifiers = activeShortcut?.modifierFlags ?? []
            // Snapshot for the timer closure (avoid capturing self.* mutable state).
            let isModifierOnly = currentStopIsModifierOnly
            let requiredModifiers = currentStopRequiredModifiers

            // Mark the stop-hold decision as PENDING so delivery's paste() can do a
            // tiny grace-wait if transcription somehow finishes before this resolves.
            FocusLockService.shared.setStopHoldDecisionPending(true)
            // VIPPDebug: STOP press key-down — recording is stopping NOW; arm the
            // stop-hold timer. modifierOnly flags whether we'll decide by live modifier
            // state (true) or by key-up timing (false).
            vippLog.info("shortcut: STOP press key-down → arming stop-hold timer (threshold=\(FocusLockService.longPressThreshold) modifierOnly=\(isModifierOnly) action=\(String(describing: action), privacy: .public))")
            longPressLockTask = Task { @MainActor [weak self] in
                let thresholdNanos = UInt64(FocusLockService.longPressThreshold * 1_000_000_000)
                try? await Task.sleep(nanoseconds: thresholdNanos)
                guard let self, !Task.isCancelled else {
                    // Cancelled before firing. For a KEY shortcut this means a real
                    // sub-threshold tap (key-up cancelled us) — nothing to do. For a
                    // modifier-only shortcut the key-up does NOT cancel us, so reaching
                    // here-cancelled would only happen on reset/teardown; also fine.
                    return
                }

                if isModifierOnly {
                    // MODIFIER-ONLY PATH: the synthetic ~0.1s key-up already cleared
                    // isShortcutPressed, so we CANNOT use it as a "still held" proxy.
                    // Ask the hardware directly: are the required modifiers (⇧⌃⌥) still
                    // physically down right now?
                    let stillHeld = FocusLockService.shared.requiredModifiersStillHeld(required: requiredModifiers)
                    // os_log: required mask + live raw flags + verdict. modifierFlags
                    // rawValue (UInt) is fine to interpolate directly.
                    let liveFlags = NSEvent.modifierFlags.rawValue
                    self.vippLog.info("focuslock: STOP threshold reached → modifiers still held=\(stillHeld) (required=\(requiredModifiers.rawValue), current=\(liveFlags)) → \(stillHeld ? "promoteToLock" : "tap") action=\(String(describing: action), privacy: .public)")
                    if stillHeld {
                        // Genuine long-hold → engage the focus lock so delivery restores
                        // focus to the field captured at the START press.
                        FocusLockService.shared.promoteToLock()
                    } else {
                        // Real quick tap (modifiers released before threshold) → no lock;
                        // discard the persisted candidate so delivery uses normal paste.
                        FocusLockService.shared.clearCandidate()
                    }
                    // Decision resolved either way — clear the pending flag so delivery's
                    // grace-wait (if any) proceeds immediately.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                    return
                }

                // KEY-SHORTCUT PATH (reliable key-up): if we got here the key-up never
                // cancelled us, i.e. the key is genuinely still held past the threshold.
                // Re-check the combo is still down for THIS action to guard a key-up
                // landing exactly as the timer fires.
                guard self.isShortcutPressed,
                      self.activeRecordingShortcutAction == action else {
                    // Released right at the boundary — let the key-up path resolve it.
                    return
                }
                // VIPPDebug: stop-hold timer SURVIVED to fire — key held past threshold
                // at STOP, so promote the persisted start-candidate to a lock.
                self.vippLog.info("focuslock: STOP long-hold ≥threshold → promoteToLock (paste into original field) action=\(String(describing: action), privacy: .public)")
                FocusLockService.shared.promoteToLock()
                FocusLockService.shared.setStopHoldDecisionPending(false)
            }
        }

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false

        // Feature A (new START→STOP model): the press has ended — but which press?
        //
        //   • START key-up: the start tap finished. Do NOTHING to the focus state —
        //     the captured candidate MUST persist for the whole recording so the later
        //     STOP press can decide whether to lock to it. (This is the key behaviour
        //     change: the old model cleared a short start-press here.) No timer to
        //     cancel either — the start press never arms one in the new model.
        //
        //   • STOP key-up: the stop press finished. Cancel the stop-hold timer (so it
        //     can't fire after release) and resolve long-hold vs short-tap:
        //       - short-tap (released before threshold) → clearCandidate(), no lock,
        //         normal paste at the live cursor.
        //       - long-hold (held ≥ threshold) → KEEP the candidate; the stop-hold
        //         timer already ran promoteToLock(), so delivery restores focus to the
        //         original field. We do NOT clear here.
        if currentPressStartedRecording {
            // START key-up — leave focus state untouched; candidate persists.
            // (No VIPPDebug noise here; the RECORD START line already logged capture.)
        } else if currentStopIsModifierOnly {
            // ── MODIFIER-ONLY STOP key-up (2026-06-21 fix) ─────────────────────────
            // This key-up is the SPURIOUS ~0.1s synthetic release that the OS emits for
            // a bare modifier combo regardless of how long Ethan physically holds the
            // keys. We must therefore IGNORE it entirely for the lock decision: do NOT
            // cancel the stop-hold timer, do NOT take any short-tap/long-hold branch.
            // The timer (armed at STOP key-down) will fire at longPressThreshold and
            // decide by LIVE NSEvent.modifierFlags whether the required modifiers (⇧⌃⌥)
            // are still physically held — that is the only reliable signal for this
            // shortcut kind. Leaving the timer alive here is the whole fix.
            vippLog.info("shortcut: STOP key-up (modifier-only) dur=\(shortcutPressStartTime.map { eventTime - $0 } ?? 0) → IGNORED for lock decision (live-modifier timer will decide)")
        } else {
            // STOP key-up (KEY shortcut, reliable key-up) — cancel the stop-hold timer,
            // then resolve the gesture by press duration.
            longPressLockTask?.cancel()
            longPressLockTask = nil
            if let pressStart = shortcutPressStartTime {
                let pressDuration = eventTime - pressStart
                if pressDuration < FocusLockService.longPressThreshold {
                    // SHORT TAP to stop → no lock; discard the persisted candidate so
                    // delivery uses the default frontmost/live-cursor paste (#785).
                    // VIPPDebug: stop short-tap — under threshold, candidate discarded.
                    vippLog.info("shortcut: STOP short-tap (dur=\(pressDuration)) → no lock, paste at cursor; clearCandidate")
                    FocusLockService.shared.clearCandidate()
                    // Decision resolved (no lock): clear the pending flag.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                } else {
                    // LONG HOLD to stop → the stop-hold timer should already have
                    // promoted the candidate to a lock; keep it (do NOT clear). This
                    // branch is mostly a fallback in case key-up fires slightly after
                    // the threshold without the timer having run yet — promote here too
                    // so a borderline-timed hold still locks.
                    if !FocusLockService.shared.isLockActive {
                        // Timer hasn't fired yet but we crossed the threshold by key-up:
                        // promote now so the hold still locks. Idempotent if it already did.
                        FocusLockService.shared.promoteToLock()
                    }
                    // Decision resolved (locked): clear the pending flag.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                    vippLog.info("shortcut: STOP long-hold key-up (dur=\(pressDuration)) ≥ threshold → lock kept (paste into original field)")
                }
            }
        }

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
