import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderUIManager")

    // VIPPDebug: dedicated unified-log channel for the records→transcribe→paste→hide
    // path so the fork's "transcribing briefly then bar hides, nothing pasted" bug is
    // observable. Filter with:
    //   log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init() {}

    /// Call after VoiceInkEngine is created to break the circular init dependency.
    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    // MARK: - Recorder Panel Management

    private func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

        switch recorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            notchWindowManager?.show()
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            miniWindowManager?.show()
        }
    }

    private func hideRecorderPanel() {
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        }
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        vippLog.info("toggleRecorderPanel: enter panelVisible=\(self.isRecorderPanelVisible, privacy: .public) state=\(String(describing: engine.recordingState), privacy: .public) modeId=\(modeId?.uuidString ?? "nil", privacy: .public)")

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting:
                // Pre-recording: a re-press here genuinely cancels a not-yet-started
                // session, so cancelling is correct.
                vippLog.info("toggleRecorderPanel: .starting → cancelRecording")
                await cancelRecording()
            case .transcribing, .enhancing:
                // ───────────────────────────────────────────────────────────────
                // FIX (2026-06-20, fork regression): "records → 'transcribing' for
                // a blink → bar hides instantly → NOTHING pasted (proxy logs mixed
                // 200s + 500 BrokenPipe)".
                //
                // ROOT CAUSE: the stop happens via toggleRecorderPanel (HYBRID key-up)
                // which then AWAITS the whole batch pipeline INLINE (VoiceInkEngine
                // .toggleRecord → runPipeline → urlSession.upload). That await frees the
                // MainActor, so a stray record-shortcut event — key-repeat, a quick
                // re-press to start the NEXT dictation, the hybrid key-up re-dispatch,
                // or a modifier-combo interruption — re-enters toggleRecorderPanel while
                // state == .transcribing and USED to fall straight into cancelRecording().
                // That poisons the active pipeline id (requestRecordingCancellation),
                // so the pipeline's post-transcribe shouldCancel() gate THROWS AWAY the
                // already-returned 200 text and dismisses the bar; the in-flight upload
                // (a child of the cancelled Task) is torn down → proxy sees BrokenPipe.
                //
                // FIX: a plain toggle press must NOT abort an in-flight transcription.
                // Transcription is already committed — let it finish and paste. Explicit
                // cancellation still works via the Esc / close-button path
                // (handleDismissRecorderPanelNotification + onCloseTapped → cancelRecording),
                // which is the ONLY intended canceller once transcription has begun.
                // ───────────────────────────────────────────────────────────────
                vippLog.info("toggleRecorderPanel: IGNORING re-entrant toggle during \(String(describing: engine.recordingState), privacy: .public) (guard — do NOT cancel in-flight transcription)")
                return
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            SoundManager.shared.playStartSound()
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        // VIPPDebug: this is the recorder-bar HIDE site. Logging state here tells us
        // WHY the bar vanished — if state is .transcribing/.enhancing at hide time,
        // a transcription was killed mid-flight (the bug); if .idle, it's a normal
        // post-delivery dismiss.
        vippLog.info("dismissRecorderPanel: HIDE bar (state=\(String(describing: engine.recordingState), privacy: .public))")

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        // VIPPDebug: explicit cancel site. After Fix above, this should ONLY fire for a
        // genuine user cancel (Esc / close button) or pre-transcription states — NOT
        // from a stray toggle during .transcribing. If you see this while state is
        // .transcribing/.enhancing on a NORMAL dictation, an unintended caller leaked in.
        vippLog.info("cancelRecording: CANCEL requested (state=\(String(describing: engine.recordingState), privacy: .public))")
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            // VIPPDebug: explicit dismiss (Esc / DismissMiniRecorderIntent). This IS the
            // intended cancel path for an in-flight transcription, so cancelling here is
            // correct (unlike the re-entrant toggle path, which we now ignore).
            vippLog.info("handleDismissRecorderPanelNotification: explicit dismiss (state=\(String(describing: self.engine?.recordingState), privacy: .public))")
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
