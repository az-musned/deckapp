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
            if definition.backend.backend == .lgWebOS {
                LGTVWidget(definition: definition, compact: compact)
            } else {
                MockTelevisionWidget(definition: definition, compact: compact)
            }
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
                    RemoteHaptics.heavy()
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
                        RemoteHaptics.heavy()
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
            FullScreenScreenMirrorView(store: remote.screenMirror)
        }
    }

    private var watchButton: some View {
        Button {
            showFullScreenMirror = true
        } label: {
            Label("Watch", systemImage: "tv.and.mediabox.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DesignToken.Spacing.medium)
                .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.cyan.opacity(0.18), interactive: true)
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
                    RemoteHaptics.heavy()
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
        case .lgWebOS: "LG TV"
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
                    RemoteHaptics.heavy()
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
                            RemoteHaptics.heavy()
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
                            RemoteHaptics.heavy()
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
                    RemoteHaptics.heavy()
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
        Button {
            RemoteHaptics.heavy()
            action()
        } label: {
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
                    RemoteHaptics.heavy()
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
                        RemoteHaptics.heavy()
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
                        Button(source) {
                            RemoteHaptics.heavy()
                            Task { await appState.selectTelevisionSource(source) }
                        }
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
        Button {
            RemoteHaptics.heavy()
            send(command)
        } label: {
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
                RemoteHaptics.heavy()
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
    @State private var showingMappings = false

    var body: some View {
        DashboardCard {
            WidgetHeader(
                definition: definition,
                availability: snapshot?.goXLRConnected == true ? .available : .unavailable
            )

            if snapshot?.goXLRConnected == true {
                if definition.size.presentationDensity != .compact {
                    HStack(spacing: DesignToken.Spacing.small) {
                        Label(
                            meterStore.meterStreamIsStale ? "Meters need attention" : "Live meters",
                            systemImage: meterStore.meterStreamIsStale ? "waveform.slash" : "waveform.path.ecg"
                        )
                        .foregroundStyle(meterStore.meterStreamIsStale ? .secondary : DesignToken.Color.positive)
                        Spacer()
                        Button("Map Meters", systemImage: "point.3.connected.trianglepath.dotted") {
                            RemoteHaptics.heavy()
                            showingMappings = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .font(.caption2.weight(.semibold))
                }
                if definition.size.presentationDensity == .compact {
                    compactMeters
                } else {
                    faderBank
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
        .sheet(isPresented: $showingMappings) { GoXLREndpointMappingView(store: meterStore) }
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
        let selectedIDs = definition.audioMixerChannelIDs ?? RoomWidgetDefinition.defaultGoXLRChannelIDs
        let selected = GoXLRChannelSelectionResolver.resolve(
            selectedIDs: selectedIDs,
            from: meterStore.channels
        )
        return definition.size.presentationDensity == .compact ? Array(selected.prefix(4)) : selected
    }

    @ViewBuilder
    private var faderBank: some View {
        if visibleChannels.count <= 4 {
            HStack(spacing: DesignToken.Spacing.small) {
                ForEach(visibleChannels) { channel in
                    LiveGoXLRVerticalFader(
                        store: meterStore,
                        channel: channel,
                        tint: Color.controlDeckTint(named: definition.tintName)
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: DesignToken.Spacing.small) {
                    ForEach(visibleChannels) { channel in
                        LiveGoXLRVerticalFader(
                            store: meterStore,
                            channel: channel,
                            tint: Color.controlDeckTint(named: definition.tintName)
                        )
                        .frame(width: compact ? 66 : 78)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var compactMeters: some View {
        HStack(alignment: .bottom, spacing: DesignToken.Spacing.small) {
            ForEach(visibleChannels) { channel in
                VStack(spacing: 3) {
                    AudioLevelMeterView(
                        level: channel.volumeScaledDisplayLevel,
                        peakHold: channel.volumeScaledPeakHold,
                        isClipping: channel.isClipping,
                        isAvailable: channel.isAvailable,
                        isStale: meterStore.meterStreamIsStale,
                        decibels: channel.volumeScaledDecibels,
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

private struct LiveGoXLRVerticalFader: View {
    let store: GoXLRStore
    let channel: GoXLRChannelState
    let tint: Color
    @State private var draftLevel: Double
    @State private var isInteracting = false

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    init(store: GoXLRStore, channel: GoXLRChannelState, tint: Color) {
        self.store = store
        self.channel = channel
        self.tint = tint
        _draftLevel = State(initialValue: channel.volume)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(channel.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 6) {
                AudioLevelMeterView(
                    level: channel.volumeScaledDisplayLevel,
                    peakHold: channel.volumeScaledPeakHold,
                    isClipping: channel.isClipping,
                    isAvailable: channel.isAvailable,
                    isStale: store.meterStreamIsStale,
                    decibels: channel.volumeScaledDecibels,
                    channelName: channel.displayName
                )
                .frame(width: isPad ? 12 : 10, height: isPad ? 116 : 92)

                GoXLRVerticalSlider(
                    value: Binding(
                        get: { draftLevel },
                        set: {
                            draftLevel = $0
                            store.updateVolumeDraft(channelId: channel.id, value: $0)
                        }
                    ),
                    tint: tint,
                    onEditingChanged: { editing in
                        isInteracting = editing
                        if editing { store.beginVolumeInteraction(channelId: channel.id) }
                    },
                    commit: {
                        Task { await store.commitVolumeInteraction(channelId: channel.id, value: draftLevel) }
                    }
                )
                .frame(width: isPad ? 32 : 28, height: isPad ? 122 : 96)
                .disabled(!store.controlsAreAvailable || store.channel(for: channel.id) == nil)
            }

            Button {
                RemoteHaptics.heavy()
                Task { await store.toggleMute(channelId: channel.id) }
            } label: {
                Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(channel.isMuted ? DesignToken.Color.destructive : .secondary)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity)
                    .glassSurface(
                        .interactive,
                        cornerRadius: 8,
                        tint: channel.isMuted ? DesignToken.Color.destructive.opacity(0.18) : tint.opacity(0.1),
                        interactive: true
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!store.controlsAreAvailable || store.channel(for: channel.id) == nil)
            .accessibilityLabel("\(channel.displayName) \(channel.isMuted ? "muted" : "not muted")")
            .accessibilityHint("Double tap to toggle mute")
        }
        .onChange(of: channel.volume) { _, level in
            if !isInteracting { draftLevel = level }
        }
    }
}

private struct GoXLRVerticalSlider: View {
    @Binding var value: Double
    let tint: Color
    let onEditingChanged: (Bool) -> Void
    let commit: () -> Void
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let knobHeight = 12.0
            let travel = max(1, geometry.size.height - knobHeight)
            let normalizedValue = min(max(value.isFinite ? value : 0, 0), 1)
            let y = (1 - normalizedValue) * travel

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.black.opacity(0.28))
                    .frame(width: 5)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(tint.opacity(0.55))
                    .frame(width: 5, height: max(3, normalizedValue * travel))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.25), lineWidth: 1))
                    .shadow(color: tint.opacity(0.35), radius: 4)
                    .frame(width: 24, height: knobHeight)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = min(max(1.0 - Double(gesture.location.y / geometry.size.height), 0), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                        commit()
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: return
            }
            onEditingChanged(true)
            onEditingChanged(false)
            commit()
        }
    }
}

private struct MockGoXLRWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        DashboardCard {
            WidgetHeader(
                definition: definition,
                availability: appState.mockRoomControl.goXLR.isConnected ? .available : .unavailable
            )

            if definition.size.presentationDensity == .compact {
                HStack(alignment: .bottom, spacing: DesignToken.Spacing.small) {
                    ForEach(visibleChannelIndices.prefix(4), id: \.self) { index in
                        VStack(spacing: 3) {
                            mockMeter(index: index).frame(width: 18, height: 52)
                            Text(String(appState.mockRoomControl.goXLR.channels[index].name.prefix(4)))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else if visibleChannelIndices.count <= 4 {
                HStack(spacing: DesignToken.Spacing.small) {
                    ForEach(visibleChannelIndices, id: \.self) { index in
                        mixerChannel(index: index).frame(maxWidth: .infinity)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: DesignToken.Spacing.small) {
                        ForEach(visibleChannelIndices, id: \.self) { index in
                            mixerChannel(index: index).frame(width: compact ? 66 : 78)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var visibleChannelIndices: [Int] {
        let selectedIDs = definition.audioMixerChannelIDs ?? RoomWidgetDefinition.defaultGoXLRChannelIDs
        return selectedIDs.compactMap { selectedID in
            appState.mockRoomControl.goXLR.channels.firstIndex {
                $0.id.caseInsensitiveCompare(selectedID) == .orderedSame
            }
        }
    }

    private func mixerChannel(index: Int) -> some View {
        let channel = appState.mockRoomControl.goXLR.channels[index]
        return VStack(spacing: 5) {
            Text(channel.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                mockMeter(index: index).frame(width: isPad ? 12 : 10, height: isPad ? 116 : 92)
                GoXLRVerticalSlider(
                    value: Binding(
                        get: { appState.mockRoomControl.goXLR.channels[index].level },
                        set: { appState.mockRoomControl.goXLR.channels[index].level = $0 }
                    ),
                    tint: Color.controlDeckTint(named: definition.tintName),
                    onEditingChanged: { _ in }
                ) {
                    Task { await appState.confirmMockControl("GoXLR channel level") }
                }
                .frame(width: isPad ? 32 : 28, height: isPad ? 122 : 96)
            }
            Button {
                RemoteHaptics.heavy()
                appState.mockRoomControl.goXLR.channels[index].isMuted.toggle()
                Task { await appState.confirmMockControl("GoXLR mute") }
            } label: {
                Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(channel.isMuted ? DesignToken.Color.destructive : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.plain)
            .glassSurface(.subtle, cornerRadius: 8, tint: channel.isMuted ? DesignToken.Color.destructive.opacity(0.12) : Color.clear)
        }
    }

    private func mockMeter(index: Int) -> some View {
        let channel = appState.mockRoomControl.goXLR.channels[index]
        return AudioLevelMeterView(
            level: channel.level * 0.82,
            peakHold: channel.level * 0.9,
            isClipping: false,
            isAvailable: appState.mockRoomControl.goXLR.isConnected,
            isStale: false,
            decibels: -60 + (channel.level * 60),
            channelName: channel.name
        )
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
