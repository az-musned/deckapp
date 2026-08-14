import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showCompanionPressConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Color scheme", selection: colorSchemeBinding) {
                        Text("System").tag(Optional<ColorScheme>.none)
                        Text("Light").tag(Optional(ColorScheme.light))
                        Text("Dark").tag(Optional(ColorScheme.dark))
                    }
                }

                Section("Home Assistant") {
                    TextField("Local URL", text: Binding(get: { appState.homeAssistantConfiguration.localURL }, set: { appState.homeAssistantConfiguration.localURL = $0 }))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Remote HTTPS URL", text: Binding(get: { appState.homeAssistantConfiguration.remoteURL }, set: { appState.homeAssistantConfiguration.remoteURL = $0 }))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Long-lived access token", text: Binding(get: { appState.homeAssistantToken }, set: { appState.homeAssistantToken = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Active route") {
                        Text(homeAssistantStatusTitle).foregroundStyle(homeAssistantStatusColor)
                    }
                    LabeledContent("Live updates") {
                        Text(homeAssistantWebSocketTitle)
                            .foregroundStyle(appState.homeAssistantWebSocketState == .subscribed ? DesignToken.Color.positive : .secondary)
                    }
                    Button {
                        Task { await appState.saveAndTestHomeAssistant() }
                    } label: {
                        Label("Save and Test Connection", systemImage: "checkmark.shield")
                    }
                    .disabled(appState.homeAssistantToken.isEmpty || appState.homeAssistantState == .testing)
                    if !appState.homeAssistantEntities.isEmpty {
                        Text("Discovered \(appState.homeAssistantEntities.count) entity states.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Credentials will be stored in Keychain. TLS certificate validation will always remain enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !appState.homeAssistantEntities.isEmpty {
                    Section("Home Assistant Entity Mapping") {
                        if !appState.homeAssistantLightEntities.isEmpty {
                            Picker("Room Lights", selection: roomLightEntityBinding) {
                                Text("Use mock light").tag("")
                                ForEach(appState.homeAssistantLightEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantClimateEntities.isEmpty {
                            Picker("Bedroom Climate", selection: climateEntityBinding) {
                                Text("Use mock climate").tag("")
                                ForEach(appState.homeAssistantClimateEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantMediaPlayerEntities.isEmpty {
                            Picker("LG TV", selection: televisionEntityBinding) {
                                Text("Use mock TV").tag("")
                                ForEach(appState.homeAssistantMediaPlayerEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantRemoteEntities.isEmpty {
                            Picker("LG TV Remote", selection: televisionRemoteEntityBinding) {
                                Text("No directional remote").tag("")
                                ForEach(appState.homeAssistantRemoteEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantSwitchEntities.isEmpty {
                            Picker("PC Smart Plug", selection: pcPowerEntityBinding) {
                                Text("Use mock smart plug").tag("")
                                ForEach(appState.homeAssistantSwitchEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantBinarySensorEntities.isEmpty {
                            Picker("PC Online Sensor", selection: pcOnlineSensorEntityBinding) {
                                Text("No online-state confirmation").tag("")
                                ForEach(appState.homeAssistantBinarySensorEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        if !appState.homeAssistantScriptEntities.isEmpty {
                            Picker("Launch Game Script", selection: launchGameScriptBinding) {
                                Text("Use Companion mapping").tag("")
                                ForEach(appState.homeAssistantScriptEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                            Picker("Sleep PC Script", selection: sleepPCScriptBinding) {
                                Text("Use Companion mapping").tag("")
                                ForEach(appState.homeAssistantScriptEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                            Picker("Shut Down PC Script", selection: shutdownPCScriptBinding) {
                                Text("Use Companion mapping").tag("")
                                ForEach(appState.homeAssistantScriptEntities) { entity in
                                    Text(appState.friendlyName(for: entity)).tag(entity.entityID)
                                }
                            }
                        }
                        Text("Each mapped widget uses capabilities and live state reported by Home Assistant. Unmapped widgets stay in mock mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Govee") {
                    SecureField("Govee API key", text: Binding(
                        get: { appState.goveeAPIKey },
                        set: { appState.goveeAPIKey = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    LabeledContent("Status") {
                        HStack(spacing: DesignToken.Spacing.xSmall) {
                            if appState.goveeStatus == .discovering {
                                ProgressView().controlSize(.small)
                            }
                            Text(appState.goveeStatus.title)
                                .foregroundStyle(goveeStatusColor)
                        }
                    }

                    if case .failed(let message) = appState.goveeStatus {
                        LabeledContent("Reason") {
                            Text(message)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(DesignToken.Color.destructive)
                        }
                        .font(.caption)
                    }

                    Button {
                        Task { await appState.saveAndDiscoverGovee() }
                    } label: {
                        Label("Save and Discover Devices", systemImage: "lightbulb.led.fill")
                    }
                    .disabled(appState.goveeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.goveeStatus == .discovering)

                    if !appState.goveeDevices.isEmpty {
                        ForEach(appState.goveeDevices) { device in
                            LabeledContent {
                                Text("\(device.actionableCapabilities.count) controls")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label(device.deviceName, systemImage: "lightbulb.led")
                            }
                        }
                    }

                    if !appState.goveeAPIKey.isEmpty {
                        Button("Remove Govee API Key", role: .destructive) {
                            appState.forgetGoveeAPIKey()
                        }
                    }

                    Text("The key is stored only in Keychain and sent only to Govee's official HTTPS API. It is never written to dashboard data or logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("PC address, for example 100.x.y.z:8000", text: companionAddressBinding)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            Task { await appState.testCompanionConnection() }
                        }

                    LabeledContent("Status") {
                        HStack(spacing: DesignToken.Spacing.xSmall) {
                            if appState.companionStatus == .testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Circle()
                                    .fill(companionStatusColor)
                                    .frame(width: 8, height: 8)
                            }
                            Text(appState.companionStatus.title)
                                .foregroundStyle(companionStatusColor)
                        }
                        .font(.subheadline.weight(.semibold))
                    }

                    if case .failed(let message) = appState.companionStatus {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(DesignToken.Color.destructive)
                    }

                    Button {
                        Task { await appState.testCompanionConnection() }
                    } label: {
                        Label("Connect and Test", systemImage: "network")
                    }
                    .disabled(
                        appState.companionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || appState.companionStatus == .testing
                    )

                    Text("Companion is allowed only over your home LAN or a private VPN. Use the PC's Tailscale IP for the same macro address on home Wi-Fi and 5G. DeckApp rejects public addresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Bitfocus Companion")
                } footer: {
                    Text("Enable Companion’s HTTP API and permit port 8000 only on the Tailscale interface. Never forward this port on your router.")
                }

                Section {
                    Stepper(value: companionPageBinding, in: 1...99) {
                        LabeledContent("Page") {
                            Text("\(appState.companionButtonMapping.page)")
                                .monospacedDigit()
                        }
                    }

                    Stepper(value: companionRowBinding, in: 0...99) {
                        LabeledContent("Row") {
                            Text("\(appState.companionButtonMapping.row)")
                                .monospacedDigit()
                        }
                    }

                    Stepper(value: companionColumnBinding, in: 0...99) {
                        LabeledContent("Column") {
                            Text("\(appState.companionButtonMapping.column)")
                                .monospacedDigit()
                        }
                    }

                    Button {
                        showCompanionPressConfirmation = true
                    } label: {
                        Label("Press Test Button", systemImage: "rectangle.and.hand.point.up.left")
                    }
                    .disabled(!canTestCompanionButton)

                    if let message = appState.companionButtonTestStatus.message {
                        HStack(alignment: .top, spacing: DesignToken.Spacing.small) {
                            if appState.companionButtonTestStatus == .sending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: companionTestSymbol)
                                    .foregroundStyle(companionTestColor)
                            }
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(companionTestColor)
                        }
                    }

                    LabeledContent("Launch Game") {
                        Text(mappingDescription(for: .launchGame))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Sleep PC") {
                        Text(mappingDescription(for: .sleepPC))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Shut Down PC") {
                        Text(mappingDescription(for: .shutdownPC))
                            .foregroundStyle(.secondary)
                    }

                    Menu {
                        Button("Launch Game") {
                            appState.assignTestedCompanionButton(to: .launchGame)
                        }
                        Button("Sleep PC") {
                            appState.assignTestedCompanionButton(to: .sleepPC)
                        }
                        Button("Shut Down PC") {
                            appState.assignTestedCompanionButton(to: .shutdownPC)
                        }
                    } label: {
                        Label("Assign Tested Button", systemImage: "link")
                    }
                    .disabled(!canAssignCompanionButton)
                } header: {
                    Text("Companion Button Test")
                } footer: {
                    Text("Rows and columns are zero-based. A successful HTTP response means Companion accepted the press; it does not confirm that the PC action completed.")
                }

                Section("PC command behavior") {
                    LabeledContent("Wake workflow") {
                        Text(appState.hasConfiguredPCWakeWorkflow ? "Ready" : "Needs wake method + sensor")
                            .foregroundStyle(appState.hasConfiguredPCWakeWorkflow ? DesignToken.Color.positive : .secondary)
                    }
                    LabeledContent("Queued-action timeout") {
                        Text("\(Int(appState.pcActionQueueTimeoutSeconds)) seconds")
                    }
                    Slider(value: pcQueueTimeoutBinding, in: 10...120, step: 5)
                    Toggle("Wake PC before queued actions", isOn: wakeBeforeQueuedActionsBinding)
                    TextField("Wake-on-LAN MAC address", text: wakeOnLANMACBinding)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Broadcast address (optional)", text: wakeOnLANBroadcastBinding)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    if !appState.wakeOnLANConfiguration.macAddress.isEmpty,
                       appState.wakeOnLANConfiguration.normalizedMACAddress == nil {
                        Label("Enter six hexadecimal pairs, for example 00:11:22:33:44:55.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DesignToken.Color.warning)
                    }
                    Button("Save PC Wake Settings") { appState.savePCWakeConfiguration() }
                    Toggle("Confirm destructive commands", isOn: .constant(true))
                }

                Section("Integrations") {
                    SettingsPlaceholderRow(title: "Gree", detail: "Through Home Assistant", symbol: "snowflake")
                    SettingsPlaceholderRow(title: "Smart Life", detail: "Through Home Assistant", symbol: "house")
                    SettingsPlaceholderRow(title: "TV control", detail: "Through Home Assistant", symbol: "tv")
                }

                Section("Integration Health") {
                    IntegrationHealthView()
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .confirmationDialog(
                "Press this Companion button?",
                isPresented: $showCompanionPressConfirmation,
                titleVisibility: .visible
            ) {
                Button("Press Page \(appState.companionButtonMapping.page), Row \(appState.companionButtonMapping.row), Column \(appState.companionButtonMapping.column)") {
                    Task { await appState.pressCompanionTestButton() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("DeckApp cannot know whether the mapped Companion button is destructive. Check its actions on the PC before continuing.")
            }
        }
    }

    private var colorSchemeBinding: Binding<ColorScheme?> {
        Binding(get: { appState.preferredColorScheme }, set: { appState.preferredColorScheme = $0 })
    }

    private var homeAssistantStatusTitle: String {
        switch appState.homeAssistantState {
        case .notConfigured: "Not configured"
        case .testing: "Testing…"
        case .connected(let route, let latency): "\(route.rawValue) · \(latency) ms"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline"
        }
    }

    private var homeAssistantStatusColor: Color {
        switch appState.homeAssistantState {
        case .connected: DesignToken.Color.positive
        case .testing, .reconnecting: DesignToken.Color.warning
        case .offline: DesignToken.Color.destructive
        case .notConfigured: .secondary
        }
    }

    private var homeAssistantWebSocketTitle: String {
        switch appState.homeAssistantWebSocketState {
        case .disconnected: "Disconnected"
        case .authenticating: "Authenticating…"
        case .subscribed: "Subscribed"
        case .reconnecting: "Reconnecting…"
        }
    }

    private var roomLightEntityBinding: Binding<String> {
        Binding(
            get: { appState.homeAssistantLightEntityID },
            set: { appState.mapRoomLightEntity($0) }
        )
    }

    private var climateEntityBinding: Binding<String> {
        Binding(get: { appState.homeAssistantClimateEntityID }, set: { appState.mapHomeAssistantEntity($0, to: .climate) })
    }

    private var televisionEntityBinding: Binding<String> {
        Binding(get: { appState.homeAssistantTelevisionEntityID }, set: { appState.mapHomeAssistantEntity($0, to: .television) })
    }

    private var televisionRemoteEntityBinding: Binding<String> {
        Binding(get: { appState.homeAssistantTelevisionRemoteEntityID }, set: { appState.mapTelevisionRemoteEntity($0) })
    }

    private var pcPowerEntityBinding: Binding<String> {
        Binding(get: { appState.homeAssistantPCPowerEntityID }, set: { appState.mapHomeAssistantEntity($0, to: .pcPower) })
    }

    private var pcOnlineSensorEntityBinding: Binding<String> {
        Binding(get: { appState.homeAssistantPCOnlineSensorEntityID }, set: { appState.mapPCOnlineSensorEntity($0) })
    }

    private var launchGameScriptBinding: Binding<String> {
        Binding(get: { appState.homeAssistantLaunchGameScriptEntityID }, set: { appState.mapPCScriptEntity($0, for: .launchGame) })
    }

    private var sleepPCScriptBinding: Binding<String> {
        Binding(get: { appState.homeAssistantSleepPCScriptEntityID }, set: { appState.mapPCScriptEntity($0, for: .sleepPC) })
    }

    private var shutdownPCScriptBinding: Binding<String> {
        Binding(get: { appState.homeAssistantShutdownPCScriptEntityID }, set: { appState.mapPCScriptEntity($0, for: .shutdownPC) })
    }

    private var pcQueueTimeoutBinding: Binding<Double> {
        Binding(get: { appState.pcActionQueueTimeoutSeconds }, set: { appState.pcActionQueueTimeoutSeconds = $0 })
    }

    private var wakeBeforeQueuedActionsBinding: Binding<Bool> {
        Binding(get: { appState.wakePCBeforeQueuedActions }, set: { appState.wakePCBeforeQueuedActions = $0 })
    }

    private var wakeOnLANMACBinding: Binding<String> {
        Binding(get: { appState.wakeOnLANConfiguration.macAddress }, set: { appState.wakeOnLANConfiguration.macAddress = $0 })
    }

    private var wakeOnLANBroadcastBinding: Binding<String> {
        Binding(get: { appState.wakeOnLANConfiguration.broadcastAddress }, set: { appState.wakeOnLANConfiguration.broadcastAddress = $0 })
    }

    private var companionAddressBinding: Binding<String> {
        Binding(get: { appState.companionAddress }, set: { appState.companionAddress = $0 })
    }

    private var companionStatusColor: Color {
        switch appState.companionStatus {
        case .connected: DesignToken.Color.positive
        case .testing: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .notConfigured: .secondary
        }
    }

    private var goveeStatusColor: Color {
        switch appState.goveeStatus {
        case .connected: DesignToken.Color.positive
        case .discovering: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .notConfigured: .secondary
        }
    }

    private var companionPageBinding: Binding<Int> {
        Binding(get: { appState.companionButtonMapping.page }, set: { appState.companionButtonMapping.page = $0 })
    }

    private var companionRowBinding: Binding<Int> {
        Binding(get: { appState.companionButtonMapping.row }, set: { appState.companionButtonMapping.row = $0 })
    }

    private var companionColumnBinding: Binding<Int> {
        Binding(get: { appState.companionButtonMapping.column }, set: { appState.companionButtonMapping.column = $0 })
    }

    private var canTestCompanionButton: Bool {
        guard case .connected = appState.companionStatus else { return false }
        return appState.companionButtonTestStatus != .sending
    }

    private var companionTestColor: Color {
        switch appState.companionButtonTestStatus {
        case .accepted: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .sending: .secondary
        case .idle: .secondary
        }
    }

    private var companionTestSymbol: String {
        switch appState.companionButtonTestStatus {
        case .accepted: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle, .sending: "circle"
        }
    }

    private var canAssignCompanionButton: Bool {
        if case .accepted = appState.companionButtonTestStatus {
            true
        } else {
            false
        }
    }

    private func mappingDescription(for action: CompanionDashboardAction) -> String {
        appState.companionDashboardMappings[action]?.locationDescription ?? "Not mapped"
    }
}

private struct SettingsPlaceholderRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
