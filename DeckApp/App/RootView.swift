import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var isSidebarCollapsed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppBackground()

                if proxy.size.width >= 760 {
                    tabletLayout
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    phoneLayout(width: proxy.size.width)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
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
                appState.lgTV.setAppActive(phase == .active)
                if phase == .active { await appState.connectCompanionIfConfigured() }
                if phase != .active { await appState.remoteInput.pauseForUnsafeState() }
            }
        }
    }

    private var tabletLayout: some View {
        @Bindable var appState = appState

        return HStack(spacing: DesignToken.Spacing.medium) {
            SidebarNavigation(
                selection: $appState.selectedSection,
                isCollapsed: $isSidebarCollapsed
            )
            .frame(width: isSidebarCollapsed ? 76 : 220)

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()
        }
        .padding(DesignToken.Spacing.medium)
        .animation(DesignToken.Animation.responsive, value: isSidebarCollapsed)
    }

    private func phoneLayout(width: CGFloat) -> some View {
        @Bindable var appState = appState

        return TabView(selection: $appState.selectedSection) {
            phoneTabSurface { DashboardView() }
                .tabItem { Label("Dashboard", systemImage: AppSection.dashboard.symbol) }
                .tag(AppSection.dashboard)

            phoneTabSurface { RemoteControlView() }
                .tabItem { Label("Remote", systemImage: AppSection.remote.symbol) }
                .tag(AppSection.remote)

            phoneTabSurface { PlaceholderFeatureView(section: .climate) }
                .tabItem { Label("Climate", systemImage: AppSection.climate.symbol) }
                .tag(AppSection.climate)

            phoneTabSurface { SceneOrchestrationView() }
                .tabItem { Label("Scenes", systemImage: AppSection.scenes.symbol) }
                .tag(AppSection.scenes)

            phoneTabSurface { SettingsView() }
                .tabItem { Label("More", systemImage: AppSection.settings.symbol) }
                .tag(AppSection.settings)
        }
        .tint(DesignToken.Color.accent)
        .background { AppBackground() }
        .frame(width: width, alignment: .leading)
    }

    private func phoneTabSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            AppBackground()
            content()
        }
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
