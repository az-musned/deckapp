import SwiftUI

struct RoomControlWidgetView: View {
    let definition: RoomWidgetDefinition
    let compact: Bool

    @ViewBuilder
    var body: some View {
        switch definition.kind {
        case .light:
            if definition.backend.backend == .govee {
                GoveeLightWidget(definition: definition)
            } else {
                MockLightWidget(definition: definition)
            }
        case .climate:
            MockClimateWidget(definition: definition, compact: compact)
        case .television:
            MockTelevisionWidget(definition: definition, compact: compact)
        case .pcPower:
            MockPCPowerWidget(definition: definition)
        case .audioMixer:
            GoXLRWidget(definition: definition, compact: compact)
        case .companionActions:
            CompanionActionsWidget(definition: definition, compact: compact)
        case .remoteInputLauncher:
            RemoteInputLauncherWidget(definition: definition)
        case .screenMirror:
            ScreenMirrorLauncherWidget(definition: definition)
        case .discord:
            DiscordWidget(definition: definition, compact: compact)
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

private struct ScreenMirrorLauncherWidget: View {
    @Environment(AppState.self) private var appState
    @State private var showFullScreenMirror = false
    let definition: RoomWidgetDefinition

    private var remote: RemoteInputController { appState.remoteInput }
    private var mode: ScreenMirrorMode { definition.resolvedScreenMirrorMode }
    private var store: ScreenMirrorStore { mode == .extend ? remote.extendDisplay : remote.screenMirror }
    private var tint: Color { mode == .extend ? Color.controlDeckTint(named: "purple") : DesignToken.Color.cyan }
    private var watchLabel: String { mode == .extend ? "Extend" : "Watch" }

    private var statusText: String {
        remote.usesMockAgent ? "Mock Agent" : remote.securityState.screenShareAllowed ? "Ready" : "Disabled on PC"
    }

    var body: some View {
        DashboardCard {
            if definition.size == .small {
                WidgetHeader(definition: definition, availability: .available)
                Text(statusText)
                    .font(.title3.bold())
                watchButton
            } else {
                HStack(spacing: DesignToken.Spacing.medium) {
                    GlassIcon(symbol: definition.symbol, tint: Color.controlDeckTint(named: definition.tintName), size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition.title).font(.headline).lineLimit(1)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    watchButton
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreenMirror) {
            FullScreenScreenMirrorView(store: store)
        }
    }

    private var watchButton: some View {
        Button {
            showFullScreenMirror = true
        } label: {
            Label(watchLabel, systemImage: definition.symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DesignToken.Spacing.medium)
                .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.18), interactive: true)
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
                    Text(backendBadge)
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
                    Text(backendBadge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backendBadge: String {
        switch definition.backend.backend {
        case .homeAssistant: "LIVE"
        case .govee: "GOVEE"
        case .windowsAgent: "AGENT"
        case .companion: "COMPANION"
        case .mock: "MOCK"
        }
    }
}

private struct GoveeLightWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition

    private let colorPresets: [(String, Int, Color)] = [
        ("Red", 0xFF3B30, .red), ("Orange", 0xFF9500, .orange),
        ("Yellow", 0xFFCC00, .yellow), ("Green", 0x34C759, .green),
        ("Cyan", 0x32ADE6, .cyan), ("Blue", 0x007AFF, .blue),
        ("Purple", 0xAF52DE, .purple), ("White", 0xFFFFFF, .white)
    ]

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: availability)

            if let device {
                powerControl(device)
                ForEach(visibleCapabilities) { capability in
                    capabilityControl(device, capability)
                }
            } else {
                ContentUnavailableView(
                    "Govee Device Unavailable",
                    systemImage: "lightbulb.slash",
                    description: Text("Reconnect Govee from Settings or choose another device.")
                )
                .frame(maxHeight: 150)
            }
        }
        .task(id: definition.backend.identifier) {
            await appState.refreshGoveeState(deviceID: definition.backend.identifier)
        }
    }

    private var device: GoveeDevice? {
        appState.goveeDevice(for: definition.backend.identifier)
    }

    private var availability: DeviceAvailability {
        guard let device else { return .unavailable }
        guard let online = device.capabilities.first(where: { $0.instance == "online" }) else { return .available }
        if case .bool(let value) = appState.goveeValue(deviceID: device.id, capabilityID: online.id) {
            return value ? .available : .unavailable
        }
        return .available
    }

    private var visibleCapabilities: [GoveeCapability] {
        guard let device else { return [] }
        let controls = device.actionableCapabilities.filter { $0.instance != "powerSwitch" }
        return switch definition.size.presentationDensity {
        case .compact: []
        case .standard: Array(controls.prefix(2))
        case .expanded: controls
        }
    }

    @ViewBuilder
    private func powerControl(_ device: GoveeDevice) -> some View {
        if let capability = device.actionableCapabilities.first(where: { $0.instance == "powerSwitch" }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPowerOn(device, capability) ? "On" : "Off")
                        .font(.title3.bold())
                    Text("Power")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let value = powerValue(capability, turnOn: !isPowerOn(device, capability))
                    Task { await appState.setGoveeCapability(deviceID: device.id, capabilityID: capability.id, value: value) }
                } label: {
                    Image(systemName: "power")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .glassSurface(
                    .interactive,
                    cornerRadius: 999,
                    tint: (isPowerOn(device, capability) ? DesignToken.Color.positive : DesignToken.Color.accent).opacity(0.2),
                    interactive: true
                )
            }
        }
    }

