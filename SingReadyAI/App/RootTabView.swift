import SwiftUI
import SingReadyAISharedKit

struct RootTabView: View {
    @AppStorage("singready.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: DemoWorkflowStore
    @State private var didPrepareLaunch = false

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
            #if DEBUG
            guard !didPrepareLaunch else { return }
            didPrepareLaunch = true
            if ProcessInfo.processInfo.arguments.contains("-singreadyResetOnboarding") {
                hasCompletedOnboarding = false
            }
            guard let launchStage = DemoLaunchStage.fromProcessArguments() else { return }
            hasCompletedOnboarding = true
            await store.prepareDemoState(for: launchStage)
            if ProcessInfo.processInfo.arguments.contains("-singreadyShowGlobalError") {
                store.errorMessage = "当前进度暂时没保存下来，请稍后再试。"
            }
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await store.loadPendingImports() }
            } else {
                Task { await store.persistWorkflowSnapshot() }
                if newPhase == .background {
                    store.cancelVoiceRecording()
                }
            }
        }
    }
}

struct ProductFlowShell: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        NavigationStack(path: $store.navigationPath) {
            stagePage(.home)
                .navigationDestination(for: WorkflowStage.self) { stage in
                    stagePage(stage)
                }
        }
        .tint(DesignSystem.cyan)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage,
               store.currentStage != .importHub {
                HStack(alignment: .top, spacing: SpacingTokens.sm) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(TypographyTokens.caption)
                        .foregroundStyle(DesignSystem.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SpacingTokens.xs)
                    Button {
                        store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(
                                minWidth: ComponentTokens.minTouchTarget,
                                minHeight: ComponentTokens.minTouchTarget
                            )
                    }
                    .accessibilityLabel("关闭错误提示")
                }
                .padding(.horizontal, DesignSystem.pageHorizontalPadding)
                .padding(.vertical, SpacingTokens.xs)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Divider().overlay(DesignSystem.border)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("global-error-banner")
                .accessibilityLabel(errorMessage)
            }
        }
        .environment(
            \.appAccessibilityFlags,
            AccessibilityFlags(
                reduceMotion: accessibilityReduceMotion,
                reduceTransparency: accessibilityReduceTransparency
            )
        )
    }

    private func stagePage(_ stage: WorkflowStage) -> some View {
        ZStack {
            PremiumBackground()
            currentPage(stage)
        }
        .navigationTitle(navigationTitle(for: stage))
        .navigationBarTitleDisplayMode(.inline)
        .nativeNavigationBarSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                StageJumpMenu(
                    stages: WorkflowStage.allCases,
                    current: stage,
                    scenario: activeScenario
                ) { selectedStage in
                    Task {
                        await store.jumpToStage(selectedStage, animated: !accessibilityReduceMotion)
                    }
                }
            }
        }
    }

    private func navigationTitle(for stage: WorkflowStage) -> String {
        stage == .home ? "今晚唱什么" : stage.title(for: activeScenario)
    }

    private var activeScenario: KTVScenario {
        store.songPlan?.scenario ?? store.scenarioConfig.scenario
    }

    @ViewBuilder
    private func currentPage(_ stage: WorkflowStage) -> some View {
        switch stage {
        case .home:
            HomeDashboardView()
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
        case .startTips:
            StartTipsView()
        }
    }
}

private extension View {
    @ViewBuilder
    func nativeNavigationBarSurface() -> some View {
        if #available(iOS 26.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
        } else {
            toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
