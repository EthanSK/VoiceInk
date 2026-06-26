import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    // Observe the focus-lock service so the pill re-renders (and pillHeight
    // recomputes to make room for the indicator row) when a long-press lock
    // arms/clears at record-start/end.
    @ObservedObject private var focusLock = FocusLockService.shared
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    // Cancel ("X"): discard the active recording/transcription with NO paste + resume
    // paused media. Routed up to RecorderUIManager.cancelRecording().
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
    }

    private var displayState: DisplayState {
        if assistantSession.isVisible {
            return .assistant
        }

        switch stateProvider.recordingState {
        case .recording:
            let shouldShowLive = !stateProvider.partialTranscript.isEmpty
            return shouldShowLive ? .liveText : .active
        case .transcribing, .enhancing:
            return .active
        default:
            return .collapsed
        }
    }

    // MARK: - Screen Geometry

    private var notchWidth: CGFloat {
        guard let screen = NSScreen.main else { return 180 }
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            return screen.frame.width - left - right
        }
        return 180
    }

    private var notchHeight: CGFloat {
        guard let screen = NSScreen.main else { return 37 }
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
    }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 90
    private let transcriptSideExpansion: CGFloat = 110
    private let assistantSideExpansion: CGFloat = 230
    private let activeHeightBonus: CGFloat = 6
    private let transcriptPanelHeight: CGFloat = 57
    private let assistantPanelHeight: CGFloat = 320
    // Extra vertical space the pill grows by when the focus-lock indicator is
    // showing above the main row. Only added while the lock is active AND the
    // pill is expanded (not collapsed) — see focusLockIndicatorHeight.
    private let focusLockIndicatorRowHeight: CGFloat = 14

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active:    return notchWidth + recordingSideExpansion * 2
        case .liveText:  return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        }
    }

    // Height contributed by the focus-lock indicator row. Zero unless the lock is
    // active AND the pill is expanded — we never want it to push the collapsed
    // (hidden) notch open on its own.
    private var focusLockIndicatorHeight: CGFloat {
        (focusLock.isLockActive && displayState != .collapsed) ? focusLockIndicatorRowHeight : 0
    }

    private var pillHeight: CGFloat {
        let base: CGFloat
        switch displayState {
        case .collapsed: base = 0
        case .active:    base = mainRowHeight
        case .liveText:  base = mainRowHeight + transcriptPanelHeight
        case .assistant: base = mainRowHeight + assistantPanelHeight
        }
        // Add the indicator row's height so the pill grows to fit the caption
        // without clipping the waveform/main row below it.
        return base + focusLockIndicatorHeight
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        displayState == .liveText || displayState == .assistant ? 20 : 16
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant &&
            stateProvider.recordingState == .idle &&
            !assistantSession.isBusy
    }

    // Cancel ("X") visibility — mirrors the mini panel: reachable while RECORDING
    // (discard audio) and while a transcription is IN-FLIGHT (.transcribing/.enhancing,
    // abort before paste) plus the brief .starting handshake. Hidden at .idle/.busy.
    private var shouldShowCancelButton: Bool {
        switch stateProvider.recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }

    private var liveAssistantFollowUpText: String {
        guard stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            // Capture-mode indicator sits ABOVE the main row (which holds the
            // waveform / AudioVisualizer on its right side). Only takes vertical
            // space + renders when the long-press focus lock is active; for a
            // normal short-press recording it's an empty zero-height view so the
            // notch pill looks unchanged. See focusLockIndicatorRow.
            focusLockIndicatorRow
            mainRow
            liveTextPanel
            assistantPanel
        }
        .frame(width: pillWidth, height: pillHeight)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topCornerRadius: displayState == .liveText ? 12 : 8,
                bottomCornerRadius: displayState == .liveText || displayState == .assistant ? 22 : 16
            )
        )
    }

    // MARK: - Focus Lock Indicator Row

    // Thin centered row above the main row that shows the FocusLockIndicator
    // caption ("Using input from voice start") when the long-press lock is active.
    // Collapses to zero height when inactive (or while the notch is collapsed) so
    // a normal short-press recording leaves the pill unchanged. Clipped so the
    // caption never spills outside the rounded notch shape during the animation.
    private var focusLockIndicatorRow: some View {
        FocusLockIndicator()
            .frame(maxWidth: .infinity)
            .frame(height: focusLockIndicatorHeight)
            .clipped()
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 14) {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }

                // Cancel ("X") immediately to the right of the Stop/record control so an
                // abort is one tap from Stop. Only while a recording/transcription is
                // cancellable (see shouldShowCancelButton); collapses out at idle/busy so
                // the notch pill's normal layout is unchanged.
                if shouldShowCancelButton {
                    RecorderCancelButton(action: onCancelTapped)
                        .transition(.opacity)
                }

                RecorderModeButton(buttonSize: 20, padding: EdgeInsets())
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowCancelButton)
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeter: recorder.audioMeter,
                    menuBarHeight: notchHeight
                )
            }
            .padding(.trailing, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText {
                Divider().background(Color.white.opacity(0.15))
                LiveTranscriptView(text: stateProvider.partialTranscript)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().background(Color.white.opacity(0.15))
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}
