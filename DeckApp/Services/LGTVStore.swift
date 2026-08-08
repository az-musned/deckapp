import Foundation
import Observation

@MainActor
@Observable
final class LGTVStore {
    var devices: [LGTVDevice]
    var discoveredDevices: [LGTVDevice] = []
    var selectedDeviceID: UUID?
    var connectionState: LGTVConnectionState = .disconnected
    var tvState = LGTVState()
    var lastError: String?
    var discoveryMessage: String?
    var pairingCooldownUntil: Date?

    @ObservationIgnored private let persistence: any LGTVDevicePersisting
    @ObservationIgnored private let discovery: any LGTVDiscovering
    @ObservationIgnored private let wakeService: any LGTVWakeOnLANServing
    @ObservationIgnored private let keychain: KeychainSecretStore
    @ObservationIgnored private let connection: any LGTVConnectionServing
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var intentionallyDisconnected = false
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var pairingCooldownTask: Task<Void, Never>?

    init(
        persistence: any LGTVDevicePersisting = LGTVDevicePersistence(),
        discovery: any LGTVDiscovering = LGTVSSDPDiscoveryService(),
        wakeService: any LGTVWakeOnLANServing = LGTVWakeOnLANService(),
        connection: (any LGTVConnectionServing)? = nil
    ) {
        self.persistence = persistence
        self.discovery = discovery
        self.wakeService = wakeService
        self.keychain = KeychainSecretStore(service: "com.example.DeckApp.lg-webos")
        let resolvedConnection = connection ?? LGTVConnectionClient()
        self.connection = resolvedConnection
        devices = persistence.loadDevices()
        let savedSelection = persistence.loadSelectedDeviceID()
        selectedDeviceID = devices.contains(where: { $0.id == savedSelection }) ? savedSelection : devices.first?.id
        resolvedConnection.onDisconnect = { [weak self] error in
            self?.connectionDropped(error)
        }
    }

    var selectedDevice: LGTVDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isConnectionAttemptInProgress: Bool {
        switch connectionState {
        case .connecting, .awaitingPairing, .reconnecting: true
        default: false
        }
    }

    var isPairingCoolingDown: Bool {
        guard let pairingCooldownUntil else { return false }
        return pairingCooldownUntil > .now
    }

    var canAutomaticallyConnectSelectedDevice: Bool {
        selectedDeviceHasPairingKey
    }

