import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var isSidebarCollapsed = false
    // Drives re-presenting the full-screen view when the floating bubble is tapped. Set from
    // the bubble's onExpand rather than reusing whatever local @State originally presented it
    // (RoomControlWidgets' widgets own their own booleans, not reachable from here) -- this
    // fullScreenCover is RootView's own, independent presentation of the same store.
    @State private var reexpandedMirrorStore: ScreenMirrorStore?

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

                if let minimized = appState.remoteInput.minimizedMirror {
                    FloatingScreenMirrorBubble(
                        store: minimized,
                        onExpand: { reexpandedMirrorStore = minimized },
                        onClose: {
                            appState.remoteInput.minimizedMirror = nil
                            Task { await minimized.stopMirroring() }
                        }
                    )
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { reexpandedMirrorStore != nil },
            set: { if !$0 { reexpandedMirrorStore = nil } }
        )) {
            if let reexpandedMirrorStore {
                FullScreenScreenMirrorView(store: reexpandedMirrorStore, remote: appState.remoteInput)
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
                await appState.remoteInput.screenMirror.setAppActive(phase == .active)
                await appState.remoteInput.extendDisplay.setAppActive(phase == .active)
                appState.lgTV.setAppActive(phase == .active)
                if phase == .active { await appState.connectCompanionIfConfigured() }
                if phase == .active { await appState.remoteInput.autoConnectIfNeeded() }
                if phase != .active { await appState.remoteInput.pauseForUnsafeState() }
                if phase != .active { await appState.greeClimate.deactivate() }
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

            phoneTabSurface { ClimateView() }
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
        case .climate:
            ClimateView()
        case .scenes:
            SceneOrchestrationView()
        default:
            PlaceholderFeatureView(section: appState.selectedSection)
        }
    }
}
