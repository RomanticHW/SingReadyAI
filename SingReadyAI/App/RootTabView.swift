import SwiftUI
import SingReadyAISharedKit

struct RootTabView: View {
    @AppStorage("singready.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            ProductFlowShell()
        } else {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}

enum DesignSystem {
    static let spacing: CGFloat = 14
    static let cornerRadius: CGFloat = 8
    static let pageHorizontalPadding: CGFloat = 16
    static let cardBackground = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.14)
    static let primary = Color(red: 0.98, green: 0.24, blue: 0.48)
    static let cyan = Color(red: 0.23, green: 0.86, blue: 0.92)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.26)
    static let ink = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.68)

    static let background = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.05, blue: 0.09),
            Color(red: 0.12, green: 0.06, blue: 0.15),
            Color(red: 0.04, green: 0.09, blue: 0.12)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct ProductFlowShell: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        NavigationStack {
            ZStack {
                DesignSystem.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    WorkflowProgressBar()
                        .padding(.horizontal, DesignSystem.pageHorizontalPadding)
                        .padding(.top, 10)
                    Divider().overlay(Color.white.opacity(0.12))
                    currentPage
                }
            }
            .navigationTitle("今晚唱什么")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.currentStage = .interview
                    } label: {
                        Image(systemName: "briefcase")
                    }
                    .accessibilityLabel("面试模式")
                }
            }
        }
        .tint(DesignSystem.primary)
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

struct WorkflowProgressBar: View {
    @EnvironmentObject private var store: DemoWorkflowStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorkflowStage.allCases) { stage in
                    Button {
                        store.currentStage = stage
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: stage.systemImage)
                            Text(stage.title)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(store.currentStage == stage ? DesignSystem.primary.opacity(0.9) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.ink)
                    .accessibilityLabel(stage.title)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

struct NightScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            DesignSystem.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.spacing) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(DesignSystem.ink)
                    content
                }
                .padding(DesignSystem.pageHorizontalPadding)
            }
        }
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius)
                .stroke(DesignSystem.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
    }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(DesignSystem.primary)
        .accessibilityLabel(title)
    }
}

struct SecondaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(DesignSystem.cyan)
        .accessibilityLabel(title)
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(DesignSystem.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(DesignSystem.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minHeight: 58)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
        .foregroundStyle(DesignSystem.ink)
    }
}

struct TagCloud: View {
    let values: [String]
    var tint: Color = DesignSystem.cyan

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(tint.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.cornerRadius)
                            .stroke(tint.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius))
                    .foregroundStyle(DesignSystem.ink)
            }
        }
    }
}

extension View {
    func stageText() -> some View {
        foregroundStyle(DesignSystem.ink)
    }
}
