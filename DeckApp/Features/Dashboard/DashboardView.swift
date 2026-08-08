import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var showLayoutEditor = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 820
            let horizontalPadding = compact ? DesignToken.Spacing.medium : DesignToken.Spacing.xSmall

            ScrollView {
                VStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
                    DashboardHeader(compact: compact)

                    if let command = appState.pendingCommand {
                        HStack {
                            Text(command.backendMessage ?? "Sending command…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            CommandStatusPill(status: command.status)
                        }
                        .padding(.horizontal, 2)
                    }

                    HStack {
                        Text(appState.roomControlTemplate.name)
                            .font(.title3.bold())
                        Spacer()
                        Text(appState.hasMappedHomeAssistantWidgets ? "Phase 5 · Live + Mock" : "Phase 5 · Mock Mode")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button {
                            RemoteHaptics.heavy()
                            showLayoutEditor = true
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignToken.Color.accent)
                    }

                    RoomControlGrid(
                        template: appState.roomControlTemplate,
                        columnCount: compact ? 2 : 4,
                        layoutClass: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
                    )
                }
                .frame(width: max(proxy.size.width - (horizontalPadding * 2), 0), alignment: .leading)
                .clipped()
                .padding(.horizontal, horizontalPadding)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showLayoutEditor) {
            DashboardLayoutEditorView()
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-editLayout") {
                showLayoutEditor = true
            }
            #endif
        }
    }

}

private struct DashboardHeader: View {
    @Environment(AppState.self) private var appState
    let compact: Bool

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(appState.dashboard.roomName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    GlassConnectionBadge(route: appState.activeHomeAssistantRoute)
                }
                Text("Good Evening, Alex 👋")
                    .font(.title3.bold())

                Label {
                    Text(appState.dashboard.temperature, format: .number.precision(.fractionLength(1))) + Text("°C Room Temperature")
                } icon: {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(DesignToken.Color.accent)
                }
                .font(.caption.weight(.semibold))
                .padding(.top, DesignToken.Spacing.xSmall)
            }
        } else {
            HStack(alignment: .center, spacing: DesignToken.Spacing.medium) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Good Evening, Alex 👋")
                        .font(.title2.bold())
                    Text("Your room is ready")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: DesignToken.Spacing.small) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(DesignToken.Color.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appState.dashboard.temperature, format: .number.precision(.fractionLength(1))) + Text("°C")
                        Text("Room Temperature")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                GlassConnectionBadge(route: appState.activeHomeAssistantRoute)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct LightCard: View {
    @Environment(AppState.self) private var appState
    let index: Int

    private var light: LightDevice {
        appState.dashboard.lights[index]
    }

    var body: some View {
        DashboardCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(light.name).font(.subheadline.weight(.semibold))
                    Text(light.brightness, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GlassIcon(symbol: "lightbulb.fill", size: 42)
            }

            Slider(
                value: Binding(
                    get: { appState.dashboard.lights[index].brightness },
                    set: { brightness in
                        appState.dashboard.lights[index].brightness = brightness
                    }
                ),
                in: 0...1
            ) { editing in
                guard !editing else { return }
                let brightness = appState.dashboard.lights[index].brightness
                Task { await appState.perform(.setLight(id: light.id, brightness: brightness)) }
            }
                .tint(DesignToken.Color.accent)
                .accessibilityLabel("\(light.name) brightness")
        }
    }
}

private struct ClimateCard: View {
    @Environment(AppState.self) private var appState
    let compact: Bool

    var body: some View {
        DashboardCard(title: "Climate", symbol: "snowflake") {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(appState.dashboard.climate.currentTemperature))°")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(Int(appState.dashboard.climate.targetTemperature))°")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("Set Temperature").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !compact {
                    GlassIcon(symbol: "snowflake", tint: DesignToken.Color.cyan, size: 48)
                }
            }

            Slider(
                value: Binding(
                    get: { appState.dashboard.climate.targetTemperature },
                    set: { appState.dashboard.climate.targetTemperature = $0 }
                ),
                in: 16...30,
                step: 0.5
            ) { editing in
                guard !editing else { return }
                Task { await appState.perform(.setTargetTemperature(appState.dashboard.climate.targetTemperature)) }
            }
            .tint(DesignToken.Color.accent)
        }
    }
}

private struct TVCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        DashboardCard(title: "TV", symbol: "tv") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.dashboard.tv.source).font(.headline)
                    Label(appState.dashboard.tv.isPlaying ? "Playing" : "Paused", systemImage: "play.fill")
                        .font(.caption)
                        .foregroundStyle(DesignToken.Color.cyan)
                }
                Spacer()
                GlassIcon(symbol: "tv", size: 48)
            }

            Slider(
                value: Binding(
                    get: { appState.dashboard.tv.volume },
                    set: { appState.dashboard.tv.volume = $0 }
                ),
                in: 0...1
            )
            .tint(DesignToken.Color.accent)

            HStack(spacing: DesignToken.Spacing.small) {
                GlassActionButton(title: "Power", symbol: "power") {
                    Task { await appState.perform(.toggleTVPower) }
                }
                GlassActionButton(title: "Input", symbol: "rectangle.on.rectangle") {}
                if !isCompactWidth {
                    GlassActionButton(title: "Mute", symbol: "speaker.slash") {}
                }
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }
}

private struct SceneButton: View {
    let scene: ScenePreset
    let action: () -> Void

    var body: some View {
        let tint = Color.sceneTint(named: scene.tintName)

        Button {
            RemoteHaptics.heavy()
            action()
        } label: {
            HStack(spacing: DesignToken.Spacing.small) {
                GlassIcon(symbol: scene.symbol, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name).font(.subheadline.weight(.semibold))
                    Text(scene.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignToken.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.card, tint: tint.opacity(0.18), interactive: true)
    }
}

private struct PCControlsCard: View {
    let compact: Bool

    var body: some View {
        DashboardCard {
            ControlDeckView(compact: compact)
        }
    }
}

private struct MediaCard: View {
    @Environment(AppState.self) private var appState
    let compact: Bool

    var body: some View {
        DashboardCard {
            HStack {
                Label(appState.dashboard.media.source, systemImage: "music.note")
                    .font(.headline)
                    .foregroundStyle(DesignToken.Color.positive)
                Spacer()
                Text(appState.dashboard.media.destination)
                    .font(.caption)
                    .foregroundStyle(DesignToken.Color.positive)
            }

            HStack(spacing: DesignToken.Spacing.medium) {
                RoundedRectangle(cornerRadius: DesignToken.Radius.control)
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: compact ? 64 : 82, height: compact ? 64 : 82)
                    .overlay(Image(systemName: "sun.horizon.fill").font(.title).foregroundStyle(.white))

                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.dashboard.media.title).font(.headline)
                    Text(appState.dashboard.media.artist).font(.subheadline)
                    Text("Endless Summer").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            ProgressView(value: appState.dashboard.media.progress)
                .tint(DesignToken.Color.accent)

            HStack {
                Spacer()
                Button { RemoteHaptics.heavy() } label: { Image(systemName: "backward.fill") }
                Spacer()
                Button {
                    RemoteHaptics.heavy()
                } label: {
                    Image(systemName: appState.dashboard.media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .glassSurface(.interactive, cornerRadius: 999, interactive: true)
                Spacer()
                Button { RemoteHaptics.heavy() } label: { Image(systemName: "forward.fill") }
                Spacer()
            }
            .buttonStyle(.plain)
        }
    }
}