    @ViewBuilder
    private func capabilityControl(_ device: GoveeDevice, _ capability: GoveeCapability) -> some View {
        if capability.instance == "colorRgb" {
            VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
                Text("Color").font(.caption)
                HStack(spacing: DesignToken.Spacing.small) {
                    ForEach(colorPresets, id: \.0) { preset in
                        Button {
                            Task {
                                await appState.setGoveeCapability(
                                    deviceID: device.id,
                                    capabilityID: capability.id,
                                    value: .number(Double(preset.1))
                                )
                            }
                        } label: {
                            Circle()
                                .fill(preset.2)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.0)
                    }
                }
            }
        } else if let options = capability.parameters?.options, !options.isEmpty {
            HStack {
                Text(capability.title).font(.caption)
                Spacer()
                Menu {
                    ForEach(options) { option in
                        Button(option.name) {
                            Task {
                                await appState.setGoveeCapability(
                                    deviceID: device.id,
                                    capabilityID: capability.id,
                                    value: option.value
                                )
                            }
                        }
                    }
                } label: {
                    Text(optionName(device, capability, options: options))
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(DesignToken.Spacing.small)
            .glassSurface(.subtle, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.accent.opacity(0.08))
        } else if let range = capability.parameters?.range {
            NumericControlRow(
                title: capability.title,
                value: numericBinding(device, capability, fallback: range.min),
                range: range.min...range.max,
                step: max(range.precision ?? 1, 1),
                valueLabel: numericValue(device, capability, fallback: range.min).formatted(.number.precision(.fractionLength(0))) + unitLabel(capability)
            ) {
                let value = numericValue(device, capability, fallback: range.min)
                Task {
                    await appState.setGoveeCapability(deviceID: device.id, capabilityID: capability.id, value: .number(value))
                }
            }
        }
    }

    private func numericBinding(_ device: GoveeDevice, _ capability: GoveeCapability, fallback: Double) -> Binding<Double> {
        Binding(
            get: { numericValue(device, capability, fallback: fallback) },
            set: { appState.goveeControlValues[device.id, default: [:]][capability.id] = .number($0) }
        )
    }

    private func numericValue(_ device: GoveeDevice, _ capability: GoveeCapability, fallback: Double) -> Double {
        guard case .number(let value) = appState.goveeValue(deviceID: device.id, capabilityID: capability.id) else { return fallback }
        return value
    }

    private func isPowerOn(_ device: GoveeDevice, _ capability: GoveeCapability) -> Bool {
        switch appState.goveeValue(deviceID: device.id, capabilityID: capability.id) {
        case .number(let value): value != 0
        case .bool(let value): value
        case .string(let value): value.caseInsensitiveCompare("on") == .orderedSame
        default: false
        }
    }

    private func powerValue(_ capability: GoveeCapability, turnOn: Bool) -> GoveeValue {
        let desiredName = turnOn ? "on" : "off"
        return capability.parameters?.options?.first {
            $0.name.caseInsensitiveCompare(desiredName) == .orderedSame
        }?.value ?? .number(turnOn ? 1 : 0)
    }

    private func optionName(_ device: GoveeDevice, _ capability: GoveeCapability, options: [GoveeCapabilityOption]) -> String {
        guard let value = appState.goveeValue(deviceID: device.id, capabilityID: capability.id) else { return "Choose" }
        return options.first(where: { $0.value == value })?.name ?? value.displayValue
    }

    private func unitLabel(_ capability: GoveeCapability) -> String {
        switch capability.parameters?.unit {
        case "unit.percent": "%"
        case "unit.colorTemperature": "K"
        case .some(let unit): unit.replacingOccurrences(of: "unit.", with: " ")
        case nil: ""
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

private struct DiscordWidget: View {
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        if definition.backend.backend == .windowsAgent {
            LiveDiscordWidget(definition: definition, compact: compact)
        } else {
            MockDiscordWidget(definition: definition, compact: compact)
        }
    }
}

private struct LiveDiscordWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool
    @State private var showingHotkeyPicker = false

    private var store: DiscordStore { appState.remoteInput.discord }

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: store.bridgeState == .ready ? .available : .unavailable)

            switch store.bridgeState {
            case .notConfigured:
                Label("Set Discord Client ID/Secret on the PC to enable this widget.", systemImage: "gearshape.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disconnected, .connectingToClient, .authenticating:
                HStack(spacing: DesignToken.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text(store.bridgeState.title).font(.caption).foregroundStyle(.secondary)
                }
            case .awaitingAuthorization:
                Label("Approve the Discord prompt on your PC.", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                readyContent
            }

            if let lastError = store.lastError, store.bridgeState == .ready {
                Text(lastError).font(.caption2).foregroundStyle(DesignToken.Color.destructive)
            }
        }
        .task {
            await store.startWatching()
            do { try await Task.sleep(for: .seconds(86_400)) } catch { }
            await store.stopWatching()
        }
        .sheet(isPresented: $showingHotkeyPicker) {
            HotkeyPickerView(combo: appState.discordScreenShareHotkey) { combo in
                appState.setDiscordScreenShareHotkey(combo)
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        voiceStatusRow
        HStack(spacing: DesignToken.Spacing.small) {
            controlButton(title: "Mute", symbol: "mic.fill", isActive: store.voice.selfMute) {
                Task { await store.toggleMute() }
            }
            controlButton(title: "Deafen", symbol: "headphones", isActive: store.voice.selfDeaf) {
                Task { await store.toggleDeafen() }
            }
            screenShareButton
            joinLeaveButton
        }
    }

    private var voiceStatusRow: some View {
        HStack(spacing: DesignToken.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.voice.isConnected ? (store.voice.channelName ?? "Voice Channel") : "Not connected")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if store.voice.isConnected {
                    Text("\(store.voice.participants.count) in voice")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.voice.isConnected {
                HStack(spacing: -6) {
                    ForEach(store.voice.participants.prefix(4)) { participant in
                        Text(String(participant.username.prefix(2)).uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.controlDeckTint(named: definition.tintName), in: Circle())
                            .overlay(Circle().strokeBorder(DesignToken.Color.card, lineWidth: 1.5))
                    }
                }
            }
        }
    }

    private func controlButton(title: String, symbol: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? DesignToken.Color.destructive : .primary)
        .glassSurface(
            .interactive,
            cornerRadius: DesignToken.Radius.control,
            tint: (isActive ? DesignToken.Color.destructive : DesignToken.Color.accent).opacity(isActive ? 0.22 : 0.1),
            interactive: true
        )
    }

    private var screenShareButton: some View {
        Button {
            if appState.discordScreenShareHotkey == nil {
                showingHotkeyPicker = true
            } else {
                Task { await appState.triggerDiscordScreenShareHotkey() }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "rectangle.inset.filled.badge.record")
                Text("Share").font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.cyan.opacity(0.14), interactive: true)
        .onLongPressGesture { showingHotkeyPicker = true }
        .accessibilityHint("Double tap to trigger. Touch and hold to change the hotkey.")
    }

    @ViewBuilder
    private var joinLeaveButton: some View {
        if store.voice.isConnected {
            Button {
                Task { await store.leave() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "phone.down.fill")
                    Text("Leave").font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignToken.Spacing.small)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.destructive.opacity(0.2), interactive: true)
        } else {
            Menu {
                if store.guilds.isEmpty {
                    Text("No servers loaded yet")
                }
                ForEach(store.guilds) { guild in
                    Menu(guild.name) {
                        let channels = store.channelsByGuildID[guild.id] ?? []
                        if channels.isEmpty {
                            Text("No voice channels")
                        }
                        ForEach(channels) { channel in
                            Button(channel.name) {
                                Task { await store.join(channelID: channel.id) }
                            }
                        }
                    }
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "phone.fill")
                    Text("Join").font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignToken.Spacing.small)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.positive.opacity(0.18), interactive: true)
        }
    }
}

