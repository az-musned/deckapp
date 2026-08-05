import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class RemoteInputController {
    var connectionState: RemoteConnectionState = .disconnected
    var selectedMode: RemoteControlMode = .touchpad
    var preferences = RemoteInputPreferences()
    var heldState = HeldRemoteInputState()
    var isDragging = false
    var lastInteraction = "Ready"
    var sentEventCount = 0
    var pairingState: WindowsAgentPairingState = .unknown
    var securityState = WindowsAgentSecurityState(remoteInputAllowed: false, inputInjectionAvailable: false, emergencyInputDisabled: false)
    var pairingCode = ""
    var pairingMessage = ""
    var capabilitySnapshot: WindowsAgentCapabilitySnapshot?
    var agentCommandExecution: WindowsAgentCommandExecution?
    let goXLR = GoXLRStore()
    var usesMockAgent = true
    var windowsAgentConnectionMode = WindowsAgentConnectionMode.automatic
    var windowsAgentLocalAddress = ""
    var windowsAgentVPNAddress = ""

    var windowsAgentAddressIsValid: Bool {
        usesMockAgent || !configuredAgentAddresses.isEmpty
    }

    var windowsAgentAddressStatus: String {
        guard !usesMockAgent else { return "Deterministic in-app development service" }
        switch windowsAgentConnectionMode {
        case .automatic:
            if configuredAgentAddresses.count == 2 { return "Local preferred · VPN fallback · HTTPS/WSS" }
            if let address = configuredAgentAddresses.first, let endpoint = try? WindowsAgentEndpoint(address) {
                return "Automatic · \(endpoint.route.rawValue) only · HTTPS/WSS"
            }
            return "Enter at least one valid Agent address."
        case .local:
            return endpointStatus(windowsAgentLocalAddress, expectedRoute: .local)
        case .vpn:
            return endpointStatus(windowsAgentVPNAddress, expectedRoute: .vpn)
        }
    }

    private var service: any WindowsRemoteInputServing = MockWindowsRemoteInputService()
    private let defaults: UserDefaults
    private let preferencesKey = "windowsRemote.inputPreferences.v1"
    private let mockModeKey = "windowsAgent.usesMock"
    private let addressKey = "windowsAgent.address"
    private let localAddressKey = "windowsAgent.localAddress"
    private let vpnAddressKey = "windowsAgent.vpnAddress"
    private let connectionModeKey = "windowsAgent.connectionMode"
    private var pointerBuffer = PointerEventBuffer()
    private var flushTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var isRecoveringTransport = false
    private var connectionEpoch: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private let pairingKeychain = KeychainSecretStore(service: "com.example.DeckApp.windows-agent")

    init(
        service: (any WindowsRemoteInputServing)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        usesMockAgent = defaults.object(forKey: mockModeKey) as? Bool ?? true
        windowsAgentLocalAddress = defaults.string(forKey: localAddressKey) ?? ""
        windowsAgentVPNAddress = defaults.string(forKey: vpnAddressKey)
            ?? defaults.string(forKey: addressKey)
            ?? ""
        if let rawMode = defaults.string(forKey: connectionModeKey),
           let savedMode = WindowsAgentConnectionMode(rawValue: rawMode) {
            windowsAgentConnectionMode = savedMode
        }
        self.service = service ?? (usesMockAgent
            ? MockWindowsRemoteInputService()
            : Self.makeAgentService(
                addresses: Self.configuredAddresses(
                    mode: windowsAgentConnectionMode,
                    localAddress: windowsAgentLocalAddress,
                    vpnAddress: windowsAgentVPNAddress
                ),
                defaults: defaults
            ))
        if let data = defaults.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(RemoteInputPreferences.self, from: data) {
            preferences = saved
        }
        goXLR.attach(controller: self)
    }

    func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferencesKey)
        defaults.set(usesMockAgent, forKey: mockModeKey)
        defaults.set(windowsAgentConnectionMode.rawValue, forKey: connectionModeKey)
        defaults.set(windowsAgentLocalAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: localAddressKey)
        defaults.set(windowsAgentVPNAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: vpnAddressKey)
    }

    func applyAgentConfiguration() async {
        await disconnect()
        windowsAgentLocalAddress = windowsAgentLocalAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        windowsAgentVPNAddress = windowsAgentVPNAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !usesMockAgent, configuredAgentAddresses.isEmpty {
            pairingState = .unpaired
            securityState = WindowsAgentSecurityState(remoteInputAllowed: false, inputInjectionAvailable: false, emergencyInputDisabled: false)
            capabilitySnapshot = nil
            pairingMessage = windowsAgentAddressStatus
            connectionState = .unavailable(windowsAgentAddressStatus)
            savePreferences()
            return
        }
        service = usesMockAgent
            ? MockWindowsRemoteInputService()
            : Self.makeAgentService(addresses: configuredAgentAddresses, defaults: defaults)
        pairingState = .unknown
        securityState = WindowsAgentSecurityState(remoteInputAllowed: false, inputInjectionAvailable: false, emergencyInputDisabled: false)
        capabilitySnapshot = nil
        agentCommandExecution = nil
        pairingMessage = usesMockAgent
            ? "Using the development mock Agent."
            : "Using the authenticated Windows Agent transport."
        savePreferences()
        await refreshAgentSecurityState()
        await goXLR.agentConfigurationChanged()
    }

    private var configuredAgentAddresses: [String] {
        Self.configuredAddresses(
            mode: windowsAgentConnectionMode,
            localAddress: windowsAgentLocalAddress,
            vpnAddress: windowsAgentVPNAddress
        )
    }

    private func endpointStatus(_ address: String, expectedRoute: RemoteConnectionRoute?) -> String {
        guard let endpoint = try? WindowsAgentEndpoint(address), expectedRoute == nil || endpoint.route == expectedRoute else {
            return expectedRoute == .local ? "Enter a valid private LAN HTTPS address." : "Enter a valid Tailscale HTTPS address."
        }
        return "\(endpoint.route.rawValue) · HTTPS/WSS · \(endpoint.displayAddress)"
    }

    private static func configuredAddresses(
        mode: WindowsAgentConnectionMode,
        localAddress: String,
        vpnAddress: String
    ) -> [String] {
        let local = localAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let vpn = vpnAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let validLocal = (try? WindowsAgentEndpoint(local)).flatMap { $0.route == .local ? local : nil }
        let validVPN = (try? WindowsAgentEndpoint(vpn)).flatMap { $0.route == .vpn ? vpn : nil }
        switch mode {
        case .automatic: return [validLocal, validVPN].compactMap { $0 }
        case .local: return [validLocal].compactMap { $0 }
        case .vpn: return [validVPN].compactMap { $0 }
        }
    }

    private static func makeAgentService(addresses: [String], defaults: UserDefaults) -> any WindowsRemoteInputServing {
        if addresses.count == 1, let address = addresses.first {
            return WindowsAgentClient(address: address, defaults: defaults)
        }
        return FailoverWindowsAgentService(addresses: addresses, defaults: defaults)
    }

    func refreshAgentSecurityState() async {
        let credential = try? pairingKeychain.load(account: pairingCredentialAccount)
        await service.restoreCredential(credential ?? nil)
        pairingState = await service.pairingState()
        securityState = await service.securityState()
        let snapshot = await service.capabilitySnapshot()
        capabilitySnapshot = snapshot.applications.isEmpty
            && snapshot.audioSessions.isEmpty
            && snapshot.goXLRChannels.isEmpty
            && !snapshot.goXLRConnected ? nil : snapshot
        goXLR.syncControlChannels(snapshot.goXLRChannels)
    }

    /// Refresh only the capability snapshot used by live GoXLR controls. Unlike the
    /// broader security refresh, this is safe to call at a modest UI polling cadence.
    func refreshGoXLRControlState() async {
        guard pairingState.isPaired else { return }
        let snapshot = await service.capabilitySnapshot()
        // The transport represents request failures as an empty snapshot. Preserve the
        // last known control values instead of making every fader jump to an empty state.
        guard snapshot.goXLRConnected || !snapshot.goXLRChannels.isEmpty else { return }
        capabilitySnapshot = snapshot
        goXLR.syncControlChannels(snapshot.goXLRChannels)
    }

    func beginPairing() async {
        await disconnect()
        do {
            let challenge = try await service.beginPairing(deviceName: UIDevice.current.name)
            pairingState = .pairing(challengeID: challenge.id, expiresAt: challenge.expiresAt)
            pairingCode = ""
            pairingMessage = usesMockAgent
                ? "Enter the six-digit code shown by \(challenge.agentDisplayName). Mock code: 482913"
                : "Enter the six-digit code displayed locally by \(challenge.agentDisplayName)."
        } catch {
            pairingMessage = error.localizedDescription
        }
    }

    func confirmPairing() async {
        guard case .pairing(let challengeID, _) = pairingState else { return }
        do {
            let result = try await service.confirmPairing(
                challengeID: challengeID,
                code: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try pairingKeychain.save(result.credentialToken, account: pairingCredentialAccount)
            pairingState = .paired(result.agent)
            pairingCode = ""
            pairingMessage = "Pairing credential saved securely in Keychain."
            securityState = await service.securityState()
        } catch {
            pairingMessage = error.localizedDescription
        }
    }

    func revokePairing() async {
        await disconnect()
        await goXLR.agentDidDisconnect()
        await service.revokePairing()
        try? pairingKeychain.delete(account: pairingCredentialAccount)
        pairingState = .revoked
        pairingCode = ""
        pairingMessage = usesMockAgent
            ? "This iPad is no longer trusted by the mock Windows Agent."
            : "This iPad credential was revoked by the Windows Agent and deleted from Keychain."
    }

    func connect() async {
        connectionEpoch &+= 1
        await refreshAgentSecurityState()
        guard pairingState.isPaired else {
            connectionState = .authenticationRejected
            pairingMessage = "Pair this device before connecting."
            return
        }
        connectionState = .connecting
        do {
            let session = try await service.connect()
            guard session.authenticated else {
                connectionState = .authenticationRejected
                return
            }
            guard session.remoteInputAllowed else {
                connectionState = .permissionDisabled
                return
            }
            connectionState = session.latencyMilliseconds >= 80
                ? .highLatency(route: session.route, latencyMilliseconds: session.latencyMilliseconds)
                : .connected(route: session.route, latencyMilliseconds: session.latencyMilliseconds)
            securityState = await service.securityState()
            lastInteraction = "Authenticated Agent session"
            startConnectionMonitor()
        } catch WindowsRemoteInputError.unpairedClient {
            connectionState = .authenticationRejected
        } catch WindowsRemoteInputError.remoteInputDisabled {
            connectionState = .permissionDisabled
        } catch WindowsRemoteInputError.emergencyInputDisabled {
            connectionState = .emergencyDisabled
        } catch {
            connectionState = .unavailable(error.localizedDescription)
        }
    }

    func disconnect() async {
        connectionEpoch &+= 1
        isRecoveringTransport = false
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        flushTask?.cancel()
        flushTask = nil
        pointerBuffer = PointerEventBuffer()

        if connectionState.acceptsInput {
            let release = heldState.releaseAll()
            try? await service.send(makeEvents([release]))
        } else {
            _ = heldState.releaseAll()
        }
        isDragging = false
        await service.disconnect()
        connectionState = .disconnected
        lastInteraction = "Input paused"
    }

    private func startConnectionMonitor() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                await self.refreshConnectedSessionState(checkSecurity: tick % 7 == 0)
            }
        }
    }

    private func refreshConnectedSessionState(checkSecurity: Bool) async {
        guard connectionState.acceptsInput else { return }
        guard await service.isConnected() else {
            let reason = await service.disconnectReason()
            await recoverTransport(after: reason ?? "Agent disconnected")
            return
        }

        if let latency = await service.currentLatencyMilliseconds() {
            switch connectionState {
            case .connected(let route, _), .highLatency(let route, _):
                connectionState = latency >= 80
                    ? .highLatency(route: route, latencyMilliseconds: latency)
                    : .connected(route: route, latencyMilliseconds: latency)
            default:
                break
            }
        }

        guard checkSecurity else { return }

        let updatedSecurity: WindowsAgentSecurityState
        do {
            updatedSecurity = try await service.refreshedSecurityState()
        } catch WindowsRemoteInputError.unpairedClient {
            await disconnect()
            connectionState = .authenticationRejected
            lastInteraction = "Windows Agent revoked this device"
            return
        } catch WindowsRemoteInputError.protocolMismatch {
            await disconnect()
            connectionState = .unavailable(WindowsRemoteInputError.protocolMismatch.localizedDescription)
            lastInteraction = "Agent protocol changed"
            return
        } catch {
            // A failed status refresh must not override a live authenticated
            // WebSocket. The Agent closes that socket itself for safety changes.
            return
        }

        securityState = updatedSecurity
        if updatedSecurity.emergencyInputDisabled {
            await disconnect()
            connectionState = .emergencyDisabled
            lastInteraction = "Emergency Disable Input active"
        } else if !updatedSecurity.remoteInputAllowed {
            await disconnect()
            connectionState = .permissionDisabled
            lastInteraction = "Input disabled on Windows"
        } else if !updatedSecurity.inputInjectionAvailable {
            await disconnect()
            connectionState = .unavailable("Windows input injection is unavailable in the current desktop state.")
            lastInteraction = "Windows desktop unavailable"
        }
    }

    func pauseForUnsafeState() async {
        guard connectionState.acceptsInput else { return }
        await disconnect()
    }

    func enqueuePointer(deltaX: Double, deltaY: Double) {
        guard connectionState.acceptsInput else { return }
        let precisionScale = preferences.precisionMode ? 0.35 : 1
        let scale = preferences.pointerSensitivity * precisionScale
        pointerBuffer.enqueuePointer(
            deltaX: deltaX * scale,
            deltaY: deltaY * scale,
            timestampMilliseconds: Self.nowMilliseconds
        )
        lastInteraction = preferences.precisionMode ? "Precision pointer" : "Pointer"
        scheduleFlush()
    }

    func enqueueScroll(deltaX: Double, deltaY: Double) {
        guard connectionState.acceptsInput else { return }
        let direction = preferences.naturalScrolling ? 1.0 : -1.0
        let scale = preferences.scrollSensitivity * direction
        pointerBuffer.enqueueScroll(
            deltaX: deltaX * scale,
            deltaY: deltaY * scale,
            timestampMilliseconds: Self.nowMilliseconds
        )
        lastInteraction = "Scrolling"
        scheduleFlush()
    }

    func click(_ button: RemoteMouseButton) {
        guard connectionState.acceptsInput else { return }
        lastInteraction = "\(button.rawValue.capitalized) click"
        sendImmediately([
            .mouseButton(button, isDown: true),
            .mouseButton(button, isDown: false)
        ])
    }

    func setDrag(active: Bool) {
        guard connectionState.acceptsInput, active != isDragging else { return }
        isDragging = active
        if active {
            heldState.mouseButtons.insert(.left)
            lastInteraction = "Dragging"
        } else {
            heldState.mouseButtons.remove(.left)
            lastInteraction = "Drag released"
        }
        sendImmediately([.mouseButton(.left, isDown: active)])
    }

    func toggleModifier(_ modifier: RemoteModifiers) {
        guard connectionState.acceptsInput else { return }
        let isDown = !heldState.modifiers.contains(modifier)
        if isDown {
            heldState.modifiers.insert(modifier)
        } else {
            heldState.modifiers.remove(modifier)
        }
        lastInteraction = isDown ? "Modifier held" : "Modifier released"
        sendImmediately([.modifier(modifier, isDown: isDown)])
    }

    func sendKey(_ key: RemoteVirtualKey) {
        guard connectionState.acceptsInput else { return }
        lastInteraction = key.rawValue
        sendImmediately([
            .virtualKey(key, isDown: true, modifiers: heldState.modifiers),
            .virtualKey(key, isDown: false, modifiers: heldState.modifiers)
        ])
    }

    func sendText(_ text: String) {
        guard connectionState.acceptsInput, !text.isEmpty else { return }
        lastInteraction = "Text sent"
        sendImmediately([.unicodeText(text)])
    }

    func sendClipboardText(_ text: String, pasteAfterCopy: Bool, userInitiated: Bool) {
        guard connectionState.acceptsInput,
              let payload = RemoteClipboardPolicy.payload(
                text: text,
                pasteAfterCopy: pasteAfterCopy,
                userInitiated: userInitiated
              ) else { return }
        lastInteraction = pasteAfterCopy ? "Clipboard sent and pasted" : "Clipboard sent"
        sendImmediately([payload])
    }

    func launchApplication(id: String) async {
        await performAgentCommand(.launchApplication(id: id))
    }

    func setAudioVolume(id: String, volume: Double) async {
        await performAgentCommand(.setAudioVolume(id: id, volume: volume))
    }

    func setAudioMuted(id: String, muted: Bool) async {
        await performAgentCommand(.setAudioMuted(id: id, muted: muted))
    }

    func setGoXLRLevel(id: String, level: Double) async {
        await performAgentCommand(.setGoXLRLevel(id: id, level: level))
    }

    func setGoXLRMuted(id: String, muted: Bool) async {
        await performAgentCommand(.setGoXLRMuted(id: id, muted: muted))
    }

    private func performAgentCommand(_ command: WindowsAgentCapabilityCommand) async {
        guard pairingState.isPaired else {
            agentCommandExecution = WindowsAgentCommandExecution(
                command: command,
                status: .unavailable,
                message: "Pair this device with the Windows Agent first."
            )
            return
        }

        var execution = WindowsAgentCommandExecution(
            command: command,
            status: .pending,
            message: "Waiting for the authenticated Windows Agent…"
        )
        agentCommandExecution = execution
        await Task.yield()

        execution.status = .running
        execution.message = "Request accepted; waiting for reported backend state…"
        agentCommandExecution = execution

        do {
            let result = try await service.perform(command)
            capabilitySnapshot = result.snapshot
            goXLR.syncControlChannels(result.snapshot.goXLRChannels)
            execution.status = result.confirmed ? .confirmed : .failed
            execution.message = result.message
        } catch WindowsRemoteInputError.unpairedClient {
            pairingState = .unpaired
            execution.status = .unavailable
            execution.message = "The Windows Agent rejected this unpaired device."
        } catch WindowsRemoteInputError.capabilityUnavailable {
            execution.status = .unavailable
            execution.message = WindowsRemoteInputError.capabilityUnavailable.localizedDescription
        } catch {
            execution.status = .failed
            execution.message = error.localizedDescription
        }
        agentCommandExecution = execution
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.flushPointerBuffer()
        }
    }

    private func flushPointerBuffer() {
        flushTask = nil
        let payloads = pointerBuffer.drain(
            nowMilliseconds: Self.nowMilliseconds,
            acceleration: preferences.pointerAcceleration,
            precision: preferences.precisionMode
        )
        guard !payloads.isEmpty else { return }
        sendImmediately(payloads)
    }

    private func sendImmediately(_ payloads: [RemoteInputPayload]) {
        let events = makeEvents(payloads)
        sentEventCount += events.count
        Task { [weak self, service] in
            do {
                try await service.send(events)
            } catch {
                await self?.handleTransportFailure(error)
            }
        }
    }

    private func makeEvents(_ payloads: [RemoteInputPayload]) -> [RemoteInputEvent] {
        payloads.map { payload in
            defer { nextSequence += 1 }
            return RemoteInputEvent(
                sequence: nextSequence,
                timestampMilliseconds: Self.nowMilliseconds,
                payload: payload
            )
        }
    }

    private func handleTransportFailure(_ error: Error) async {
        await recoverTransport(after: error.localizedDescription)
    }

    private func recoverTransport(after reason: String) async {
        guard !isRecoveringTransport else { return }
        guard connectionState.acceptsInput || connectionState == .connecting else { return }
        isRecoveringTransport = true
        let recoveryEpoch = connectionEpoch

        flushTask?.cancel()
        flushTask = nil
        pointerBuffer = PointerEventBuffer()
        _ = heldState.releaseAll()
        isDragging = false
        await service.disconnect()

        var finalError = reason
        let delays: [Duration] = [.milliseconds(250), .milliseconds(750), .seconds(1.5), .seconds(3)]
        for delay in delays {
            guard recoveryEpoch == connectionEpoch else {
                isRecoveringTransport = false
                return
            }

            connectionState = .connecting
            lastInteraction = "Reconnecting…"
            do {
                try await Task.sleep(for: delay)
                guard recoveryEpoch == connectionEpoch else {
                    isRecoveringTransport = false
                    return
                }
                let session = try await service.connect()
                guard recoveryEpoch == connectionEpoch else {
                    await service.disconnect()
                    isRecoveringTransport = false
                    return
                }
                connectionState = session.latencyMilliseconds >= 80
                    ? .highLatency(route: session.route, latencyMilliseconds: session.latencyMilliseconds)
                    : .connected(route: session.route, latencyMilliseconds: session.latencyMilliseconds)
                lastInteraction = "Reconnected · \(session.latencyMilliseconds) ms"
                isRecoveringTransport = false
                return
            } catch WindowsRemoteInputError.unpairedClient {
                connectionState = .authenticationRejected
                lastInteraction = "Windows Agent revoked this device"
                isRecoveringTransport = false
                return
            } catch WindowsRemoteInputError.remoteInputDisabled {
                connectionState = .permissionDisabled
                lastInteraction = "Input disabled on Windows"
                isRecoveringTransport = false
                return
            } catch WindowsRemoteInputError.emergencyInputDisabled {
                connectionState = .emergencyDisabled
                lastInteraction = "Emergency Disable Input active"
                isRecoveringTransport = false
                return
            } catch {
                finalError = error.localizedDescription
            }
        }

        guard recoveryEpoch == connectionEpoch else {
            isRecoveringTransport = false
            return
        }
        connectionState = .unavailable(finalError)
        lastInteraction = "Reconnect failed"
        isRecoveringTransport = false
    }

    private static var nowMilliseconds: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }

    private var pairingCredentialAccount: String {
        usesMockAgent ? "pairing-credential.mock" : "pairing-credential.live"
    }

    var goXLRAudioConfiguration: GoXLRAudioConfiguration? {
        guard !usesMockAgent,
              !configuredAgentAddresses.isEmpty,
              let credential = try? pairingKeychain.load(account: pairingCredentialAccount),
              !credential.isEmpty else { return nil }
        return GoXLRAudioConfiguration(addresses: configuredAgentAddresses, credential: credential)
    }
}
