import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppBackground()

                if proxy.size.width >= 760 {
                    tabletLayout
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    phoneLayout(width: proxy.size.width)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                        .clipped()
                }
            }
        }
        .task {
            appState.configureLayoutPersistence(modelContext)
            appState.startNetworkMonitoring()
            await appState.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await appState.remoteInput.goXLR.setAppActive(phase == .active)
                if phase != .active { await appState.remoteInput.pauseForUnsafeState() }
            }
        }
    }

    private var tabletLayout: some View {
        @Bindable var appState = appState

        return HStack(spacing: DesignToken.Spacing.large) {
            SidebarNavigation(selection: $appState.selectedSection)
                .frame(width: 220)

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(DesignToken.Spacing.large)
    }

    private func phoneLayout(width: CGFloat) -> some View {
        @Bindable var appState = appState

        return VStack(spacing: 0) {
            selectedContent
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity)
                .clipped()

            PhoneTabBar(selection: $appState.selectedSection)
                .frame(width: max(width - (DesignToken.Spacing.small * 2), 0))
                .padding(.horizontal, DesignToken.Spacing.small)
                .padding(.bottom, DesignToken.Spacing.xSmall)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch appState.selectedSection {
        case .dashboard:
            DashboardView()
        case .settings:
            SettingsView()
        case .remote:
            RemoteControlView()
        case .scenes:
            SceneOrchestrationView()
        default:
            PlaceholderFeatureView(section: appState.selectedSection)
        }
    }
}