private struct MockDiscordWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        DashboardCard {
            WidgetHeader(definition: definition, availability: appState.mockRoomControl.discord.isConnected ? .available : .unavailable)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.mockRoomControl.discord.isConnected ? appState.mockRoomControl.discord.channelName : "Not connected")
                        .font(.subheadline.weight(.semibold))
                    if appState.mockRoomControl.discord.isConnected {
                        Text("\(appState.mockRoomControl.discord.participantNames.count) in voice")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: DesignToken.Spacing.small) {
                mockToggleButton(title: "Mute", symbol: "mic.fill", isActive: appState.mockRoomControl.discord.selfMute) {
                    Task { await appState.toggleMockDiscordMute() }
                }
                mockToggleButton(title: "Deafen", symbol: "headphones", isActive: appState.mockRoomControl.discord.selfDeaf) {
                    Task { await appState.toggleMockDiscordDeafen() }
                }
                Button {
                    Task { await appState.toggleMockDiscordConnection() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: appState.mockRoomControl.discord.isConnected ? "phone.down.fill" : "phone.fill")
                        Text(appState.mockRoomControl.discord.isConnected ? "Leave" : "Join").font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignToken.Spacing.small)
                }
                .buttonStyle(.plain)
                .glassSurface(
                    .interactive,
                    cornerRadius: DesignToken.Radius.control,
                    tint: (appState.mockRoomControl.discord.isConnected ? DesignToken.Color.destructive : DesignToken.Color.positive).opacity(0.18),
                    interactive: true
                )
            }
        }
    }

    private func mockToggleButton(title: String, symbol: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? DesignToken.Color.destructive : .primary)
        .glassSurface(
            .interactive,
            cornerRadius: DesignToken.Radius.control,
            tint: (isActive ? DesignToken.Color.destructive : DesignToken.Color.accent).opacity(isActive ? 0.22 : 0.1),
            interactive: true
        )
    }
}

