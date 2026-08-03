import SwiftUI

struct RoomControlWidgetView: View {
    let definition: RoomWidgetDefinition
    let compact: Bool

    @ViewBuilder
    var body: some View {
        switch definition.kind {
        case .light:
            MockLightWidget(definition: definition)
        case .climate:
            MockClimateWidget(definition: definition, compact: compact)
        case .television:
            MockTelevisionWidget(definition: definition, compact: compact)
        case .pcPower:
            MockPCPowerWidget(definition: definition)
        case .audioMixer:
            MockGoXLRWidget(definition: definition, compact: compact)
        case .companionActions:
            CompanionActionsWidget(definition: definition, compact: compact)
        case .remoteInputLauncher:
            RemoteInputLauncherWidget(definition: definition)
        }
    }
}

private struct RemoteInputLauncherWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition

    var body: some View {
        DashboardCard {
            if definition.size == .small {
                WidgetHeader(definition: definition, availability: .available)
                Text(appState.remoteInput.connectionState.title)
                    .font(.title3.bold())
                Button {
                    appState.selectedSection = .remote
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignToken.Spacing.small)
                }
                .buttonStyle(.plain)
                .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.cyan.opacity(0.18), interactive: true)
            } else {
                HStack(spacing: DesignToken.Spacing.medium) {
                    GlassIcon(symbol: definition.symbol, tint: DesignToken.Color.cyan, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition.title).font(.headline).lineLimit(1)
                        Text("\(appState.remoteInput.connectionState.title) · Mock Agent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.selectedSection = .remote
                    } label: {
                        Label("Open Remote", systemImage: "arrow.up.forward.app.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, DesignToken.Spacing.medium)
                            .padding(.vertical, DesignToken.Spacing.small)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.cyan.opacity(0.18), interactive: true)
                }
            }
        }
    }
}

private struct CompanionActionsWidget: View {
    @State private var showControlDeck = false
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        if definition.size == .small {
            DashboardCard {
                WidgetHeader(definition: definition, availability: .available)
                Text("Actions & macros")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showControlDeck = true
                } label: {
                    Label("Open", systemImage: "square.grid.2x2.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignToken.Spacing.small)
                }
                .buttonStyle(.plain)
                .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.accent.opacity(0.16), interactive: true)
            }
            .sheet(isPresented: $showControlDeck) {
                NavigationStack {
                    ScrollView {
                        DashboardCard {
                            ControlDeckView(compact: true)
                        }
                        .padding()
                    }
                    .background(AppBackground())
                    .navigationTitle("Companion Actions")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        } else {
            DashboardCard {
                ControlDeckView(compact: compact)
            }
        }
    }
}

private struct WidgetHeader: View {
    let definition: RoomWidgetDefinition
    let availability: DeviceAvailability

