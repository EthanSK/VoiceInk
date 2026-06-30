import Foundation
import AVFoundation
import CoreAudio
import os
import AppKit

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: CoreAudioRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    // Re-prepares the AUHAL after a system wake. See setupWakeObserver for the why.
    private var wakeObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
        setupDeviceSwitchObserver()
        setupAudioDeviceChangedObserver()
        setupWakeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    /// Re-prepare the capture hardware after the Mac wakes from sleep.
    ///
    /// ── WHY (clipped-start-of-speech half of the idle-miss bug) ───────────────────
    /// The AUHAL is prepared once at init (and on device changes) but NOT after a wake.
    /// After a long idle period / system sleep the input device can go cold or its AUHAL
    /// state can be torn down, so the FIRST recording cold-starts the unit and the first
    /// few hundred ms of speech are lost (there is no pre-roll ring buffer). Ethan's
    /// report: "there's no buffer — it just misses the start." Re-preparing on wake keeps
    /// the unit warm so the first post-wake press captures from the very first word.
    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Don't disturb an in-progress recording; prepare() also early-returns if
                // recording, but skipping here avoids needless setup churn on the audio queue.
                guard !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "wake")
            }
        }
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "device-changed")
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let recorder = recorder else { return }
        guard let userInfo = notification.userInfo,
              let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Switched to: %@"), deviceName),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        deviceManager.isRecordingActive = true

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Using: %@"), deviceName),
                    type: .info
                )
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()
        muteSystemAudio()

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            // Offload hardware start to avoid shortcut lag.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            startAudioMeterTimer()
            pauseMedia()
            // Complementary to pauseMedia(): broadcast "recording started" so the external YouTube
            // helper app can pause a playing YouTube tab in Chrome (which MediaRemote can't reach).
            // Posted in the success branch only, so a failed start (which falls into catch →
            // stopRecording) won't emit a started without a matching real recording.
            RecordingActivityNotifier.postRecordingStarted()
        } catch {
            logger.error("Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil

        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder
        onAudioChunk = nil

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }

        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }

        // Complementary to resumeMedia(): broadcast "recording stopped" so the external YouTube
        // helper app can resume the tab it paused. Posted synchronously here (not inside the
        // delayed audioRestorationTask) so the resume isn't subject to the audio-resumption delay.
        // The helper only resumes a tab it actually paused, so a spurious stop (e.g. reset on
        // launch) or a cancel is a safe no-op on the YouTube side. Cancel == stop at this layer.
        RecordingActivityNotifier.postRecordingStopped()

        deviceManager.isRecordingActive = false
    }

    private func muteSystemAudio() {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    private func pauseMedia() {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia()
        }
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Recording Failed: %@"), error.localizedDescription),
                type: .error
            )
        }
    }

    private func startAudioMeterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(17)) 
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter()
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID)
            } catch {
                logger.warning("Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        // Dispatch to main queue for UI updates (more efficient than Task)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioMeter = newAudioMeter
        }
    }
    
    // MARK: - Cleanup

    deinit {
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioMeterUpdateTimer?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
