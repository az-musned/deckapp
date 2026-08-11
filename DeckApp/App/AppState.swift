import Observation
import SwiftUI
import SwiftData
import UIKit

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection = .dashboard
    var dashboard: RoomDashboard = .preview
    var roomControlTemplate: RoomControlTemplate = .roomControl
    var mockRoomControl: MockRoomControlState = .preview
    var pendingCommand: CommandExecution?
    var preferredColorScheme: ColorScheme? = .dark
    var companionAddress: String
    var companionStatus: CompanionConnectionStatus = .notConfigured
    var companionButtonMapping: CompanionButtonMapping
    var companionButtonTestStatus: CompanionButtonTestStatus = .idle
    var companionDashboardMappings: [CompanionDashboardAction: CompanionButtonMapping]
    var companionMappingTestStatuses: [CompanionDashboardAction: CompanionButtonTestStatus] = [:]
    var goveeAPIKey = ""
    var goveeStatus: GoveeConnectionStatus = .notConfigured
    var goveeDevices: [GoveeDevice] = []
    var goveeControlValues: [String: [String: GoveeValue]] = [:]
    @ObservationIgnored private var goveeStateRefreshDates: [String: Date] = [:]
    var controlDeckItems: [ControlDeckItem]
    var homeAssistantConfiguration: HomeAssistantConfiguration
    var homeAssistantToken = ""
    var homeAssistantState: HomeAssistantConnectionState = .notConfigured
    var homeAssistantWebSocketState: HAWebSocketState = .disconnected
    var homeAssistantEntities: [HAEntityState] = []
    var homeAssistantLightEntityID: String
    var homeAssistantClimateEntityID: String
    var homeAssistantTelevisionEntityID: String
    var homeAssistantTelevisionRemoteEntityID: String
    var homeAssistantPCPowerEntityID: String
    var homeAssistantPCOnlineSensorEntityID: String
    var homeAssistantLaunchGameScriptEntityID: String
    var homeAssistantSleepPCScriptEntityID: String
    var wakeOnLANConfiguration: WakeOnLANConfiguration
    var pcActionQueueTimeoutSeconds: Double
    var wakePCBeforeQueuedActions: Bool
    var favoriteSceneActionIDs: Set<String>
    var sceneOrchestrationExecution: SceneOrchestrationExecution?
    var discordScreenShareHotkey: HotkeyCombo?
    var pcTVInputID: String? {
        didSet {
            if let pcTVInputID {
                UserDefaults.standard.set(pcTVInputID, forKey: "remote.pcTVInputID.v1")
            } else {
                UserDefaults.standard.removeObject(forKey: "remote.pcTVInputID.v1")
            }
        }
    }
    let remoteInput: RemoteInputController
    let lgTV: LGTVStore
    let sleepTimer = SleepTimerController()

    let dashboardService: any DashboardService
    let commandService: any CommandService
    private let companionService: any CompanionServing
    private let companionSettings: CompanionSettingsStore
    private let goveeService: any GoveeServing
    private var modelContext: ModelContext?
    private var layoutRecord: DashboardLayoutRecord?
    private let homeAssistantService: any HomeAssistantServiceProtocol
    private let keychain = KeychainSecretStore(service: "com.example.DeckApp.home-assistant")
    private let goveeKeychain = KeychainSecretStore(service: "com.example.DeckApp.govee")
    private let homeAssistantWebSocket = HomeAssistantWebSocketClient()
    private let networkPathObserver = NetworkPathObserver()
    private var activeHomeAssistantURL: URL?
    private var reconnectTask: Task<Void, Never>?
    private var pendingHomeAssistantLightConfirmation: UUID?
    private var pendingHomeAssistantConfirmationEntityID: String?

    init(
        dashboardService: any DashboardService = MockDashboardService(),
        commandService: any CommandService = MockCommandService(),
        companionService: any CompanionServing = CompanionClient(),
        companionSettings: CompanionSettingsStore = CompanionSettingsStore(),
        goveeService: any GoveeServing = GoveeClient(),
        remoteInput: RemoteInputController = RemoteInputController(),
        lgTV: LGTVStore = LGTVStore(),
        homeAssistantService: any HomeAssistantServiceProtocol = HomeAssistantClient()
    ) {
        self.dashboardService = dashboardService
        self.commandService = commandService
        self.companionService = companionService
        self.companionSettings = companionSettings
        self.goveeService = goveeService
        self.remoteInput = remoteInput
        self.lgTV = lgTV
        self.homeAssistantService = homeAssistantService
        homeAssistantConfiguration = (try? JSONDecoder().decode(HomeAssistantConfiguration.self, from: UserDefaults.standard.data(forKey: "homeAssistant.configuration") ?? Data())) ?? HomeAssistantConfiguration()
        homeAssistantToken = (try? keychain.load(account: "long-lived-access-token")) ?? ""
        goveeAPIKey = (try? goveeKeychain.load(account: "api-key")) ?? ""
        homeAssistantLightEntityID = UserDefaults.standard.string(forKey: "homeAssistant.roomLightEntityID") ?? ""
        homeAssistantClimateEntityID = UserDefaults.standard.string(forKey: "homeAssistant.climateEntityID") ?? ""
        homeAssistantTelevisionEntityID = UserDefaults.standard.string(forKey: "homeAssistant.televisionEntityID") ?? ""
        homeAssistantTelevisionRemoteEntityID = UserDefaults.standard.string(forKey: "homeAssistant.televisionRemoteEntityID") ?? ""
        homeAssistantPCPowerEntityID = UserDefaults.standard.string(forKey: "homeAssistant.pcPowerEntityID") ?? ""
        homeAssistantPCOnlineSensorEntityID = UserDefaults.standard.string(forKey: "homeAssistant.pcOnlineSensorEntityID") ?? ""
        homeAssistantLaunchGameScriptEntityID = UserDefaults.standard.string(forKey: "homeAssistant.launchGameScriptEntityID") ?? ""
        homeAssistantSleepPCScriptEntityID = UserDefaults.standard.string(forKey: "homeAssistant.sleepPCScriptEntityID") ?? ""
        wakeOnLANConfiguration = (try? JSONDecoder().decode(WakeOnLANConfiguration.self, from: UserDefaults.standard.data(forKey: "homeAssistant.wakeOnLAN") ?? Data())) ?? WakeOnLANConfiguration()
        pcActionQueueTimeoutSeconds = max(10, UserDefaults.standard.double(forKey: "pcAction.queueTimeoutSeconds"))
        if UserDefaults.standard.object(forKey: "pcAction.queueTimeoutSeconds") == nil { pcActionQueueTimeoutSeconds = 45 }
        wakePCBeforeQueuedActions = UserDefaults.standard.object(forKey: "pcAction.wakeBeforeQueuedActions") as? Bool ?? true
        favoriteSceneActionIDs = Set(UserDefaults.standard.stringArray(forKey: "homeAssistant.favoriteSceneActions") ?? [])
        sceneOrchestrationExecution = nil
        discordScreenShareHotkey = (try? JSONDecoder().decode(HotkeyCombo.self, from: UserDefaults.standard.data(forKey: "discord.screenShareHotkey") ?? Data()))
        pcTVInputID = UserDefaults.standard.string(forKey: "remote.pcTVInputID.v1")
        let savedButtonMapping = companionSettings.loadButtonMapping()
        let savedDashboardMappings = companionSettings.loadDashboardMappings()
        companionAddress = companionSettings.loadAddress()
        companionButtonMapping = savedButtonMapping
        companionDashboardMappings = savedDashboardMappings
        controlDeckItems = companionSettings.loadControlDeckItems() ?? ControlDeckItem.initialItems(
            launchMapping: savedDashboardMappings[.launchGame],
            sleepMapping: savedDashboardMappings[.sleepPC]
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-showRemote") {
            selectedSection = .remote
        } else if ProcessInfo.processInfo.arguments.contains("-showTV") {
            selectedSection = .remote
            UserDefaults.standard.set(RemoteTarget.tv.rawValue, forKey: "remote.target.v1")
        } else if ProcessInfo.processInfo.arguments.contains("-showScenes") {
            selectedSection = .scenes
        }
        #endif
        sleepTimer.attach(appState: self)
    }

    func refresh() async {
        dashboard = await dashboardService.dashboard()
        await connectCompanionIfConfigured()
        if !goveeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await saveAndDiscoverGovee()
        }
    }

    func saveAndDiscoverGovee() async {
        goveeStatus = .discovering
        let normalizedKey = goveeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !normalizedKey.isEmpty else { throw GoveeClientError.missingAPIKey }
            try goveeKeychain.save(normalizedKey, account: "api-key")
            let devices = try await goveeService.discoverDevices(apiKey: normalizedKey)
            goveeAPIKey = normalizedKey
            goveeDevices = devices.sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
            goveeStatus = .connected(deviceCount: devices.count)
        } catch {
            goveeDevices = []
            goveeStatus = .failed(error.localizedDescription)
        }
    }

    func forgetGoveeAPIKey() {
        try? goveeKeychain.delete(account: "api-key")
        goveeAPIKey = ""
        goveeDevices = []
        goveeControlValues = [:]
        goveeStateRefreshDates = [:]
        goveeStatus = .notConfigured
    }

    func goveeDevice(for identifier: String) -> GoveeDevice? {
        goveeDevices.first { $0.id == identifier }
    }

    func goveeValue(deviceID: String, capabilityID: String) -> GoveeValue? {
        goveeControlValues[deviceID]?[capabilityID]
    }

    func refreshGoveeState(deviceID: String) async {
        guard let device = goveeDevice(for: deviceID) else { return }
        if let refreshedAt = goveeStateRefreshDates[device.id],
           Date.now.timeIntervalSince(refreshedAt) < 5,
           goveeControlValues[device.id] != nil {
            return
        }
        goveeStateRefreshDates[device.id] = .now
        do {
            let key = try goveeKeychain.load(account: "api-key") ?? ""
            goveeControlValues[device.id] = try await goveeService.state(for: device, apiKey: key)
        } catch {
            if goveeControlValues[device.id] == nil {
                goveeControlValues[device.id] = [:]
            }
        }
    }

    func setGoveeCapability(deviceID: String, capabilityID: String, value: GoveeValue) async {
        guard let device = goveeDevice(for: deviceID),
              let capability = device.actionableCapabilities.first(where: { $0.id == capabilityID }) else { return }
        let previousValue = goveeControlValues[device.id]?[capability.id]
        goveeControlValues[device.id, default: [:]][capability.id] = value
        let action = GoveeDeviceAction(
            sku: device.sku,
            device: device.device,
            deviceName: device.deviceName,
            capabilityType: capability.type,
            capabilityInstance: capability.instance,
            value: value
        )
        if !(await performGoveeAction(action, title: "\(device.deviceName) \(capability.title)")) {
            goveeControlValues[device.id, default: [:]][capability.id] = previousValue
        }
    }

    func saveAndTestHomeAssistant() async {
        homeAssistantState = .testing
        do {
            try keychain.save(homeAssistantToken, account: "long-lived-access-token")
            if let data = try? JSONEncoder().encode(homeAssistantConfiguration) { UserDefaults.standard.set(data, forKey: "homeAssistant.configuration") }
            let candidates: [(String, ConnectionRoute)] = [(homeAssistantConfiguration.localURL, .local), (homeAssistantConfiguration.remoteURL, .remote)]
            var lastError: Error?
            for (address, route) in candidates where !address.isEmpty {
                do {
                    guard let url = URL(string: address), route != .remote || url.scheme == "https" else { throw HAClientError.invalidResponse }
                    let latency = try await homeAssistantService.testConnection(baseURL: url, token: homeAssistantToken)
                    homeAssistantEntities = try await homeAssistantService.fetchStates(baseURL: url, token: homeAssistantToken)
                    for entity in homeAssistantEntities { applyMappedEntityState(entity) }
                    activeHomeAssistantURL = url
                    homeAssistantState = .connected(route, latencyMilliseconds: latency)
                    await connectHomeAssistantWebSocket(baseURL: url)
                    return
                } catch { lastError = error }
            }
            throw lastError ?? HAClientError.invalidResponse
        } catch {
            homeAssistantState = .offline(error.localizedDescription)
        }
    }

    var homeAssistantLightEntities: [HAEntityState] {
        homeAssistantEntities
            .filter { $0.entityID.hasPrefix("light.") }
            .sorted { friendlyName(for: $0) < friendlyName(for: $1) }
    }

    var homeAssistantClimateEntities: [HAEntityState] { entities(in: "climate") }
    var homeAssistantMediaPlayerEntities: [HAEntityState] { entities(in: "media_player") }
    var homeAssistantRemoteEntities: [HAEntityState] { entities(in: "remote") }
    var homeAssistantSwitchEntities: [HAEntityState] { entities(in: "switch") }
    var homeAssistantBinarySensorEntities: [HAEntityState] { entities(in: "binary_sensor") }
    var homeAssistantScriptEntities: [HAEntityState] { entities(in: "script") }

    var homeAssistantSceneActions: [HomeAssistantSceneAction] {
        homeAssistantEntities
            .filter { $0.domain == "scene" || $0.domain == "script" }
            .map { entity in
                HomeAssistantSceneAction(
                    entityID: entity.entityID,
                    title: friendlyName(for: entity),
                    domain: entity.domain,
                    isAvailable: entity.isAvailable,
                    isFavorite: favoriteSceneActionIDs.contains(entity.entityID)
                )
            }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    var mappedRoomLightState: HAEntityState? {
        homeAssistantEntities.first { $0.entityID == homeAssistantLightEntityID }
    }

    var activeHomeAssistantRoute: ConnectionRoute {
        if case .connected(let route, _) = homeAssistantState { return route }
        return .offline
    }

    var hasMappedHomeAssistantWidgets: Bool {
        !homeAssistantLightEntityID.isEmpty || !homeAssistantClimateEntityID.isEmpty
            || !homeAssistantTelevisionEntityID.isEmpty || !homeAssistantPCPowerEntityID.isEmpty
    }

    var hasConfiguredPCWakeWorkflow: Bool {
        !homeAssistantPCOnlineSensorEntityID.isEmpty
            && (!homeAssistantPCPowerEntityID.isEmpty || wakeOnLANConfiguration.normalizedMACAddress != nil)
    }

    var integrationHealthItems: [IntegrationHealthItem] {
        let homeAssistant: IntegrationHealthItem = switch homeAssistantState {
        case .connected(let route, let latency):
            IntegrationHealthItem(id: "ha", title: "Home Assistant", status: route.rawValue, detail: "Connected · \(latency) ms", level: .healthy, symbol: "house.fill")
        case .testing, .reconnecting:
            IntegrationHealthItem(id: "ha", title: "Home Assistant", status: "Reconnecting", detail: "Selecting the best configured route", level: .attention, symbol: "house.fill")
        case .offline:
            IntegrationHealthItem(id: "ha", title: "Home Assistant", status: "Offline", detail: "No active Home Assistant route", level: .unavailable, symbol: "house.fill")
        case .notConfigured:
            IntegrationHealthItem(id: "ha", title: "Home Assistant", status: "Not configured", detail: "Add URLs and a token in Settings", level: .informational, symbol: "house.fill")
        }
        let live = IntegrationHealthItem(
            id: "ha-live", title: "Live State", status: homeAssistantWebSocketState == .subscribed ? "Subscribed" : homeAssistantWebSocketState.rawValue.capitalized,
            detail: "Home Assistant state-change channel", level: homeAssistantWebSocketState == .subscribed ? .healthy : .attention,
            symbol: "bolt.horizontal.circle.fill"
        )
        let mappedCount = [homeAssistantLightEntityID, homeAssistantClimateEntityID, homeAssistantTelevisionEntityID,
                           homeAssistantTelevisionRemoteEntityID, homeAssistantPCPowerEntityID, homeAssistantPCOnlineSensorEntityID,
                           homeAssistantLaunchGameScriptEntityID, homeAssistantSleepPCScriptEntityID].filter { !$0.isEmpty }.count
        let mappings = IntegrationHealthItem(id: "mappings", title: "Entity Mappings", status: "\(mappedCount) mapped", detail: "Identifiers hidden from diagnostics", level: mappedCount > 0 ? .healthy : .informational, symbol: "link.circle.fill")
        let pc = IntegrationHealthItem(
            id: "pc", title: "PC State", status: homeAssistantPCOnlineSensorEntityID.isEmpty ? "No sensor" : (mockRoomControl.pcPower.backendReachable ? "Online" : "Offline"),
            detail: hasConfiguredPCWakeWorkflow ? "Wake workflow ready" : "Wake workflow incomplete", level: mockRoomControl.pcPower.backendReachable ? .healthy : .informational,
            symbol: "desktopcomputer"
        )
        let companion: IntegrationHealthItem = switch companionStatus {
        case .connected(let route): IntegrationHealthItem(id: "companion", title: "Companion", status: route.rawValue, detail: "Private-network connection", level: .healthy, symbol: "network")
        case .testing: IntegrationHealthItem(id: "companion", title: "Companion", status: "Testing", detail: "Private-network connection", level: .attention, symbol: "network")
        case .failed: IntegrationHealthItem(id: "companion", title: "Companion", status: "Unavailable", detail: "Address hidden from diagnostics", level: .unavailable, symbol: "network")
        case .notConfigured: IntegrationHealthItem(id: "companion", title: "Companion", status: "Not configured", detail: "Optional LAN/private-VPN integration", level: .informational, symbol: "network")
        }
        return [homeAssistant, live, mappings, pc, companion]
    }

    func friendlyName(for entity: HAEntityState) -> String {
        if case .string(let name) = entity.attributes["friendly_name"] { return name }
        return entity.entityID
    }

    func mapRoomLightEntity(_ entityID: String) {
        homeAssistantLightEntityID = entityID
        UserDefaults.standard.set(entityID, forKey: "homeAssistant.roomLightEntityID")
        guard let index = roomControlTemplate.widgets.firstIndex(where: { $0.kind == .light }) else { return }
        if entityID.isEmpty {
            roomControlTemplate.widgets[index].backend = WidgetBackendReference(backend: .mock, identifier: "mock.light.room")
            roomControlTemplate.widgets[index].subtitle = "Mock Govee light"
        } else {
            roomControlTemplate.widgets[index].backend = WidgetBackendReference(backend: .homeAssistant, identifier: entityID)
            roomControlTemplate.widgets[index].subtitle = "Home Assistant · \(entityID)"
            if let entity = mappedRoomLightState {
                roomControlTemplate.widgets[index].capabilities = HomeAssistantCapabilityDiscovery.capabilities(for: entity)
                applyLightState(entity)
            }
        }
        saveRoomControlLayout()
    }

    func mapHomeAssistantEntity(_ entityID: String, to kind: RoomWidgetKind) {
        let defaultsKey: String
        switch kind {
        case .climate:
            homeAssistantClimateEntityID = entityID
            defaultsKey = "homeAssistant.climateEntityID"
        case .television:
            homeAssistantTelevisionEntityID = entityID
            defaultsKey = "homeAssistant.televisionEntityID"
        case .pcPower:
            homeAssistantPCPowerEntityID = entityID
            defaultsKey = "homeAssistant.pcPowerEntityID"
        default:
            return
        }
        UserDefaults.standard.set(entityID, forKey: defaultsKey)
        configureMappedWidget(kind: kind, entityID: entityID)
        if let entity = homeAssistantEntities.first(where: { $0.entityID == entityID }) {
            applyMappedEntityState(entity)
        }
        saveRoomControlLayout()
    }

    func mapTelevisionRemoteEntity(_ entityID: String) {
        homeAssistantTelevisionRemoteEntityID = entityID
        UserDefaults.standard.set(entityID, forKey: "homeAssistant.televisionRemoteEntityID")
        refreshTelevisionCapabilities()
        saveRoomControlLayout()
    }

    func mapPCOnlineSensorEntity(_ entityID: String) {
        homeAssistantPCOnlineSensorEntityID = entityID
        UserDefaults.standard.set(entityID, forKey: "homeAssistant.pcOnlineSensorEntityID")
        if let entity = homeAssistantEntities.first(where: { $0.entityID == entityID }) { applyMappedEntityState(entity) }
    }

    func mapPCScriptEntity(_ entityID: String, for action: CompanionDashboardAction) {
        switch action {
        case .launchGame:
            homeAssistantLaunchGameScriptEntityID = entityID
            UserDefaults.standard.set(entityID, forKey: "homeAssistant.launchGameScriptEntityID")
        case .sleepPC:
            homeAssistantSleepPCScriptEntityID = entityID
            UserDefaults.standard.set(entityID, forKey: "homeAssistant.sleepPCScriptEntityID")
        }
    }

    func savePCWakeConfiguration() {
        if let data = try? JSONEncoder().encode(wakeOnLANConfiguration) { UserDefaults.standard.set(data, forKey: "homeAssistant.wakeOnLAN") }
        UserDefaults.standard.set(pcActionQueueTimeoutSeconds, forKey: "pcAction.queueTimeoutSeconds")
        UserDefaults.standard.set(wakePCBeforeQueuedActions, forKey: "pcAction.wakeBeforeQueuedActions")
    }

    func toggleSceneActionFavorite(_ entityID: String) {
        if favoriteSceneActionIDs.contains(entityID) {
            favoriteSceneActionIDs.remove(entityID)
        } else {
            favoriteSceneActionIDs.insert(entityID)
        }
        UserDefaults.standard.set(Array(favoriteSceneActionIDs).sorted(), forKey: "homeAssistant.favoriteSceneActions")
    }

    func activateSceneAction(_ action: HomeAssistantSceneAction) async {
        var execution = SceneOrchestrationExecution(
            entityID: action.entityID,
            title: action.title,
            steps: [
                OrchestrationStep(id: "route", title: "Secure route", status: .queued, detail: "Waiting for Home Assistant"),
                OrchestrationStep(id: "dispatch", title: "Dispatch", status: .queued, detail: "Not sent"),
                OrchestrationStep(id: "confirmation", title: "Backend confirmation", status: .queued, detail: "Not started")
            ]
        )
        sceneOrchestrationExecution = execution
        var command = CommandExecution(action: .activateScene(action.title), status: .queued, backendMessage: "Preparing \(action.title)…")
        pendingCommand = command

        guard action.isAvailable else {
            execution.steps[0].status = .unavailable
            execution.steps[0].detail = "Entity unavailable"
            sceneOrchestrationExecution = execution
            command.status = .unavailable
            command.backendMessage = "\(action.title) is unavailable."
            pendingCommand = command
            return
        }
        guard let activeHomeAssistantURL else {
            execution.steps[0].status = .unavailable
            execution.steps[0].detail = "Home Assistant offline"
            sceneOrchestrationExecution = execution
            command.status = .unavailable
            command.backendMessage = "Home Assistant is offline."
            pendingCommand = command
            return
        }

        execution.steps[0].status = .confirmed
        execution.steps[0].detail = activeHomeAssistantRoute.rawValue
        execution.steps[1].status = .running
        execution.steps[1].detail = "Sending \(action.kindTitle.lowercased()) action"
        sceneOrchestrationExecution = execution
        command.status = .running
        command.backendMessage = "Sending \(action.title) to Home Assistant…"
        pendingCommand = command

        let before = homeAssistantEntities.first(where: { $0.entityID == action.entityID })
        do {
            try await homeAssistantService.callService(
                HAServiceCall(domain: action.domain, service: "turn_on", data: ["entity_id": .string(action.entityID)]),
                baseURL: activeHomeAssistantURL, token: homeAssistantToken
            )
            execution.steps[1].status = .confirmed
            execution.steps[1].detail = "Accepted by Home Assistant"
            execution.steps[2].status = .running
            execution.steps[2].detail = action.domain == "scene" ? "Waiting for activation timestamp" : "Waiting for script lifecycle"
            sceneOrchestrationExecution = execution
            command.backendMessage = execution.steps[2].detail
            pendingCommand = command

            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var observedScriptRunning = false
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else { throw CancellationError() }
                if let current = homeAssistantEntities.first(where: { $0.entityID == action.entityID }) {
                    let confirmed: Bool
                    if action.domain == "scene" {
                        confirmed = current.state != before?.state || current.lastChanged != before?.lastChanged
                    } else {
                        if current.state == "on" { observedScriptRunning = true }
                        confirmed = current.state == "off" && (observedScriptRunning || current.lastChanged != before?.lastChanged)
                    }
                    if confirmed {
                        execution.steps[2].status = .confirmed
                        execution.steps[2].detail = action.domain == "scene" ? "Activation recorded by Home Assistant" : "Script lifecycle completed"
                        sceneOrchestrationExecution = execution
                        command.status = .confirmed
                        command.backendMessage = action.domain == "scene"
                            ? "Scene activation confirmed by Home Assistant."
                            : "Script completed; downstream device states may require separate confirmation."
                        pendingCommand = command
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            execution.steps[2].status = .failed
            execution.steps[2].detail = "No confirming state update before timeout"
            sceneOrchestrationExecution = execution
            command.status = .failed
            command.backendMessage = "Home Assistant accepted the action, but activation was not confirmed."
            pendingCommand = command
        } catch {
            execution.steps[1].status = .failed
            execution.steps[1].detail = error is CancellationError ? "Cancelled" : "Request failed"
            sceneOrchestrationExecution = execution
            command.status = .failed
            command.backendMessage = error is CancellationError ? "Scene action cancelled." : error.localizedDescription
            pendingCommand = command
        }
    }

    func startNetworkMonitoring() {
        networkPathObserver.start { [weak self] isReachable in
            guard let self else { return }
            self.lgTV.networkPathChanged(isReachable: isReachable)
            if isReachable {
                self.scheduleHomeAssistantReconnect()
                Task { await self.connectCompanionIfConfigured() }
            } else {
                self.reconnectTask?.cancel()
                self.homeAssistantWebSocketState = .disconnected
                if !self.homeAssistantToken.isEmpty {
                    self.homeAssistantState = .offline("No network connection")
                }
                Task { await self.homeAssistantWebSocket.disconnect() }
            }
        }
    }

    func toggleRoomLightControl() async {
        guard !homeAssistantLightEntityID.isEmpty else {
            await toggleMockLight()
            return
        }
        await callMappedLightService(
            service: "toggle",
            data: ["entity_id": .string(homeAssistantLightEntityID)],
            label: "Light power"
        )
    }

    func turnOffRoomLight() async {
        guard !homeAssistantLightEntityID.isEmpty else {
            if mockRoomControl.light.isOn { await toggleMockLight() }
            return
        }
        guard mockRoomControl.light.isOn else { return }
        await callMappedLightService(
            service: "turn_off",
            data: ["entity_id": .string(homeAssistantLightEntityID)],
            label: "Light power"
        )
    }

    func commitRoomLightBrightness() async {
        guard !homeAssistantLightEntityID.isEmpty else {
            await confirmMockControl("Light brightness")
            return
        }
        await callMappedLightService(
            service: "turn_on",
            data: [
                "entity_id": .string(homeAssistantLightEntityID),
                "brightness_pct": .number(mockRoomControl.light.brightness)
            ],
            label: "Light brightness"
        )
    }

    func commitRoomLightColorTemperature() async {
        guard !homeAssistantLightEntityID.isEmpty else {
            await confirmMockControl("Light color temperature")
            return
        }
        await callMappedLightService(
            service: "turn_on",
            data: [
                "entity_id": .string(homeAssistantLightEntityID),
                "color_temp_kelvin": .number(mockRoomControl.light.colorTemperature)
            ],
            label: "Light color temperature"
        )
    }

    func commitClimateTemperature() async {
        guard !homeAssistantClimateEntityID.isEmpty else {
            await confirmMockControl("Climate target temperature")
            return
        }
        await callHomeAssistantService(
            domain: "climate", service: "set_temperature",
            data: ["entity_id": .string(homeAssistantClimateEntityID), "temperature": .number(mockRoomControl.climate.targetTemperature)],
            label: "Climate target temperature", confirmationEntityID: homeAssistantClimateEntityID
        )
    }

    func setClimateOption(_ capability: DeviceCapabilityKind, value: String) async {
        guard !homeAssistantClimateEntityID.isEmpty else {
            await confirmMockControl("Climate \(capability.rawValue)")
            return
        }
        let service: String
        let key: String
        switch capability {
        case .hvacMode: service = "set_hvac_mode"; key = "hvac_mode"
        case .fanMode: service = "set_fan_mode"; key = "fan_mode"
        case .swingMode: service = "set_swing_mode"; key = "swing_mode"
        default: return
        }
        await callHomeAssistantService(
            domain: "climate", service: service,
            data: ["entity_id": .string(homeAssistantClimateEntityID), key: .string(value)],
            label: "Climate \(capability.rawValue)", confirmationEntityID: homeAssistantClimateEntityID
        )
    }

    func toggleTelevisionControl() async {
        guard !homeAssistantTelevisionEntityID.isEmpty else { await toggleMockTelevisionPower(); return }
        await callHomeAssistantService(
            domain: "media_player", service: mockRoomControl.television.isOn ? "turn_off" : "turn_on",
            data: ["entity_id": .string(homeAssistantTelevisionEntityID)], label: "TV power",
            confirmationEntityID: homeAssistantTelevisionEntityID
        )
    }

    func commitTelevisionVolume() async {
        guard !homeAssistantTelevisionEntityID.isEmpty else { await confirmMockControl("TV volume"); return }
        await callHomeAssistantService(
            domain: "media_player", service: "volume_set",
            data: ["entity_id": .string(homeAssistantTelevisionEntityID), "volume_level": .number(mockRoomControl.television.volume / 100)],
            label: "TV volume", confirmationEntityID: homeAssistantTelevisionEntityID
        )
    }

    func toggleTelevisionMute() async {
        guard !homeAssistantTelevisionEntityID.isEmpty else {
            mockRoomControl.television.isMuted.toggle()
            await confirmMockControl("TV mute")
            return
        }
        await callHomeAssistantService(
            domain: "media_player", service: "volume_mute",
            data: ["entity_id": .string(homeAssistantTelevisionEntityID), "is_volume_muted": .bool(!mockRoomControl.television.isMuted)],
            label: "TV mute", confirmationEntityID: homeAssistantTelevisionEntityID
        )
    }

    func sendTelevisionControl(_ command: String) async {
        guard !homeAssistantTelevisionEntityID.isEmpty else { await sendMockTelevisionRemoteCommand(command); return }
        if command == "PlayPause" {
            await callHomeAssistantService(
                domain: "media_player", service: "media_play_pause",
                data: ["entity_id": .string(homeAssistantTelevisionEntityID)], label: "TV playback",
                confirmationEntityID: homeAssistantTelevisionEntityID
            )
            return
        }
        guard !homeAssistantTelevisionRemoteEntityID.isEmpty else {
            pendingCommand = CommandExecution(action: .mockControl("TV \(command)"), status: .unavailable, backendMessage: "Map a Home Assistant remote entity in Settings first.")
            return
        }
        let translated = ["Up": "UP", "Down": "DOWN", "Left": "LEFT", "Right": "RIGHT", "OK": "ENTER", "Back": "BACK", "Home": "HOME"][command] ?? command
        await callHomeAssistantAcceptedService(
            domain: "remote", service: "send_command",
            data: ["entity_id": .string(homeAssistantTelevisionRemoteEntityID), "command": .array([.string(translated)])],
            label: "TV \(command)"
        )
    }

    func selectTelevisionSource(_ source: String) async {
        guard !homeAssistantTelevisionEntityID.isEmpty else {
            mockRoomControl.television.source = source
            await confirmMockControl("TV source")
            return
        }
        await callHomeAssistantService(
            domain: "media_player", service: "select_source",
            data: ["entity_id": .string(homeAssistantTelevisionEntityID), "source": .string(source)],
            label: "TV source", confirmationEntityID: homeAssistantTelevisionEntityID
        )
    }

    func startPCControl() async {
        guard !homeAssistantPCPowerEntityID.isEmpty || wakeOnLANConfiguration.normalizedMACAddress != nil else {
            await startMockPC()
            return
        }
        _ = await wakePCAndWait(label: "Start PC")
    }

    private func wakePCAndWait(label: String) async -> Bool {
        if mockRoomControl.pcPower.backendReachable {
            pendingCommand = CommandExecution(action: .mockControl(label), status: .confirmed, backendMessage: "PC is already online.")
            return true
        }
        guard let activeHomeAssistantURL else {
            pendingCommand = CommandExecution(action: .mockControl(label), status: .unavailable, backendMessage: "Home Assistant is offline.")
            return false
        }

        var execution = CommandExecution(action: .mockControl(label), status: .queued, backendMessage: "Queued while the PC wakes…")
        pendingCommand = execution
        do {
            var wakeMethodUsed = false
            if !homeAssistantPCPowerEntityID.isEmpty, mockRoomControl.pcPower.plugState != .on {
                execution.status = .running
                execution.backendMessage = "Turning on the PC smart plug through Home Assistant…"
                pendingCommand = execution
                mockRoomControl.pcPower.plugState = .turningOn
                mockRoomControl.pcPower.pcState = .supplyingPower
                try await homeAssistantService.callService(
                    HAServiceCall(domain: "switch", service: "turn_on", data: ["entity_id": .string(homeAssistantPCPowerEntityID)]),
                    baseURL: activeHomeAssistantURL, token: homeAssistantToken
                )
                wakeMethodUsed = true
                try await Task.sleep(for: .seconds(1))
            }

            if wakePCBeforeQueuedActions, let mac = wakeOnLANConfiguration.normalizedMACAddress {
                execution.status = .running
                execution.backendMessage = "Sending Wake-on-LAN through Home Assistant…"
                pendingCommand = execution
                var data: [String: HAJSONValue] = ["mac": .string(mac)]
                let broadcast = wakeOnLANConfiguration.broadcastAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                if !broadcast.isEmpty { data["broadcast_address"] = .string(broadcast) }
                try await homeAssistantService.callService(
                    HAServiceCall(domain: "wake_on_lan", service: "send_magic_packet", data: data),
                    baseURL: activeHomeAssistantURL, token: homeAssistantToken
                )
                wakeMethodUsed = true
            }

            guard wakeMethodUsed else {
                execution.status = .unavailable
                execution.backendMessage = "Configure a smart plug or valid Wake-on-LAN MAC address first."
                pendingCommand = execution
                return false
            }
            guard !homeAssistantPCOnlineSensorEntityID.isEmpty else {
                execution.status = .running
                execution.backendMessage = "Wake request accepted. Map a PC online sensor to confirm startup."
                pendingCommand = execution
                return false
            }

            execution.status = .running
            execution.backendMessage = "Wake request accepted. Waiting for the PC online sensor…"
            pendingCommand = execution
            let deadline = ContinuousClock.now.advanced(by: .seconds(pcActionQueueTimeoutSeconds))
            while ContinuousClock.now < deadline {
                if Task.isCancelled {
                    execution.status = .failed
                    execution.backendMessage = "Queued PC action was cancelled."
                    pendingCommand = execution
                    return false
                }
                if mockRoomControl.pcPower.backendReachable {
                    execution.status = .confirmed
                    execution.backendMessage = "PC online confirmed by Home Assistant."
                    pendingCommand = execution
                    return true
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            execution.status = .failed
            execution.backendMessage = "PC did not come online within \(Int(pcActionQueueTimeoutSeconds)) seconds; queued action cancelled."
            pendingCommand = execution
            return false
        } catch is CancellationError {
            execution.status = .failed
            execution.backendMessage = "Queued PC action was cancelled."
            pendingCommand = execution
            return false
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
            pendingCommand = execution
            return false
        }
    }

    private func homeAssistantScriptID(for action: CompanionDashboardAction) -> String {
        switch action {
        case .launchGame: homeAssistantLaunchGameScriptEntityID
        case .sleepPC: homeAssistantSleepPCScriptEntityID
        }
    }

    private func runHomeAssistantPCScript(_ action: CompanionDashboardAction, entityID: String) async {
        if action == .launchGame, wakePCBeforeQueuedActions, hasConfiguredPCWakeWorkflow,
           !mockRoomControl.pcPower.backendReachable,
           !(await wakePCAndWait(label: "Wake PC for \(action.title)")) { return }

        guard let activeHomeAssistantURL else {
            pendingCommand = CommandExecution(action: action.roomAction, status: .unavailable, backendMessage: "Home Assistant is offline.")
            return
        }
        let previousLastChanged = homeAssistantEntities.first(where: { $0.entityID == entityID })?.lastChanged
        var execution = CommandExecution(action: action.roomAction, status: .running, backendMessage: "Starting \(action.title) through Home Assistant…")
        pendingCommand = execution
        do {
            try await homeAssistantService.callService(
                HAServiceCall(domain: "script", service: "turn_on", data: ["entity_id": .string(entityID)]),
                baseURL: activeHomeAssistantURL, token: homeAssistantToken
            )
            execution.backendMessage = "Home Assistant accepted the script. Waiting for its state to complete…"
            pendingCommand = execution
            let deadline = ContinuousClock.now.advanced(by: .seconds(pcActionQueueTimeoutSeconds))
            var observedRunning = false
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else { throw CancellationError() }
                if let script = homeAssistantEntities.first(where: { $0.entityID == entityID }) {
                    if script.state == "on" { observedRunning = true }
                    let lifecycleChanged = observedRunning || script.lastChanged != previousLastChanged
                    if lifecycleChanged, script.state == "off" {
                        if action == .sleepPC, !homeAssistantPCOnlineSensorEntityID.isEmpty {
                            execution.backendMessage = "Sleep script completed. Waiting for PC offline confirmation…"
                            pendingCommand = execution
                            if await waitForPCOnlineState(false, until: deadline) {
                                execution.status = .confirmed
                                execution.backendMessage = "PC offline confirmed by Home Assistant."
                            } else {
                                execution.status = .failed
                                execution.backendMessage = "Sleep script finished, but the PC did not go offline before timeout."
                            }
                        } else {
                            execution.status = .confirmed
                            execution.backendMessage = "Home Assistant script completed; downstream PC outcome was not independently verified."
                        }
                        pendingCommand = execution
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            execution.status = .failed
            execution.backendMessage = "Home Assistant accepted the script, but its completion was not observed before timeout."
            pendingCommand = execution
        } catch is CancellationError {
            execution.status = .failed
            execution.backendMessage = "Queued PC script was cancelled."
            pendingCommand = execution
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
            pendingCommand = execution
        }
    }

    private func waitForPCOnlineState(_ expectedOnline: Bool, until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if mockRoomControl.pcPower.backendReachable == expectedOnline { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func callMappedLightService(service: String, data: [String: HAJSONValue], label: String) async {
        await callHomeAssistantService(
            domain: "light", service: service, data: data, label: label,
            confirmationEntityID: homeAssistantLightEntityID
        )
    }

    private func callHomeAssistantService(
        domain: String,
        service: String,
        data: [String: HAJSONValue],
        label: String,
        confirmationEntityID: String
    ) async {
        guard let activeHomeAssistantURL else {
            pendingCommand = CommandExecution(action: .mockControl(label), status: .unavailable, backendMessage: "Home Assistant is offline.")
            return
        }
        var execution = CommandExecution(action: .mockControl(label), status: .running, backendMessage: "Sending to Home Assistant…")
        pendingCommand = execution
        pendingHomeAssistantLightConfirmation = execution.id
        pendingHomeAssistantConfirmationEntityID = confirmationEntityID
        do {
            try await homeAssistantService.callService(
                HAServiceCall(domain: domain, service: service, data: data),
                baseURL: activeHomeAssistantURL,
                token: homeAssistantToken
            )
            if pendingCommand?.id == execution.id, pendingCommand?.status == .running {
                execution.backendMessage = "Home Assistant accepted the command. Waiting for device-state confirmation…"
                pendingCommand = execution
            }
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
            pendingCommand = execution
            pendingHomeAssistantLightConfirmation = nil
            pendingHomeAssistantConfirmationEntityID = nil
        }
    }

    private func callHomeAssistantAcceptedService(
        domain: String,
        service: String,
        data: [String: HAJSONValue],
        label: String
    ) async {
        guard let activeHomeAssistantURL else {
            pendingCommand = CommandExecution(action: .mockControl(label), status: .unavailable, backendMessage: "Home Assistant is offline.")
            return
        }
        var execution = CommandExecution(action: .mockControl(label), status: .running, backendMessage: "Sending to Home Assistant…")
        pendingCommand = execution
        do {
            try await homeAssistantService.callService(
                HAServiceCall(domain: domain, service: service, data: data),
                baseURL: activeHomeAssistantURL, token: homeAssistantToken
            )
            execution.backendMessage = "Home Assistant accepted the command; this remote action has no confirmable state."
            pendingCommand = execution
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
            pendingCommand = execution
        }
    }

    private func connectHomeAssistantWebSocket(baseURL: URL) async {
        homeAssistantWebSocketState = .authenticating
        do {
            try await homeAssistantWebSocket.connect(
                baseURL: baseURL,
                token: homeAssistantToken,
                stateChanged: { [weak self] entity in
                    Task { @MainActor in self?.applyHomeAssistantState(entity) }
                },
                disconnected: { [weak self] message in
                    Task { @MainActor in
                        guard let self else { return }
                        self.homeAssistantWebSocketState = .reconnecting
                        self.scheduleHomeAssistantReconnect(message: message)
                    }
                }
            )
            homeAssistantWebSocketState = .subscribed
        } catch {
            homeAssistantWebSocketState = .disconnected
            scheduleHomeAssistantReconnect(message: error.localizedDescription)
        }
    }

    private func scheduleHomeAssistantReconnect(message: String? = nil) {
        guard !homeAssistantToken.isEmpty else { return }
        reconnectTask?.cancel()
        homeAssistantWebSocketState = .reconnecting
        homeAssistantState = .reconnecting
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.saveAndTestHomeAssistant()
            if case .offline = self.homeAssistantState, let message {
                self.homeAssistantState = .offline(message)
            }
        }
    }

    private func applyHomeAssistantState(_ entity: HAEntityState) {
        if let index = homeAssistantEntities.firstIndex(where: { $0.entityID == entity.entityID }) {
            homeAssistantEntities[index] = entity
        } else {
            homeAssistantEntities.append(entity)
        }
        applyMappedEntityState(entity)
        if let confirmationID = pendingHomeAssistantLightConfirmation,
           entity.entityID == pendingHomeAssistantConfirmationEntityID,
           pendingCommand?.id == confirmationID {
            pendingCommand?.status = .confirmed
            pendingCommand?.backendMessage = "Confirmed by Home Assistant device state"
            pendingHomeAssistantLightConfirmation = nil
            pendingHomeAssistantConfirmationEntityID = nil
        }
    }

    private func entities(in domain: String) -> [HAEntityState] {
        homeAssistantEntities
            .filter { $0.domain == domain }
            .sorted { friendlyName(for: $0) < friendlyName(for: $1) }
    }

    private func configureMappedWidget(kind: RoomWidgetKind, entityID: String) {
        guard let index = roomControlTemplate.widgets.firstIndex(where: { $0.kind == kind }) else { return }
        if entityID.isEmpty {
            // An empty Home Assistant mapping only means that a previously mapped
            // HA widget should return to its default. Direct integrations (such as
            // LG webOS) are persisted in the dashboard layout and must survive app
            // foregrounding and relaunches.
            guard roomControlTemplate.widgets[index].backend.backend == .homeAssistant else { return }
            let fallback = RoomControlTemplate.roomControl.widgets.first { $0.kind == kind }
            if let fallback {
                roomControlTemplate.widgets[index].backend = fallback.backend
                roomControlTemplate.widgets[index].subtitle = fallback.subtitle
                roomControlTemplate.widgets[index].capabilities = fallback.capabilities
            }
            return
        }
        roomControlTemplate.widgets[index].backend = WidgetBackendReference(backend: .homeAssistant, identifier: entityID)
        roomControlTemplate.widgets[index].subtitle = "Home Assistant · \(entityID)"
        if let entity = homeAssistantEntities.first(where: { $0.entityID == entityID }) {
            roomControlTemplate.widgets[index].capabilities = HomeAssistantCapabilityDiscovery.capabilities(for: entity)
        }
        if kind == .television { refreshTelevisionCapabilities() }
    }

    private func refreshTelevisionCapabilities() {
        guard let index = roomControlTemplate.widgets.firstIndex(where: { $0.kind == .television }),
              !homeAssistantTelevisionEntityID.isEmpty,
              let mediaEntity = homeAssistantEntities.first(where: { $0.entityID == homeAssistantTelevisionEntityID }) else { return }
        var capabilities = HomeAssistantCapabilityDiscovery.capabilities(for: mediaEntity)
        if !homeAssistantTelevisionRemoteEntityID.isEmpty,
           let remote = homeAssistantEntities.first(where: { $0.entityID == homeAssistantTelevisionRemoteEntityID }),
           remote.isAvailable {
            capabilities.append(contentsOf: HomeAssistantCapabilityDiscovery.capabilities(for: remote))
        }
        roomControlTemplate.widgets[index].capabilities = capabilities
    }

    private func applyMappedEntityState(_ entity: HAEntityState) {
        if let index = roomControlTemplate.widgets.firstIndex(where: { $0.backend.identifier == entity.entityID }) {
            roomControlTemplate.widgets[index].capabilities = HomeAssistantCapabilityDiscovery.capabilities(for: entity)
        }
        switch entity.entityID {
        case homeAssistantLightEntityID:
            applyLightState(entity)
        case homeAssistantClimateEntityID:
            mockRoomControl.climate.availability = entity.isAvailable ? .available : .unavailable
            if let current = entity.numberAttribute("current_temperature") { mockRoomControl.climate.currentTemperature = current }
            if let target = entity.numberAttribute("temperature") { mockRoomControl.climate.targetTemperature = target }
            mockRoomControl.climate.hvacMode = entity.state.replacingOccurrences(of: "_", with: " ").capitalized
            if let fan = entity.stringAttribute("fan_mode") { mockRoomControl.climate.fanMode = fan.capitalized }
            if let swing = entity.stringAttribute("swing_mode") { mockRoomControl.climate.swingMode = swing.capitalized }
        case homeAssistantTelevisionEntityID:
            mockRoomControl.television.isOnline = entity.isAvailable
            mockRoomControl.television.isOn = entity.state != "off" && entity.isAvailable
            if let volume = entity.numberAttribute("volume_level") { mockRoomControl.television.volume = volume * 100 }
            if let muted = entity.boolAttribute("is_volume_muted") { mockRoomControl.television.isMuted = muted }
            if let source = entity.stringAttribute("source") { mockRoomControl.television.source = source }
            if let app = entity.stringAttribute("app_name") { mockRoomControl.television.application = app }
            mockRoomControl.television.isPlaying = entity.state == "playing"
            refreshTelevisionCapabilities()
        case homeAssistantTelevisionRemoteEntityID:
            refreshTelevisionCapabilities()
        case homeAssistantPCPowerEntityID:
            mockRoomControl.pcPower.plugState = entity.isAvailable ? (entity.state == "on" ? .on : .off) : .unavailable
            if entity.state == "off" { mockRoomControl.pcPower.pcState = .offline }
        case homeAssistantPCOnlineSensorEntityID:
            mockRoomControl.pcPower.backendReachable = entity.isAvailable && entity.state == "on"
            if mockRoomControl.pcPower.backendReachable {
                mockRoomControl.pcPower.pcState = .online
            } else {
                mockRoomControl.pcPower.pcState = .offline
            }
        default:
            break
        }
    }

    private func applyLightState(_ entity: HAEntityState) {
        mockRoomControl.light.availability = entity.state == "unavailable" ? .unavailable : .available
        mockRoomControl.light.isOn = entity.state == "on"
        if case .number(let brightness) = entity.attributes["brightness"] {
            mockRoomControl.light.brightness = min(max(brightness / 255 * 100, 0), 100)
        }
        if let kelvin = entity.numberAttribute("color_temp_kelvin") {
            mockRoomControl.light.colorTemperature = kelvin
        }
    }

    func configureLayoutPersistence(_ context: ModelContext) {
        guard modelContext == nil else { return }
        modelContext = context
        var migratedGoXLRWidget = false

        let templateID = roomControlTemplate.id
        var descriptor = FetchDescriptor<DashboardLayoutRecord>(
            predicate: #Predicate { $0.templateID == templateID }
        )
        descriptor.fetchLimit = 1

        if let record = try? context.fetch(descriptor).first,
           let widgets = try? JSONDecoder().decode([RoomWidgetDefinition].self, from: record.widgetsData) {
            layoutRecord = record
            roomControlTemplate.name = record.name
            roomControlTemplate.widgets = widgets
        } else if let data = try? JSONEncoder().encode(roomControlTemplate.widgets) {
            let record = DashboardLayoutRecord(
                templateID: roomControlTemplate.id,
                name: roomControlTemplate.name,
                widgetsData: data
            )
            context.insert(record)
            try? context.save()
            layoutRecord = record
        }

        if !homeAssistantLightEntityID.isEmpty,
           let index = roomControlTemplate.widgets.firstIndex(where: { $0.kind == .light && $0.backend.backend != .govee }) {
            roomControlTemplate.widgets[index].backend = WidgetBackendReference(
                backend: .homeAssistant,
                identifier: homeAssistantLightEntityID
            )
            roomControlTemplate.widgets[index].subtitle = "Home Assistant · \(homeAssistantLightEntityID)"
        }
        configureMappedWidget(kind: .climate, entityID: homeAssistantClimateEntityID)
        configureMappedWidget(kind: .television, entityID: homeAssistantTelevisionEntityID)
        refreshTelevisionCapabilities()
        configureMappedWidget(kind: .pcPower, entityID: homeAssistantPCPowerEntityID)
        if !remoteInput.usesMockAgent,
           let index = roomControlTemplate.widgets.firstIndex(where: {
               $0.kind == .audioMixer
                   && $0.backend.backend == .mock
                   && $0.backend.identifier == "mock.audio.goxlr"
           }) {
            roomControlTemplate.widgets[index].backend = WidgetBackendReference(
                backend: .windowsAgent,
                identifier: "windows-agent.goxlr"
            )
            roomControlTemplate.widgets[index].subtitle = "Authenticated Windows Agent mixer"
            migratedGoXLRWidget = true
        }
        if migratedGoXLRWidget { saveRoomControlLayout() }
    }

    func saveRoomControlLayout() {
        guard let modelContext,
              let data = try? JSONEncoder().encode(roomControlTemplate.widgets) else { return }

        let record = layoutRecord ?? DashboardLayoutRecord(
            templateID: roomControlTemplate.id,
            name: roomControlTemplate.name,
            widgetsData: data
        )
        if layoutRecord == nil {
            modelContext.insert(record)
            layoutRecord = record
        }
        record.name = roomControlTemplate.name
        record.widgetsData = data
        record.updatedAt = .now
        try? modelContext.save()
    }

    func addRoomWidget(_ widget: RoomWidgetDefinition) {
        roomControlTemplate.widgets.append(widget)
        saveRoomControlLayout()
    }

    func updateRoomWidget(_ widget: RoomWidgetDefinition) {
        guard let index = roomControlTemplate.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        roomControlTemplate.widgets[index] = widget
        saveRoomControlLayout()
    }

    func deleteRoomWidget(id: UUID) {
        roomControlTemplate.widgets.removeAll { $0.id == id }
        saveRoomControlLayout()
    }

    func moveRoomWidgets(from source: IndexSet, to destination: Int) {
        roomControlTemplate.widgets.move(fromOffsets: source, toOffset: destination)
        saveRoomControlLayout()
    }

    func resetRoomControlLayout() {
        roomControlTemplate = .roomControl
        saveRoomControlLayout()
    }

    func perform(_ action: RoomAction) async {
        let execution = CommandExecution(action: action, status: .queued)
        pendingCommand = execution
        pendingCommand?.status = .running
        pendingCommand = await commandService.execute(execution)
    }

    func confirmMockControl(_ name: String) async {
        var execution = CommandExecution(action: .mockControl(name), status: .pending)
        execution.backendMessage = "Waiting for mock \(name) confirmation…"
        pendingCommand = execution
        await Task.yield()
        execution.status = .running
        execution.backendMessage = "Applying \(name) in mock mode…"
        pendingCommand = execution
        try? await Task.sleep(for: .milliseconds(280))
        execution.status = .confirmed
        execution.backendMessage = "\(name) confirmed by mock device state"
        pendingCommand = execution
    }

    func toggleMockLight() async {
        mockRoomControl.light.isOn.toggle()
        await confirmMockControl("Light power")
    }

    func setDiscordScreenShareHotkey(_ combo: HotkeyCombo?) {
        discordScreenShareHotkey = combo
        if let combo, let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: "discord.screenShareHotkey")
        } else {
            UserDefaults.standard.removeObject(forKey: "discord.screenShareHotkey")
        }
    }

    @discardableResult
    func triggerDiscordScreenShareHotkey() async -> Bool {
        guard let combo = discordScreenShareHotkey else { return false }
        return await remoteInput.sendHotkey(combo)
    }

    func toggleMockDiscordConnection() async {
        if mockRoomControl.discord.isConnected {
            mockRoomControl.discord.isConnected = false
        } else {
            mockRoomControl.discord.isConnected = true
        }
        await confirmMockControl("Discord voice connection")
    }

    func toggleMockDiscordMute() async {
        mockRoomControl.discord.selfMute.toggle()
        await confirmMockControl("Discord mute")
    }

    func toggleMockDiscordDeafen() async {
        mockRoomControl.discord.selfDeaf.toggle()
        await confirmMockControl("Discord deafen")
    }

    func toggleSpotifyPlayback() async {
        mockRoomControl.spotify.isPlaying.toggle()
        await confirmMockControl("Spotify playback")
    }

    func skipSpotifyTrack(forward: Bool) async {
        let count = MockSpotifyState.library.count
        mockRoomControl.spotify.trackIndex = (mockRoomControl.spotify.trackIndex + (forward ? 1 : -1) + count) % count
        mockRoomControl.spotify.progressSeconds = 0
        await confirmMockControl(forward ? "Spotify skip" : "Spotify previous")
    }

    func toggleSpotifyLike() async {
        let trackID = mockRoomControl.spotify.currentTrack.id
        if mockRoomControl.spotify.likedTrackIDs.contains(trackID) {
            mockRoomControl.spotify.likedTrackIDs.remove(trackID)
            await confirmMockControl("Removed from Liked Songs")
        } else {
            mockRoomControl.spotify.likedTrackIDs.insert(trackID)
            await confirmMockControl("Added to Liked Songs")
        }
    }

    func toggleCurrentSpotifyTrack(inPlaylistID playlistID: String) async {
        guard let index = mockRoomControl.spotify.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let trackID = mockRoomControl.spotify.currentTrack.id
        let playlistName = mockRoomControl.spotify.playlists[index].name
        if let trackIndex = mockRoomControl.spotify.playlists[index].trackIDs.firstIndex(of: trackID) {
            mockRoomControl.spotify.playlists[index].trackIDs.remove(at: trackIndex)
            await confirmMockControl("Removed from \(playlistName)")
        } else {
            mockRoomControl.spotify.playlists[index].trackIDs.append(trackID)
            await confirmMockControl("Added to \(playlistName)")
        }
    }

    func toggleMockTelevisionPower() async {
        guard mockRoomControl.television.isOnline else {
            pendingCommand = CommandExecution(
                action: .mockControl("TV power"),
                status: .unavailable,
                backendMessage: "TV is unavailable in mock mode."
            )
            return
        }
        mockRoomControl.television.isOn.toggle()
        await confirmMockControl("TV power")
    }

    func sendMockTelevisionRemoteCommand(_ command: String) async {
        guard mockRoomControl.television.isOnline else {
            pendingCommand = CommandExecution(
                action: .mockControl("TV remote"),
                status: .unavailable,
                backendMessage: "TV is unavailable in mock mode."
            )
            return
        }
        mockRoomControl.television.lastRemoteCommand = command
        await confirmMockControl("TV \(command)")
    }

    func startMockPC() async {
        guard mockRoomControl.pcPower.pcState != .online else { return }

        var execution = CommandExecution(action: .mockControl("Start PC"), status: .running)
        execution.backendMessage = "Turning on the mock Smart Life plug…"
        pendingCommand = execution
        mockRoomControl.pcPower.plugState = .turningOn
        mockRoomControl.pcPower.pcState = .supplyingPower

        try? await Task.sleep(for: .milliseconds(500))
        mockRoomControl.pcPower.plugState = .on
        mockRoomControl.pcPower.pcState = .booting(progress: 0.35)
        execution.backendMessage = "Waiting for the PC backend…"
        pendingCommand = execution

        try? await Task.sleep(for: .milliseconds(650))
        mockRoomControl.pcPower.pcState = .booting(progress: 0.75)

        try? await Task.sleep(for: .milliseconds(650))
        mockRoomControl.pcPower.backendReachable = true
        mockRoomControl.pcPower.pcState = .online
        execution.status = .confirmed
        execution.backendMessage = "PC online confirmed by the mock backend"
        pendingCommand = execution
    }

    func testCompanionConnection() async {
        guard companionStatus != .testing else { return }
        companionStatus = .testing
        companionButtonTestStatus = .idle

        do {
            let endpoint = try CompanionEndpoint(address: companionAddress)
            try await companionService.testConnection(to: endpoint)
            companionAddress = endpoint.baseURL.absoluteString
            companionSettings.saveAddress(companionAddress)
            companionStatus = .connected(endpoint.route)
            updateCompanionConnection(route: endpoint.route == .localNetwork ? .local : .remote, health: .connected)
        } catch {
            companionStatus = .failed(error.localizedDescription)
            updateCompanionConnection(route: .offline, health: .unavailable)
        }
    }

    func connectCompanionIfConfigured() async {
        guard !companionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            companionStatus = .notConfigured
            return
        }
        await testCompanionConnection()
    }

    func pressCompanionTestButton() async {
        companionButtonTestStatus = .sending

        do {
            let endpoint = try CompanionEndpoint(address: companionAddress)
            let location = try CompanionButtonLocation(
                page: companionButtonMapping.page,
                row: companionButtonMapping.row,
                column: companionButtonMapping.column
            )
            companionSettings.saveButtonMapping(companionButtonMapping)

            let receipt = try await companionService.pressButton(at: location, on: endpoint)
            if receipt.accepted {
                companionButtonTestStatus = .accepted(receipt.statusCode)
            } else {
                companionButtonTestStatus = .failed("Companion rejected the request with HTTP \(receipt.statusCode).")
            }
        } catch {
            companionButtonTestStatus = .failed(error.localizedDescription)
        }
    }

    func assignTestedCompanionButton(to action: CompanionDashboardAction) {
        companionDashboardMappings[action] = companionButtonMapping
        companionSettings.saveDashboardMapping(companionButtonMapping, for: action)
    }

    func dashboardMapping(for action: CompanionDashboardAction) -> CompanionButtonMapping {
        companionDashboardMappings[action] ?? companionButtonMapping
    }

    func updateCompanionDashboardMapping(_ mapping: CompanionButtonMapping, for action: CompanionDashboardAction) {
        companionDashboardMappings[action] = mapping
        companionSettings.saveDashboardMapping(mapping, for: action)
        companionMappingTestStatuses[action] = .idle
    }

    func testCompanionDashboardMapping(_ action: CompanionDashboardAction) async {
        companionMappingTestStatuses[action] = .sending

        do {
            let mapping = dashboardMapping(for: action)
            updateCompanionDashboardMapping(mapping, for: action)
            companionMappingTestStatuses[action] = .sending

            let endpoint = try CompanionEndpoint(address: companionAddress)
            let location = try CompanionButtonLocation(
                page: mapping.page,
                row: mapping.row,
                column: mapping.column
            )
            let receipt = try await companionService.pressButton(at: location, on: endpoint)

            if receipt.accepted {
                companionMappingTestStatuses[action] = .accepted(receipt.statusCode)
            } else {
                companionMappingTestStatuses[action] = .failed(
                    "Companion rejected the request with HTTP \(receipt.statusCode)."
                )
            }
        } catch {
            companionMappingTestStatuses[action] = .failed(error.localizedDescription)
        }
    }

    func performCompanionDashboardAction(_ action: CompanionDashboardAction) async {
        var execution = CommandExecution(action: action.roomAction, status: .queued)
        pendingCommand = execution

        let scriptID = homeAssistantScriptID(for: action)
        if !scriptID.isEmpty {
            await runHomeAssistantPCScript(action, entityID: scriptID)
            return
        }

        guard let mapping = companionDashboardMappings[action] else {
            execution.status = .unavailable
            execution.backendMessage = "\(action.title) has not been mapped in Settings."
            pendingCommand = execution
            return
        }

        if action == .launchGame, wakePCBeforeQueuedActions, hasConfiguredPCWakeWorkflow,
           !mockRoomControl.pcPower.backendReachable {
            guard await wakePCAndWait(label: "Wake PC for \(action.title)") else { return }
            await testCompanionConnection()
            execution = CommandExecution(action: action.roomAction, status: .queued, backendMessage: "PC is online. Continuing \(action.title)…")
            pendingCommand = execution
        }

        guard case .connected = companionStatus else {
            execution.status = .unavailable
            execution.backendMessage = "Companion is offline. Reconnect it in Settings."
            pendingCommand = execution
            return
        }

        execution.status = .running
        execution.backendMessage = "Sending to Companion…"
        pendingCommand = execution

        do {
            let endpoint = try CompanionEndpoint(address: companionAddress)
            let location = try CompanionButtonLocation(
                page: mapping.page,
                row: mapping.row,
                column: mapping.column
            )
            let receipt = try await companionService.pressButton(at: location, on: endpoint)

            if receipt.accepted {
                execution.status = .running
                execution.backendMessage = "Companion accepted \(action.title). Waiting for PC-state confirmation."
            } else {
                execution.status = .failed
                execution.backendMessage = "Companion rejected \(action.title) with HTTP \(receipt.statusCode)."
            }
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
        }

        pendingCommand = execution
    }

    func performControlDeckAction(_ item: ControlDeckItem) async {
        if let action = item.action {
            switch action {
            case .shortcut(let shortcut):
                await performShortcut(shortcut, title: item.title)
            case .govee(let goveeAction):
                await performGoveeAction(goveeAction, title: item.title)
            case .companion(let mapping):
                var mappedItem = item
                mappedItem.mapping = mapping
                await performCompanionControl(mappedItem)
            }
            return
        }

        // Existing saved dashboards predate ControlDeckAction. Preserve their
        // Companion mappings without requiring a migration prompt.
        await performCompanionControl(item)
    }

    private func performShortcut(_ shortcut: AppleShortcutAction, title: String) async {
        var execution = CommandExecution(action: .companionButton(title), status: .running)
        pendingCommand = execution

        let name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            execution.status = .unavailable
            execution.backendMessage = "Choose an Apple Shortcut for \(title)."
            pendingCommand = execution
            return
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var queryItems = [URLQueryItem(name: "name", value: name)]
        let input = shortcut.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            queryItems.append(URLQueryItem(name: "input", value: "text"))
            queryItems.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = queryItems

        guard let url = components.url, await UIApplication.shared.open(url) else {
            execution.status = .failed
            execution.backendMessage = "The Shortcuts app could not run \(name)."
            pendingCommand = execution
            return
        }

        execution.backendMessage = "Sent \(name) to Apple Shortcuts. Completion is handled by the shortcut."
        pendingCommand = execution
    }

    @discardableResult
    private func performGoveeAction(_ action: GoveeDeviceAction, title: String) async -> Bool {
        var execution = CommandExecution(action: .companionButton(title), status: .running)
        execution.backendMessage = "Sending \(title) to Govee…"
        pendingCommand = execution

        guard !action.sku.isEmpty,
              !action.device.isEmpty,
              !action.capabilityType.isEmpty,
              !action.capabilityInstance.isEmpty,
              action.value != .null else {
            execution.status = .unavailable
            execution.backendMessage = "Choose a Govee device, control, and value for \(title)."
            pendingCommand = execution
            return false
        }

        do {
            let key = try goveeKeychain.load(account: "api-key") ?? ""
            try await goveeService.control(action, apiKey: key)
            execution.status = .confirmed
            execution.backendMessage = "Govee accepted \(title)."
            pendingCommand = execution
            return true
        } catch {
            execution.status = (error as? GoveeClientError) == .rateLimited ? .queued : .failed
            execution.backendMessage = error.localizedDescription
            pendingCommand = execution
            return false
        }
    }

    func performCompanionControl(_ item: ControlDeckItem) async {
        var execution = CommandExecution(action: .companionButton(item.title), status: .queued)
        pendingCommand = execution

        let fallbackAction: CompanionDashboardAction? = switch item.title.lowercased() {
        case "launch game": .launchGame
        case "sleep pc": .sleepPC
        default: nil
        }
        let semanticAction = item.systemAction ?? fallbackAction
        if let semanticAction {
            let scriptID = homeAssistantScriptID(for: semanticAction)
            if !scriptID.isEmpty {
                await runHomeAssistantPCScript(semanticAction, entityID: scriptID)
                return
            }
        }

        guard case .connected = companionStatus else {
            execution.status = .unavailable
            execution.backendMessage = "Companion is offline. Connect from Configure Deck."
            pendingCommand = execution
            return
        }

        guard let mapping = item.mapping else {
            execution.status = .unavailable
            execution.backendMessage = "\(item.title) has no Companion mapping."
            pendingCommand = execution
            return
        }

        execution.status = .running
        execution.backendMessage = "Sending \(item.title) to Companion…"
        pendingCommand = execution

        do {
            let receipt = try await pressCompanionMapping(mapping)
            if receipt.accepted {
                execution.backendMessage = "Companion accepted \(item.title). Waiting for backend-state confirmation."
            } else {
                execution.status = .failed
                execution.backendMessage = "Companion rejected \(item.title) with HTTP \(receipt.statusCode)."
            }
        } catch {
            execution.status = .failed
            execution.backendMessage = error.localizedDescription
        }

        pendingCommand = execution
    }

    func testCompanionMapping(_ mapping: CompanionButtonMapping) async -> CompanionButtonTestStatus {
        do {
            let receipt = try await pressCompanionMapping(mapping)
            return receipt.accepted
                ? .accepted(receipt.statusCode)
                : .failed("Companion rejected the request with HTTP \(receipt.statusCode).")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func addControlDeckItem(_ item: ControlDeckItem, to folderID: UUID? = nil) {
        if let folderID, let index = controlDeckItems.firstIndex(where: { $0.id == folderID && $0.kind == .folder }) {
            controlDeckItems[index].children.append(item)
            refreshFolderSubtitle(at: index)
        } else {
            controlDeckItems.append(item)
        }
        saveControlDeck()
    }

    func updateControlDeckItem(_ item: ControlDeckItem, parentFolderID: UUID?) {
        if parentFolderID == nil,
           let index = controlDeckItems.firstIndex(where: { $0.id == item.id }) {
            controlDeckItems[index] = item
            saveControlDeck()
            return
        }

        if let parentFolderID,
           let folderIndex = controlDeckItems.firstIndex(where: { $0.id == parentFolderID && $0.kind == .folder }),
           let childIndex = controlDeckItems[folderIndex].children.firstIndex(where: { $0.id == item.id }) {
            controlDeckItems[folderIndex].children[childIndex] = item
            refreshFolderSubtitle(at: folderIndex)
            saveControlDeck()
            return
        }

        removeControlDeckItem(id: item.id, save: false)
        addControlDeckItem(item, to: parentFolderID)
    }

    func deleteControlDeckItem(id: UUID) {
        removeControlDeckItem(id: id, save: true)
    }

    func moveControlDeckItems(from source: IndexSet, to destination: Int) {
        controlDeckItems.move(fromOffsets: source, toOffset: destination)
        saveControlDeck()
    }

    func moveControlDeckItems(in folderID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = controlDeckItems.firstIndex(where: { $0.id == folderID && $0.kind == .folder }) else { return }
        controlDeckItems[index].children.move(fromOffsets: source, toOffset: destination)
        saveControlDeck()
    }

    private func pressCompanionMapping(_ mapping: CompanionButtonMapping) async throws -> CompanionRequestReceipt {
        let endpoint = try CompanionEndpoint(address: companionAddress)
        let location = try CompanionButtonLocation(page: mapping.page, row: mapping.row, column: mapping.column)
        return try await companionService.pressButton(at: location, on: endpoint)
    }

    private func removeControlDeckItem(id: UUID, save: Bool) {
        controlDeckItems.removeAll { $0.id == id }
        for index in controlDeckItems.indices where controlDeckItems[index].kind == .folder {
            controlDeckItems[index].children.removeAll { $0.id == id }
            refreshFolderSubtitle(at: index)
        }
        if save { saveControlDeck() }
    }

    private func refreshFolderSubtitle(at index: Int) {
        let count = controlDeckItems[index].children.count
        controlDeckItems[index].subtitle = "\(count) \(count == 1 ? "button" : "buttons")"
    }

    private func saveControlDeck() {
        companionSettings.saveControlDeckItems(controlDeckItems)
    }

    private func updateCompanionConnection(route: ConnectionRoute, health: ConnectionHealth) {
        if let index = dashboard.connections.firstIndex(where: { $0.service == "Companion" }) {
            dashboard.connections[index].route = route
            dashboard.connections[index].health = health
        } else {
            dashboard.connections.append(ConnectionState(service: "Companion", route: route, health: health))
        }
    }
}
