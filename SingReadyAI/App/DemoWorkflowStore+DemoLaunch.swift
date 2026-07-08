import Foundation
import SingReadyAISharedKit

extension DemoWorkflowStore {
    func prepareDemoState(for launchStage: DemoLaunchStage) async {
        errorMessage = nil
        isWorking = false

        if launchStage == .importHub {
            resetImport()
            return
        }

        do {
            let playlist = try ImportCoordinator().resolveDemoPlaylist()
            prepareForReview(playlist: playlist)
        } catch {
            errorMessage = error.localizedDescription
            currentStage = .importHub
            return
        }

        if launchStage == .review {
            return
        }

        beginMatchingReviewedSongs()
        if launchStage == .matchReport {
            return
        }

        if launchStage == .voiceSetup {
            voiceProfile = nil
            recordingState = .idle
            currentStage = .voice
            return
        }

        useSimulatedVoice()
        if launchStage == .voiceResult {
            currentStage = .voice
            return
        }

        scenarioConfig = ScenarioConfig(scenario: .friends, peopleCount: 5, durationMinutes: 90, vibe: .chorus, chorusPreference: .moreChorus)
        if launchStage == .scenario {
            currentStage = .scenario
            return
        }

        generatePlan()
        switch launchStage {
        case .result:
            currentStage = .result
        case .export:
            currentStage = .export
        case .interview:
            currentStage = .interview
        default:
            break
        }
    }
}

enum DemoLaunchStage: String {
    case importHub
    case review
    case matchReport
    case voiceSetup
    case voiceResult
    case scenario
    case result
    case export
    case interview

    static func fromProcessArguments() -> DemoLaunchStage? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-singreadyStage"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return DemoLaunchStage(rawValue: arguments[index + 1])
    }
}