private struct HotkeyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers: RemoteModifiers
    @State private var keyCode: Int
    let onSave: (HotkeyCombo?) -> Void

    init(combo: HotkeyCombo?, onSave: @escaping (HotkeyCombo?) -> Void) {
        _modifiers = State(initialValue: combo?.modifiers ?? [.control, .alt])
        _keyCode = State(initialValue: combo?.keyCode ?? 0x53) // "S"
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Modifiers") {
                    HStack(spacing: DesignToken.Spacing.small) {
                        ForEach(RemoteModifiers.allCases, id: \.title) { item in
                            Button {
                                if modifiers.contains(item.modifier) { modifiers.remove(item.modifier) }
                                else { modifiers.insert(item.modifier) }
                            } label: {
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, DesignToken.Spacing.medium)
                                    .padding(.vertical, DesignToken.Spacing.small)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(modifiers.contains(item.modifier) ? DesignToken.Color.accent : .primary)
                            .glassSurface(.interactive, cornerRadius: 999, tint: modifiers.contains(item.modifier) ? DesignToken.Color.accent.opacity(0.22) : nil, interactive: true)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Key") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(HotkeyCombo.availableKeys, id: \.keyCode) { key in
                            Button {
                                keyCode = key.keyCode
                            } label: {
                                Text(key.label)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(keyCode == key.keyCode ? DesignToken.Color.accent : .primary)
                            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: keyCode == key.keyCode ? DesignToken.Color.accent.opacity(0.22) : nil, interactive: true)
                        }
                    }
                    .padding(.vertical, DesignToken.Spacing.xSmall)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Text("Preview: \(HotkeyCombo(keyCode: keyCode, modifiers: modifiers).displayString)")
                        .font(.subheadline.weight(.semibold))
                } footer: {
                    Text("This should match the hotkey your Vencord plugin (or any other tool) already listens for.")
                }
            }
            .navigationTitle("Screen Share Hotkey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(HotkeyCombo(keyCode: keyCode, modifiers: modifiers))
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct GoXLRWidget: View {
    let definition: RoomWidgetDefinition
    let compact: Bool

    var body: some View {
        if definition.backend.backend == .windowsAgent {
            LiveGoXLRWidget(definition: definition, compact: compact)
        } else {
            MockGoXLRWidget(definition: definition, compact: compact)
        }
    }
}

private struct LiveGoXLRWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool
    @State private var showingMixer = false

    var body: some View {
        DashboardCard {
            WidgetHeader(
                definition: definition,
                availability: snapshot?.goXLRConnected == true ? .available : .unavailable
            )

            if snapshot?.goXLRConnected == true {
                if definition.size.presentationDensity == .expanded {
                    Label(
                        meterStore.meterStreamIsStale ? "Live meters stale" : meterStore.meterConnectionState.title,
                        systemImage: meterStore.meterStreamIsStale ? "waveform.slash" : "waveform.path.ecg"
                    )
                    .font(.caption2)
                    .foregroundStyle(meterStore.meterStreamIsStale ? .secondary : DesignToken.Color.positive)
                }
                if definition.size.presentationDensity == .compact {
                    compactMeters
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: DesignToken.Spacing.small) {
                            ForEach(visibleChannels) { channel in
                                LiveGoXLRChannelRow(
                                    store: meterStore,
                                    channel: channel,
                                    tint: Color.controlDeckTint(named: definition.tintName),
                                    showsDecibels: definition.size.presentationDensity == .expanded
                                )
                                .frame(width: compact ? 155 : 190)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                Label(
                    appState.remoteInput.pairingState.isPaired
                        ? "GoXLR Utility is unavailable on the PC"
                        : "Pair the Windows Agent to load GoXLR",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if definition.size.presentationDensity == .compact { showingMixer = true } }
        .sheet(isPresented: $showingMixer) { GoXLRMixerView(store: meterStore) }
        .task {
            await appState.remoteInput.refreshAgentSecurityState()
            await meterStore.startMetering()
            do { try await Task.sleep(for: .seconds(86_400)) } catch { }
            await meterStore.stopMetering()
        }
    }

    private var snapshot: WindowsAgentCapabilitySnapshot? {
        appState.remoteInput.capabilitySnapshot
    }

    private var meterStore: GoXLRStore { appState.remoteInput.goXLR }

    private var visibleChannels: [GoXLRChannelState] {
        let limit = switch definition.size.presentationDensity {
        case .compact: min(4, meterStore.channels.count)
        case .standard: min(6, meterStore.channels.count)
        case .expanded: meterStore.channels.count
        }
        return Array(meterStore.channels.prefix(limit))
    }

    private var compactMeters: some View {
        HStack(alignment: .bottom, spacing: DesignToken.Spacing.small) {
            ForEach(visibleChannels) { channel in
                VStack(spacing: 3) {
                    AudioLevelMeterView(
                        level: channel.displayLevel,
                        peakHold: channel.peakHold,
                        isClipping: channel.isClipping,
                        isAvailable: channel.isAvailable,
                        isStale: meterStore.meterStreamIsStale,
                        decibels: channel.decibels,
                        channelName: channel.displayName
                    )
                    .frame(width: 18, height: 52)
                    Text(String(channel.displayName.prefix(4)))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveGoXLRChannelRow: View {
    let store: GoXLRStore
    let channel: GoXLRChannelState
    let tint: Color
    let showsDecibels: Bool
    @State private var draftLevel: Double

    init(store: GoXLRStore, channel: GoXLRChannelState, tint: Color, showsDecibels: Bool) {
        self.store = store
        self.channel = channel
        self.tint = tint
        self.showsDecibels = showsDecibels
        _draftLevel = State(initialValue: channel.volume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
            HStack(alignment: .center) {
                AudioLevelMeterView(
                    level: channel.displayLevel,
                    peakHold: channel.peakHold,
                    isClipping: channel.isClipping,
                    isAvailable: channel.isAvailable,
                    isStale: store.meterStreamIsStale,
                    decibels: channel.decibels,
                    channelName: channel.displayName
                )
                .frame(width: 16, height: 54)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(draftLevel, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if showsDecibels {
                        Text(channel.decibels > -120 ? "\(channel.decibels.formatted(.number.precision(.fractionLength(1)))) dB" : "−∞ dB")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await store.toggleMute(channelId: channel.id) }
                } label: {
                    Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(channel.isMuted ? DesignToken.Color.destructive : DesignToken.Color.positive)
                }
                .buttonStyle(.plain)
                .disabled(!store.controlsAreAvailable)
            }
            Slider(value: $draftLevel, in: 0...1) { editing in
                if !editing {
                    store.updateVolumeDraft(channelId: channel.id, value: draftLevel)
                    Task { await store.setVolume(channelId: channel.id, value: draftLevel) }
                }
            }
            .tint(tint)
            .disabled(!store.controlsAreAvailable)
        }
        .padding(DesignToken.Spacing.small)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.08))
        .onChange(of: channel.volume) { _, level in
            draftLevel = level
        }
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
