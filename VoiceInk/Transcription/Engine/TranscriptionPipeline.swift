import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Used to log the exact
    // transcription request/result + every cancel-discard decision on this path.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var didInsertSessionMetric = false
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            vippLog.info("pipeline: PRE-transcribe shouldCancel==true → finishCanceled (no network, no paste)")
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            vippLog.info("pipeline: transcribe START model=\(model.displayName, privacy: .public) session=\(session != nil ? "streaming" : "file", privacy: .public)")
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            vippLog.info("pipeline: transcribe SUCCESS chars=\(text.count, privacy: .public) elapsed=\(transcriptionDuration, format: .fixed(precision: 3), privacy: .public)s")

            // ───────────────────────────────────────────────────────────────────────
            // FIX (2026-06-20, defensive guard for the same fork regression as the
            // RecorderUIManager re-entrancy fix): a cancel that raced in AFTER the
            // network round-trip already returned real text must NOT silently eat the
            // user's words. Previously ANY shouldCancel()==true here discarded a perfectly
            // good 200 transcription. Now we only treat a late cancel as "discard" when
            // the returned text is actually EMPTY; non-empty text is delivered. The
            // PRE-transcribe gate above still skips work before any network cost.
            // ───────────────────────────────────────────────────────────────────────
            if shouldCancel() {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vippLog.info("pipeline: POST-transcribe shouldCancel==true AND empty text → finishCanceled (no paste)")
                    await finishCanceledTranscription(); return
                } else {
                    vippLog.info("pipeline: POST-transcribe shouldCancel==true BUT text non-empty (chars=\(text.count, privacy: .public)) → DELIVER anyway (don't discard a finished 200)")
                }
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !assistant.isFollowUp,
               let processedText = triggerWordModeSelection(text) {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ??
                    resolvedEnhancementConfiguration?.mode ??
                    resolvedOutputConfiguration.mode ??
                    transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp {
                let shouldRespondInRecorder = resolvedOutputConfiguration.outputMode == .respond &&
                    resolvedEnhancementConfiguration?.isEnabled == true &&
                    resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement = !shouldRespondInRecorder &&
                    isSkipShortEnhancementEnabled &&
                    WordCounter.count(in: text) <= shortEnhancementWordThreshold

                if let enhancementService,
                   let resolvedEnhancementConfiguration,
                   resolvedEnhancementConfiguration.isEnabled,
                   enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                   !shouldSkipEnhancement {
                    if shouldCancel() { await finishCanceledTranscription(); return }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let contextSnapshot = await recordingContextSnapshot()
                        let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                            textForAI,
                            configuration: resolvedEnhancementConfiguration,
                            contextSnapshot: contextSnapshot
                        )
                        transcription.enhancedText = enhancedText
                        transcription.aiEnhancementModelName = resolvedEnhancementConfiguration.modelName ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = promptName
                        transcription.enhancementDuration = enhancementDuration
                        transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                        transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                        finalText = enhancedText
                    } catch {
                        let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        transcription.enhancedText = String(format: String(localized: "Enhancement failed: %@"), errorDescription)
                        responseError = errorDescription
                        let shortReason = String(errorDescription.prefix(80))
                        await MainActor.run {
                            NotificationManager.shared.showNotification(
                                title: String(format: String(localized: "Enhancement failed: %@"), shortReason),
                                type: .warning
                            )
                        }
                        if shouldCancel() { await finishCanceledTranscription(); return }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // VIPPDebug: transcription threw. A URLError(.cancelled) here means the
            // upload Task was torn down (the BrokenPipe-500 case at the proxy); any other
            // error is a genuine network/decode failure. Either way the bar will hide
            // with no paste — this line attributes which.
            let isCancelled = (error as? URLError)?.code == .cancelled
            vippLog.error("pipeline: transcribe FAILED isCancelled=\(isCancelled, privacy: .public) error=\(errorDescription, privacy: .public)")

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
               nativeAppleError.shouldShowNotification {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        // FINAL pre-delivery cancel gate. Same defensive logic as the post-transcribe
        // gate: only discard if there is NO usable text to deliver. If we have a real
        // finalText, deliver it even if a late cancel raced in — discarding a completed
        // 200 here is the exact "nothing pasted" symptom.
        if shouldCancel() {
            let hasText = !(finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if !hasText {
                vippLog.info("pipeline: PRE-delivery shouldCancel==true AND no text → finishCanceled (no paste)")
                await finishCanceledTranscription()
                return
            } else {
                vippLog.info("pipeline: PRE-delivery shouldCancel==true BUT finalText present → DELIVER anyway")
            }
        }

        vippLog.info("pipeline: about to DELIVER finalChars=\(finalText?.count ?? -1, privacy: .public) outputMode=\(String(describing: outputForDelivery?.outputMode), privacy: .public)")
        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        saveTranscriptionAndPostCompletion()
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
