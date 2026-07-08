import SwiftUI
import SingReadyAISharedKit

struct RootTabView: View {
    @AppStorage("singready.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                ProductFlowShell()
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-singreadyResetOnboarding") {
                hasCompletedOnboarding = false
            }
            guard let launchStage = DemoLaunchStage.fromProcessArguments() else { return }
            hasCompletedOnboarding = true
            await store.prepareDemoState(for: launchStage)
        }
    }
}

struct ProductFlowShell: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        ZStack {
            PremiumBackground()
            VStack(spacing: 0) {
                topBar

                StepProgressRail(stages: WorkflowStage.allCases, current: store.currentStage) { stage in
                    store.currentStage = stage
                }
                .padding(.horizontal, DesignSystem.pageHorizontalPadding)

                Rectangle()
                    .fill(DesignSystem.separator)
                    .frame(height: 1)

                currentPage
                    .id(store.currentStage.id)
            }
        }
        .tint(DesignSystem.primary)
    }

    private var topBar: some View {
        HStack(spacing: SpacingTokens.sm) {
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text("今晚唱什么")
                    .font(TypographyTokens.title)
                    .foregroundStyle(DesignSystem.ink)
                Text(store.currentStage.title)
                    .font(TypographyTokens.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.cyan)
            }
            Spacer()
            Button {
                Haptics.selection()
                store.currentStage = .interview
            } label: {
                Image(systemName: "briefcase")
                    .font(.title3.weight(.semibold))
                    .frame(width: ComponentTokens.iconButtonSize, height: ComponentTokens.iconButtonSize)
                    .background(DesignSystem.raisedBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous)
                            .stroke(DesignSystem.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radiusSmall, style: .continuous))
            }
            .foregroundStyle(DesignSystem.ink)
            .accessibilityLabel("打开面试模式")
        }
        .padding(.horizontal, DesignSystem.pageHorizontalPadding)
        .padding(.top, SpacingTokens.md)
        .padding(.bottom, SpacingTokens.xs)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch store.currentStage {
        case .importHub:
            ImportHubView()
        case .review:
            ImportReviewView()
        case .matchReport:
            MatchReportView()
        case .voice:
            VoiceSetupView()
        case .scenario:
            ScenarioBuilderView()
        case .result:
            SongPlanResultView()
        case .export:
            ExportCenterView()
        case .interview:
            InterviewModeView()
        }
    }
}
