import Foundation
import SingReadyAISharedKit

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
extension DemoWorkflowStore {
    func useSimulatedVoice(navigate: Bool = true) {
        cancelVoiceRecording()
        voiceProfile = voiceAnalyzer.simulatedProfile()
        statusMessage = "已先按常见音域排歌"
        if navigate {
            setStage(.voice)
        }
    }

    func continueToScenarioWithoutMeasuring() {
        if voiceProfile == nil {
            useSimulatedVoice(navigate: false)
        }
        setStage(.scenario)
    }

    func startVoiceRecording() {
        guard voiceRecordingTask == nil,
              let request = voiceMeasurementGate.beginIfIdle() else {
            return
        }
        recordingState = .requestingPermission
        errorMessage = nil
        microphonePermissionDenied = false
        voiceRecordingTask = Task { [weak self] in
            await self?.performVoiceRecording(request: request)
        }
    }

    private func performVoiceRecording(request: UInt64) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-singreadySimulatedRecording") {
            await runSimulatedVoiceRecording(request: request)
            return
        }
        #endif

        #if os(iOS) && canImport(AVFoundation)
        let granted = await requestMicrophonePermission()
        guard acceptsVoiceMeasurement(request) else { return }
        guard granted else {
            microphonePermissionDenied = true
            recordingState = .failed("没开麦克风权限。可以去设置里打开，也可以先不测。")
            finishVoiceMeasurement(request)
            return
        }

        let countdownTask = Task { @MainActor [weak self] in
            for second in stride(from: 10, through: 1, by: -1) {
                guard let self, self.voiceMeasurementGate.accepts(request) else { return }
                self.recordingRemainingSeconds = second
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }

        do {
            guard acceptsVoiceMeasurement(request) else { return }
            recordingState = .recording
            recordingRemainingSeconds = 10
            recordingLevel = 0.08
            let profile = try await voiceRecordingService.recordPitchProfile(
                duration: 10,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.voiceMeasurementGate.accepts(request) else { return }
                        self.recordingLevel = level
                    }
                },
                onAnalysisStarted: { [weak self] in
                    countdownTask.cancel()
                    guard let self, self.acceptsVoiceMeasurement(request) else { return }
                    self.recordingState = .analyzing
                }
            )
            countdownTask.cancel()
            guard acceptsVoiceMeasurement(request) else { return }
            var measuredProfile = profile
            measuredProfile.source = .measured
            guard measuredProfile.hasValidMeasuredRange else {
                recordingState = .failed(measuredProfile.note)
                finishVoiceMeasurement(request)
                return
            }
            await completeMeasuredVoiceProfile(measuredProfile, request: request)
        } catch is CancellationError {
            countdownTask.cancel()
            if voiceMeasurementGate.accepts(request) {
                cancelVoiceRecording()
            }
        } catch {
            countdownTask.cancel()
            guard voiceMeasurementGate.accepts(request) else { return }
            recordingState = .failed("这次没录好：\(error.localizedDescription)。也可以先不测，直接排。")
            finishVoiceMeasurement(request)
        }
        #else
        await runSimulatedVoiceRecording(request: request)
        #endif
    }

    func cancelVoiceRecording() {
        voiceMeasurementGate.cancel()
        voiceRecordingTask?.cancel()
        voiceRecordingTask = nil
        #if os(iOS) && canImport(AVFoundation)
        voiceRecordingService.stop()
        #endif
        recordingState = .idle
        recordingRemainingSeconds = 10
        recordingLevel = 0.08
    }

    private func runSimulatedVoiceRecording(request: UInt64) async {
        for second in stride(from: 10, through: 1, by: -1) {
            guard acceptsVoiceMeasurement(request) else { return }
            recordingState = .recording
            recordingRemainingSeconds = second
            recordingLevel = Double(11 - second) / 10
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }
        await completeSimulatedMeasurement(request: request)
    }

    private func completeSimulatedMeasurement(request: UInt64) async {
        guard acceptsVoiceMeasurement(request) else { return }
        recordingState = .analyzing
        let measuredProfile = VoiceProfile(
            type: .unknown,
            minMidi: 48,
            maxMidi: 72,
            stableLowMidi: 52,
            stableHighMidi: 69,
            averageMidi: 60.5,
            confidence: 0.72,
            note: "这是本次唱到的音区，仅作排歌参考，不代表完整音域。",
            source: .measured,
            suitableSongTypes: ["旋律线平稳", "合唱歌曲"],
            avoidSongTypes: ["音域跨度很大", "连续高强度"],
            singingStrategy: ["先用中音区热身", "根据现场感受调整或换歌"]
        )
        await completeMeasuredVoiceProfile(measuredProfile, request: request)
    }

    private func completeMeasuredVoiceProfile(
        _ measuredProfile: VoiceProfile,
        request: UInt64
    ) async {
        guard measuredProfile.hasValidMeasuredRange,
              acceptsVoiceMeasurement(request) else { return }
        let previousMeasuredProfile = voiceProfile?.hasValidMeasuredRange == true
            ? voiceProfile
            : nil
        let persistenceRequest = voiceProfilePersistenceGate.begin()
        do {
            _ = try await voiceProfileStore.saveIfEligible(measuredProfile)
        } catch {
            errorMessage = "本次音区可以继续使用，但暂时没保存到本机。"
        }
        guard acceptsVoiceMeasurement(request) else {
            guard voiceProfilePersistenceGate.accepts(persistenceRequest) else { return }
            await restorePreviousMeasuredVoiceProfile(previousMeasuredProfile)
            return
        }
        guard voiceProfilePersistenceGate.accepts(persistenceRequest) else { return }
        voiceProfile = measuredProfile
        recordingState = .idle
        statusMessage = "音域看好了"
        finishVoiceMeasurement(request)
        setStage(.voice)
    }

    private func restorePreviousMeasuredVoiceProfile(_ profile: VoiceProfile?) async {
        if let profile {
            _ = try? await voiceProfileStore.saveIfEligible(profile)
        } else {
            try? await voiceProfileStore.clear()
        }
    }

    private func acceptsVoiceMeasurement(_ request: UInt64) -> Bool {
        !Task.isCancelled
            && currentStage == .voice
            && voiceMeasurementGate.accepts(request)
    }

    private func finishVoiceMeasurement(_ request: UInt64) {
        guard voiceMeasurementGate.finish(request) else { return }
        voiceRecordingTask = nil
    }

    #if os(iOS) && canImport(AVFoundation)
    private func requestMicrophonePermission() async -> Bool {
        await voiceRecordingService.requestPermission()
    }
    #endif
}