    var body: some View {
        if definition.size == .small {
            VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
                HStack {
                    GlassIcon(
                        symbol: definition.symbol,
                        tint: Color.controlDeckTint(named: definition.tintName),
                        size: 36
                    )
                    Spacer(minLength: 4)
                    Circle()
                        .fill(availability == .available ? DesignToken.Color.positive : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(definition.backend.backend == .homeAssistant ? "LIVE" : "MOCK")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(definition.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        } else {
            HStack(alignment: .top, spacing: DesignToken.Spacing.small) {
                GlassIcon(
                    symbol: definition.symbol,
                    tint: Color.controlDeckTint(named: definition.tintName),
                    size: 42
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(definition.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Label(availability == .available ? "Available" : "Unavailable", systemImage: "circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(availability == .available ? DesignToken.Color.positive : .secondary)
                        .lineLimit(1)
                    Text(definition.backend.backend == .homeAssistant ? "LIVE" : "MOCK")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MockLightWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: appState.mockRoomControl.light.availability)

            HStack {
                Text(appState.mockRoomControl.light.isOn ? "On" : "Off")
                    .font(.title3.bold())
                Spacer()
                Button {
                    Task { await appState.toggleRoomLightControl() }
                } label: {
                    Image(systemName: "power")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .glassSurface(.interactive, cornerRadius: 999, tint: DesignToken.Color.accent.opacity(0.2), interactive: true)
            }

            if supports(.brightness) {
                NumericControlRow(
                    title: "Brightness",
                    value: Binding(
                        get: { appState.mockRoomControl.light.brightness },
                        set: { appState.mockRoomControl.light.brightness = $0 }
                    ),
                    range: 0...100,
                    step: 1,
                    valueLabel: "\(Int(appState.mockRoomControl.light.brightness))%"
                ) {
                    Task { await appState.commitRoomLightBrightness() }
                }
            }

            if supports(.colorTemperature), definition.size.presentationDensity == .expanded {
                NumericControlRow(
                    title: "Warmth",
                    value: Binding(
                        get: { appState.mockRoomControl.light.colorTemperature },
                        set: { appState.mockRoomControl.light.colorTemperature = $0 }
                    ),
                    range: 2200...6500,
                    step: 50,
                    valueLabel: "\(Int(appState.mockRoomControl.light.colorTemperature))K"
                ) {
                    Task { await appState.commitRoomLightColorTemperature() }
                }
            }
        }
    }

    private func supports(_ capability: DeviceCapabilityKind) -> Bool {
        definition.capabilities.contains { $0.kind == capability && $0.availability == .available }
    }
}

private struct MockClimateWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: appState.mockRoomControl.climate.availability)

            if definition.size == .small {
                VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
                    Text("\(appState.mockRoomControl.climate.targetTemperature, specifier: "%.1f")°")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Target · Current \(appState.mockRoomControl.climate.currentTemperature, specifier: "%.1f")°")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: DesignToken.Spacing.small) {
                        temperatureButton("minus") { adjustTemperature(by: -0.5) }
                        temperatureButton("plus") { adjustTemperature(by: 0.5) }
                    }
                }
            } else {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(appState.mockRoomControl.climate.currentTemperature, specifier: "%.1f")°")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(appState.mockRoomControl.climate.targetTemperature, specifier: "%.1f")°")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                        Text("Target").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if supports(.temperature) {
                    NumericControlRow(
                        title: "Temperature",
                        value: Binding(
                            get: { appState.mockRoomControl.climate.targetTemperature },
                            set: { appState.mockRoomControl.climate.targetTemperature = $0 }
                        ),
                        range: temperatureRange,
                        step: temperatureStep,
                        valueLabel: String(format: "%.1f°C", appState.mockRoomControl.climate.targetTemperature)
                    ) {
                        Task { await appState.commitClimateTemperature() }
                    }
                }

                if definition.size == .large || definition.size == .wide {
                    ViewThatFits(in: .horizontal) {
                        HStack { climateMenus }
                        VStack(alignment: .leading) { climateMenus }
                    }
                } else if supports(.hvacMode) {
                    HStack { optionMenu("Mode", capability: .hvacMode, value: appState.mockRoomControl.climate.hvacMode, options: options(for: .hvacMode, fallback: ["cool", "dry", "fan_only", "off"])) { appState.mockRoomControl.climate.hvacMode = display($0) } }
                }
            }
        }
    }

    private func adjustTemperature(by delta: Double) {
        appState.mockRoomControl.climate.targetTemperature = min(temperatureRange.upperBound, max(temperatureRange.lowerBound, appState.mockRoomControl.climate.targetTemperature + delta))
        Task { await appState.commitClimateTemperature() }
    }