    func device(id: String) -> LGTVDevice? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return devices.first { $0.id == uuid }
    }

    func discover() async {
        connectionState = .discovering
        lastError = nil
        discoveryMessage = nil
        do {
            discoveredDevices = try await discovery.discover(timeout: 3)
            if discoveredDevices.isEmpty {
                discoveryMessage = "No TVs were found automatically. Confirm Local Network access and use the TV's IP address below if your mesh blocks discovery."
            }
            connectionState = selectedDevice == nil ? .disconnected : connectionStateForExistingConnection
        } catch {
            lastError = error.localizedDescription
            connectionState = .unavailable(error.localizedDescription)
        }
    }

    @discardableResult
    func addManual(name: String, host: String, macAddress: String?, secure: Bool) -> LGTVDevice? {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: ":").first.map(String.init) ?? ""
        guard !normalizedHost.isEmpty, !normalizedHost.contains("/") else {
            lastError = LGTVProtocolError.invalidAddress.localizedDescription
            return nil
        }
        let device = LGTVDevice(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "LG webOS TV" : name,
            host: normalizedHost,
            macAddress: macAddress?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            useSecureConnection: secure
        )
        upsert(device)
        select(device.id, connect: false)
        return device
    }

    func addDiscovered(_ discovered: LGTVDevice) {
        if let existing = devices.first(where: { $0.host.caseInsensitiveCompare(discovered.host) == .orderedSame }) {
            select(existing.id)
        } else {
            upsert(discovered)
            select(discovered.id)
        }
    }

    func update(_ device: LGTVDevice) {
        upsert(device)
        if selectedDeviceID == device.id {
            disconnect()
            Task { await connect() }
        }
    }

    func remove(_ id: UUID) {
        if selectedDeviceID == id { disconnect() }
        devices.removeAll { $0.id == id }
        try? keychain.delete(account: pairingAccount(id))
        selectedDeviceID = devices.first?.id
        saveConfiguration()
    }

    func select(_ id: UUID, connect shouldConnect: Bool = true) {
        guard devices.contains(where: { $0.id == id }) else { return }
        if selectedDeviceID != id { disconnect() }
        selectedDeviceID = id
        persistence.saveSelectedDeviceID(id)
        if shouldConnect { Task { await connect() } }
    }

    func connect(isReconnectAttempt: Bool = false) async {
        guard isAppActive, let device = selectedDevice, !isConnecting else { return }
        let existingKey = try? keychain.load(account: pairingAccount(device.id))
        if existingKey == nil, isPairingCoolingDown {
            connectionState = .unavailable("The TV is temporarily limiting pairing requests. Wait for the cooldown, then try once.")
            lastError = "Too many pairing requests were sent. Restart the TV, wait a few minutes, then tap Connect only once."
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        if !isReconnectAttempt { reconnectTask?.cancel() }
        intentionallyDisconnected = false
        connectionState = .connecting
        lastError = nil
        do {
            var connectedDevice = device
            let result: LGTVConnectionResult
            do {
                result = try await connection.connect(to: connectedDevice, clientKey: existingKey ?? nil) { [weak self] awaiting in
                    if awaiting { self?.connectionState = .awaitingPairing }
                }
            } catch {
                if !device.useSecureConnection {
                    connectedDevice.useSecureConnection = true
                    result = try await connection.connect(to: connectedDevice, clientKey: existingKey ?? nil) { [weak self] awaiting in
                        if awaiting { self?.connectionState = .awaitingPairing }
                    }
                } else {
                    throw error
                }
            }
            try keychain.save(result.clientKey, account: pairingAccount(device.id))
            connectedDevice.certificateSHA256 = result.certificateSHA256 ?? connectedDevice.certificateSHA256
            if connectedDevice != device { upsert(connectedDevice) }
            clearPairingCooldown()
            connectionState = .connected
            tvState.isOn = true
            tvState.lastUpdated = .now
            await refreshStateAndCapabilities()
        } catch is CancellationError {
            connection.disconnect()
            connectionState = .disconnected
        } catch {
            connection.disconnect()
            if isPairingRateLimit(error) { beginPairingCooldown() }
            lastError = error.localizedDescription
            connectionState = .unavailable(error.localizedDescription)
        }
    }

    func disconnect() {
        intentionallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connection.disconnect()
        connectionState = .disconnected
    }

    func forgetPairing() {
        guard let id = selectedDeviceID else { return }
        disconnect()
        try? keychain.delete(account: pairingAccount(id))
        lastError = "Saved pairing removed. The TV will ask for approval on the next connection."
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if active {
            if selectedDeviceHasPairingKey, !connectionState.isConnected { Task { await connect() } }
        } else {
            disconnect()
        }
    }

    func networkPathChanged(isReachable: Bool) {
        if isReachable {
            intentionallyDisconnected = false
            if isAppActive, selectedDeviceHasPairingKey, !connectionState.isConnected {
                Task { await connect() }
            }
        } else {
            disconnect()
            connectionState = .unavailable("No network connection")
        }
    }

    func powerOff() async {
        guard connectionState.isConnected else { return }
        await perform(LGTVRequests.powerOff, optimistic: { $0.isOn = false })
        disconnect()
    }

    func powerToggle() async {
        guard let device = selectedDevice else { return }
        if connectionState.isConnected {
            await powerOff()
        } else {
            guard let mac = device.macAddress else {
                lastError = LGTVProtocolError.wakeOnLANNotConfigured.localizedDescription
                return
            }
            do {
                try await wakeService.wake(macAddress: mac, host: device.host)
                let delays = [3.0, 4.0, 5.0, 6.0]
                for (index, delay) in delays.enumerated() {
                    connectionState = .reconnecting(attempt: index + 1)
                    try await Task.sleep(for: .seconds(delay))
                    await connect(isReconnectAttempt: true)
                    if connectionState.isConnected { return }
                }
                lastError = "The wake packet was sent, but the TV did not come online. Enable TV On With Mobile and verify the saved MAC address."
                connectionState = .unavailable("TV did not wake")
            } catch is CancellationError {
                connectionState = .disconnected
            } catch { lastError = error.localizedDescription }
        }
    }

    func setVolume(_ volume: Int) async {
        let clamped = min(max(volume, 0), 100)
        await perform(LGTVRequests.setVolume(clamped), optimistic: { $0.volume = clamped })
    }

    func volumeUp() async { await perform(LGTVRequests.volumeUp, optimistic: { $0.volume = min(100, $0.volume + 1) }) }
    func volumeDown() async { await perform(LGTVRequests.volumeDown, optimistic: { $0.volume = max(0, $0.volume - 1) }) }
    func channelUp() async { await perform(LGTVRequests.channelUp) }
    func channelDown() async { await perform(LGTVRequests.channelDown) }
    func toggleMute() async { await perform(LGTVRequests.setMute(!tvState.isMuted), optimistic: { $0.isMuted.toggle() }) }
    func setBrightness(_ value: Int) async {
        let clamped = min(max(value, 0), 100)
        await perform(LGTVRequests.setBrightness(clamped), optimistic: { $0.brightness = clamped })
    }
    func switchInput(_ id: String) async { await perform(LGTVRequests.switchInput(id), optimistic: { $0.currentInputID = id }) }
    func launchApplication(_ id: String) async { await perform(LGTVRequests.launch(id), optimistic: { $0.foregroundApplicationID = id }) }
    func playback(_ command: LGTVPlaybackCommand) async { await perform(LGTVRequests.playback(command)) }

    func send(_ button: LGTVRemoteButton) async {
        do { try await connection.sendRemoteButton(button); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    func refreshStateAndCapabilities() async {
        guard connectionState.isConnected else { return }

        // A subscription is not guaranteed to emit its current value immediately.
        // Fetch a snapshot first so returning to the app never displays a stale
        // volume while waiting for the next physical TV volume change.
        do {
            let volumeResponse = try await connection.request(LGTVRequests.volumeSnapshot)
            applyVolume(volumeResponse)
        } catch {
            lastError = error.localizedDescription
        }

        do {
            try await connection.subscribe(LGTVRequests.volume) { [weak self] message in self?.applyVolume(message) }
        } catch {
            lastError = error.localizedDescription
        }

        // Brightness has no subscription; the setting is queried once per connection and
        // otherwise kept in sync locally through optimistic setBrightness commands.
        do {
            let response = try await connection.request(LGTVRequests.brightnessSnapshot)
            applyPictureSettings(response)
        } catch {
            // Older webOS firmware or a missing CONTROL_DISPLAY grant can reject this request;
            // leave brightness unset rather than showing a value the TV never confirmed.
        }

        do {
            try await connection.subscribe(LGTVRequests.foregroundApp) { [weak self] message in self?.applyForegroundApplication(message) }
        } catch {
            lastError = error.localizedDescription
        }

        do {
            let inputResponse = try await connection.request(LGTVRequests.inputs)
            applyInputs(inputResponse)
        } catch {
            lastError = error.localizedDescription
        }

        do {
            let appResponse = try await connection.request(LGTVRequests.applications)
            applyApplications(appResponse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var connectionStateForExistingConnection: LGTVConnectionState {
        connectionState.isConnected ? .connected : .disconnected
    }

    private func perform(_ request: LGTVRequest, optimistic: ((inout LGTVState) -> Void)? = nil) async {
        guard connectionState.isConnected else {
            lastError = LGTVProtocolError.notConnected.localizedDescription
            return
        }
        let previous = tvState
        optimistic?(&tvState)
        do {
            _ = try await connection.request(request)
            tvState.lastUpdated = .now
            lastError = nil
        } catch {
            tvState = previous
            lastError = error.localizedDescription
        }
    }

    private func applyVolume(_ message: LGTVProtocolMessage) {
        guard let payload = message.payload else { return }
        LGTVStateReducer.applyVolumePayload(payload, to: &tvState)
    }

    private func applyPictureSettings(_ message: LGTVProtocolMessage) {
        guard let payload = message.payload else { return }
        LGTVStateReducer.applyPictureSettingsPayload(payload, to: &tvState)
    }

    private func applyForegroundApplication(_ message: LGTVProtocolMessage) {
        guard let payload = message.payload else { return }
        tvState.foregroundApplicationID = payload["appId"]?.stringValue
        tvState.foregroundApplicationName = payload["appName"]?.stringValue
            ?? tvState.applications.first(where: { $0.id == tvState.foregroundApplicationID })?.name
        tvState.lastUpdated = .now
    }

    private func applyInputs(_ message: LGTVProtocolMessage) {
        let values = message.payload?["devices"]?.arrayValue ?? []
        tvState.inputs = values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue ?? object["inputId"]?.stringValue else { return nil }
            return LGTVInput(
                id: id,
                name: object["label"]?.stringValue ?? object["name"]?.stringValue ?? id,
                iconURL: object["icon"]?.stringValue.flatMap(URL.init(string:))
            )
        }.filter { objectInput in
            let connectedObject = values.first { $0.objectValue?["id"]?.stringValue == objectInput.id }?.objectValue
            return connectedObject?["connected"]?.boolValue ?? true
        }
    }

    private func applyApplications(_ message: LGTVProtocolMessage) {
        guard let payload = message.payload else { return }
        tvState.applications = LGTVApplicationParser.launcherApplications(from: payload)
    }

    private func connectionDropped(_ error: Error?) {
        guard !intentionallyDisconnected, isAppActive, selectedDeviceHasPairingKey else { return }
        lastError = error?.localizedDescription
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...LGTVReconnectPolicy.maximumAttempts where !Task.isCancelled {
                self.connectionState = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: .seconds(LGTVReconnectPolicy.delaySeconds(for: attempt)))
                guard !Task.isCancelled else { return }
                await self.connect(isReconnectAttempt: true)
                if self.connectionState.isConnected { return }
            }
        }
    }

    private func upsert(_ device: LGTVDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id || $0.host.caseInsensitiveCompare(device.host) == .orderedSame }) {
            var updated = device
            updated.id = devices[index].id
            devices[index] = updated
        } else {
            devices.append(device)
        }
        saveConfiguration()
    }

    private func saveConfiguration() {
        persistence.saveDevices(devices)
        persistence.saveSelectedDeviceID(selectedDeviceID)
    }

    // Version 2 requests the pointer and installed-app grants in LG's supported
    // manifest shape. Older keys must not silently retain the incomplete grant.
    private func pairingAccount(_ id: UUID) -> String { "client-key.v2.\(id.uuidString)" }

    private var selectedDeviceHasPairingKey: Bool {
        guard let id = selectedDeviceID else { return false }
        return ((try? keychain.load(account: pairingAccount(id))) ?? nil) != nil
    }

    private func isPairingRateLimit(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("too many pairing requests")
    }

    private func beginPairingCooldown() {
        let duration: TimeInterval = 5 * 60
        pairingCooldownUntil = .now.addingTimeInterval(duration)
        pairingCooldownTask?.cancel()
        pairingCooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.clearPairingCooldown()
        }
    }

    private func clearPairingCooldown() {
        pairingCooldownTask?.cancel()
        pairingCooldownTask = nil
        pairingCooldownUntil = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
