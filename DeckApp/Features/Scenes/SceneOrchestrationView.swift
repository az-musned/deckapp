import SwiftUI

struct SceneOrchestrationView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 700
            ScrollView {
                VStack(alignment: .leading, spacing: DesignToken.Spacing.large) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Scenes").font(compact ? .title2.bold() : .largeTitle.bold())
                            Text("Home Assistant scenes and orchestrations")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        GlassConnectionBadge(route: appState.activeHomeAssistantRoute)
                    }

                    if let execution = appState.sceneOrchestrationExecution {
                        orchestrationProgress(execution)
                    }

                    if appState.homeAssistantSceneActions.isEmpty {
                        mockScenes
                    } else {
                        let columns = [GridItem(.adaptive(minimum: compact ? 150 : 210), spacing: DesignToken.Spacing.medium)]
                        LazyVGrid(columns: columns, spacing: DesignToken.Spacing.medium) {
                            ForEach(appState.homeAssistantSceneActions) { action in
                                sceneCard(action)
                            }
                        }
                    }
                }
                .padding(compact ? DesignToken.Spacing.medium : DesignToken.Spacing.large)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sceneCard(_ action: HomeAssistantSceneAction) -> some View {
        DashboardCard {
            HStack {
                GlassIcon(symbol: action.symbol, tint: action.domain == "scene" ? .purple : DesignToken.Color.accent, size: 42)
                Spacer()
                Button {
                    appState.toggleSceneActionFavorite(action.entityID)
                } label: {
                    Image(systemName: action.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(action.isFavorite ? DesignToken.Color.warning : .secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            Text(action.title)
                .font(.headline)
                .lineLimit(2)
            Label(action.isAvailable ? action.kindTitle : "Unavailable", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(action.isAvailable ? DesignToken.Color.positive : DesignToken.Color.destructive)
            Button {
                Task { await appState.activateSceneAction(action) }
            } label: {
                Label("Activate", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignToken.Spacing.small)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: .purple.opacity(0.18), interactive: true)
            .disabled(!action.isAvailable)
        }
    }

    private func orchestrationProgress(_ execution: SceneOrchestrationExecution) -> some View {
        DashboardCard {
            HStack {
                Label(execution.title, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if let final = execution.steps.last { CommandStatusPill(status: final.status) }
            }
            ForEach(execution.steps) { step in
                HStack(alignment: .top, spacing: DesignToken.Spacing.small) {
                    Image(systemName: stepSymbol(step.status))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.caption.weight(.semibold))
                        Text(step.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if step.status == .running { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var mockScenes: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
            Text("Preview Scenes").font(.headline)
            Text("Connect Home Assistant to discover live scenes and scripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignToken.Spacing.medium)]) {
                ForEach(appState.dashboard.scenes) { scene in
                    Button {
                        Task { await appState.perform(.activateScene(scene.name)) }
                    } label: {
                        VStack(alignment: .leading, spacing: DesignToken.Spacing.small) {
                            GlassIcon(symbol: scene.symbol, tint: Color.controlDeckTint(named: scene.tintName), size: 40)
                            Text(scene.name).font(.headline)
                            Text(scene.subtitle).font(.caption).foregroundStyle(.secondary)
                            Text("MOCK").font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                        .padding(DesignToken.Spacing.medium)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(.interactive, cornerRadius: DesignToken.Radius.card, tint: Color.controlDeckTint(named: scene.tintName).opacity(0.12), interactive: true)
                }
            }
        }
    }

    private func stepSymbol(_ status: CommandStatus) -> String {
        switch status {
        case .confirmed: "checkmark.circle.fill"
        case .failed, .unavailable: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .queued, .pending: "circle"
        }
    }

    private func stepColor(_ status: CommandStatus) -> Color {
        switch status {
        case .confirmed: DesignToken.Color.positive
        case .failed, .unavailable: DesignToken.Color.destructive
        case .running: DesignToken.Color.warning
        case .queued, .pending: .secondary
        }
    }
}