    private func temperatureButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.cyan.opacity(0.14), interactive: true)
    }

    @ViewBuilder
    private var climateMenus: some View {
        if supports(.hvacMode) {
            optionMenu("Mode", capability: .hvacMode, value: appState.mockRoomControl.climate.hvacMode, options: options(for: .hvacMode, fallback: ["cool", "dry", "fan_only", "off"])) {
                appState.mockRoomControl.climate.hvacMode = display($0)
            }
        }
        if supports(.fanMode) {
            optionMenu("Fan", capability: .fanMode, value: appState.mockRoomControl.climate.fanMode, options: options(for: .fanMode, fallback: ["auto", "low", "medium", "high"])) {
                appState.mockRoomControl.climate.fanMode = display($0)
            }
        }
        if supports(.swingMode) {
            optionMenu("Swing", capability: .swingMode, value: appState.mockRoomControl.climate.swingMode, options: options(for: .swingMode, fallback: ["off", "vertical"])) {
                appState.mockRoomControl.climate.swingMode = display($0)
            }
        }
    }

    private func optionMenu(_ title: String, capability: DeviceCapabilityKind, value: String, options: [String], set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(display(option)) {
                    set(option)
                    Task { await appState.setClimateOption(capability, value: option) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, interactive: true)
    }

    private func options(for capability: DeviceCapabilityKind, fallback: [String]) -> [String] {
        definition.capabilities.first(where: { $0.kind == capability })?.selection?.options ?? fallback
    }

    private var temperatureRange: ClosedRange<Double> {
        guard let numeric = definition.capabilities.first(where: { $0.kind == .temperature })?.numericRange else { return 16...30 }
        return numeric.minimum...numeric.maximum
    }

    private var temperatureStep: Double {
        definition.capabilities.first(where: { $0.kind == .temperature })?.numericRange?.step ?? 0.5
    }

    private func display(_ option: String) -> String {
        option.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func supports(_ capability: DeviceCapabilityKind) -> Bool {
        definition.capabilities.contains { $0.kind == capability && $0.availability == .available }
    }
}

private struct MockTelevisionWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        DashboardCard {
            WidgetHeader(
                definition: definition,
                availability: appState.mockRoomControl.television.isOnline ? .available : .unavailable
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.mockRoomControl.television.source).font(.title3.bold())
                    Text(appState.mockRoomControl.television.application)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if supports(.power) {
                    Button {
                        Task { await appState.toggleTelevisionControl() }
                    } label: {
                        Image(systemName: "power").frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(.interactive, cornerRadius: 999, tint: .purple.opacity(0.2), interactive: true)
                }
            }

            if supports(.sourceSelection), !sourceOptions.isEmpty {
                Menu {
                    ForEach(sourceOptions, id: \.self) { source in
                        Button(source) { Task { await appState.selectTelevisionSource(source) } }
                    }
                } label: {
                    LabeledContent("Source") {
                        Text(appState.mockRoomControl.television.source)
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .padding(DesignToken.Spacing.small)
                }
                .buttonStyle(.plain)
                .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, interactive: true)
            }

            if definition.size != .small && supports(.volume) {
                NumericControlRow(
                title: "Volume",
                value: Binding(
                    get: { appState.mockRoomControl.television.volume },
                    set: { appState.mockRoomControl.television.volume = $0 }
                ),
                range: 0...100,
                step: 1,
                valueLabel: "\(Int(appState.mockRoomControl.television.volume))%"
                ) {
                    Task { await appState.commitTelevisionVolume() }
                }
            }

            if (definition.size == .large || definition.size == .wide) && supports(.directionalRemote) {
                DirectionalRemoteControl { command in
                    Task { await appState.sendTelevisionControl(command) }
                }
            } else {
                HStack(spacing: DesignToken.Spacing.small) {
                    if supports(.mute) {
                        GlassActionButton(title: "Mute", symbol: "speaker.slash.fill") {
                            Task { await appState.toggleTelevisionMute() }
                        }
                    }
                    if supports(.mediaPlayback) {
                        GlassActionButton(title: "Play", symbol: "playpause.fill") {
                            Task { await appState.sendTelevisionControl("PlayPause") }
                        }
                    }
                }
            }

            if let command = appState.mockRoomControl.television.lastRemoteCommand {
                Text("Last remote command: \(command)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func supports(_ capability: DeviceCapabilityKind) -> Bool {
        definition.capabilities.contains { $0.kind == capability && $0.availability == .available }
    }

    private var sourceOptions: [String] {
        definition.capabilities.first(where: { $0.kind == .sourceSelection })?.selection?.options ?? []
    }
}

private struct DirectionalRemoteControl: View {
    let send: (String) -> Void

    var body: some View {
        Grid(horizontalSpacing: DesignToken.Spacing.small, verticalSpacing: DesignToken.Spacing.xSmall) {
            GridRow {
                Color.clear.frame(width: 42, height: 34)
                remoteButton("chevron.up", command: "Up")
                Color.clear.frame(width: 42, height: 34)
            }
            GridRow {
                remoteButton("chevron.left", command: "Left")
                remoteButton("circle.inset.filled", command: "OK")
                remoteButton("chevron.right", command: "Right")
            }
            GridRow {
                remoteButton("arrow.uturn.backward", command: "Back")
                remoteButton("chevron.down", command: "Down")
                remoteButton("house.fill", command: "Home")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func remoteButton(_ symbol: String, command: String) -> some View {
        Button { send(command) } label: {
            Image(systemName: symbol)
                .frame(width: 42, height: 34)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: 10, tint: .purple.opacity(0.12), interactive: true)
        .accessibilityLabel(command)
    }
}

private struct MockPCPowerWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: plugAvailability)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.mockRoomControl.pcPower.pcState.title)
                        .font(.title3.bold())
                    Text("Plug: \(appState.mockRoomControl.pcPower.plugState.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stateIcon
            }

            if case .booting(let progress) = appState.mockRoomControl.pcPower.pcState {
                ProgressView(value: progress)
                    .tint(DesignToken.Color.warning)
            }

            Button {
                Task { await appState.startPCControl() }
            } label: {
                Label("Turn On and Start PC", systemImage: "power")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignToken.Spacing.small)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.warning.opacity(0.2), interactive: true)
            .disabled(appState.mockRoomControl.pcPower.pcState != .offline)

            Label("Power-off is intentionally unavailable", systemImage: "lock.shield.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch appState.mockRoomControl.pcPower.pcState {
        case .supplyingPower, .booting:
            ProgressView().controlSize(.regular)
        case .online:
            GlassIcon(symbol: "checkmark.circle.fill", tint: DesignToken.Color.positive, size: 44)
        case .failed:
            GlassIcon(symbol: "exclamationmark.triangle.fill", tint: DesignToken.Color.destructive, size: 44)
        case .offline:
            GlassIcon(symbol: "desktopcomputer", tint: .secondary, size: 44)
        }
    }

    private var plugAvailability: DeviceAvailability {
        appState.mockRoomControl.pcPower.plugState == .unavailable ? .unavailable : .available
    }
}

private struct MockGoXLRWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        DashboardCard {
            WidgetHeader(
                definition: definition,
                availability: appState.mockRoomControl.goXLR.isConnected ? .available : .unavailable
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 130 : 180), spacing: DesignToken.Spacing.medium)]) {
                ForEach(visibleChannelIndices, id: \.self) { index in
                    mixerChannel(index: index)
                }
            }
        }
    }

    private var visibleChannelIndices: [Int] {
        let limit = switch definition.size.presentationDensity {
        case .compact: 1
        case .standard: 2
        case .expanded: appState.mockRoomControl.goXLR.channels.count
        }
        return Array(appState.mockRoomControl.goXLR.channels.indices.prefix(limit))
    }

    private func mixerChannel(index: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
            HStack {
                Text(appState.mockRoomControl.goXLR.channels[index].name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    appState.mockRoomControl.goXLR.channels[index].isMuted.toggle()
                    Task { await appState.confirmMockControl("GoXLR mute") }
                } label: {
                    Image(systemName: appState.mockRoomControl.goXLR.channels[index].isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(appState.mockRoomControl.goXLR.channels[index].isMuted ? DesignToken.Color.destructive : DesignToken.Color.positive)
                }
                .buttonStyle(.plain)
            }
            Slider(
                value: Binding(
                    get: { appState.mockRoomControl.goXLR.channels[index].level },
                    set: { appState.mockRoomControl.goXLR.channels[index].level = $0 }
                ),
                in: 0...1
            ) { editing in
                if !editing { Task { await appState.confirmMockControl("GoXLR channel level") } }
            }
            .tint(Color.controlDeckTint(named: definition.tintName))
        }
        .padding(DesignToken.Spacing.small)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.control, tint: Color.controlDeckTint(named: definition.tintName).opacity(0.08))
    }
}

private struct NumericControlRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { commit() }
            }
            .tint(DesignToken.Color.accent)
        }
    }
}
