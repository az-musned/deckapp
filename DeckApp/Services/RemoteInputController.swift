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
    var usesMockAgent = true
    var windowsAgentAddress = "https://127.0.0.1:8732"

    private var service: any WindowsRemoteInputServing = MockWindowsRemoteInputService()
    private let defaults: UserDefaults
    private let preferencesKey = "windowsRemote.inputPreferences.v1"
    private let mockModeKey = "windowsAgent.usesMock"
    private let addressKey = "windowsAgent.address"
    private var pointerBuffer = PointerEventBuffer()
    private var flushTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var nextSequence: UInt64 = 1
    private let pairingKeychain = KeychainSecretStore(service: "com.example.DeckApp.windows-agent")

    init(
        service: (any WindowsRemoteInputServing)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        usesMockAgent = defaults.object(forKey: mockModeKey) as? Bool ?? true
        windowsAgentAddress = defaults.string(forKey: addressKey) ?? "https://127.0.0.1:8732"
        self.service = service ?? (usesMockAgent
            ? MockWindowsRemoteInputService()
            : WindowsAgentClient(address: windowsAgentAddress, defaults: defaults))
        if let data = defaults.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(RemoteInputPreferences.self, from: data) {
            preferences = saved
        }
    }

    func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferencesKey)
        defaults.set(usesMockAgent, forKey: mockModeKey)
        defaults.set(windowsAgentAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey)
    }

    func applyAgentConfiguration() async {
        await disconnect()
        windowsAgentAddress = windowsAgentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        service = usesMockAgent
            ? MockWindowsRemoteInputService()
            : WindowsAgentClient(address: windowsAgentAddress, defaults: defaults)
        pairingState = .unknown
        securityState = WindowsAgentSecurityState(remoteInputAllowed: false, inputInjectionAvailable: false, emergencyInputDisabled: false)
        capabilitySnapshot = nil
        agentCommandExecution = nil
        pairingMessage = usesMockAgent
            ? "Using the development mock Agent."
            : "Using the authenticated Windows Agent transport."
        savePreferences()
        await refreshAgentSecurityState()
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
        await service.revokePairing()
        try? pairingKeychain.delete(account: pairingCredentialAccount)
        pairingState = .revoked
        pairingCode = ""
        pairingMessage = usesMockAgent
            ? "This iPad is no longer trusted by the mock Windows Agent."
            : "This iPad credential was revoked by the Windows Agent and deleted from Keychain."
    }

    func connect() async {
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self else { return }
                await self.refreshConnectedSessionState()
            }
        }
    }

    private func refreshConnectedSessionState() async {
        guard connectionState.acceptsInput else { return }
        guard await service.isConnected() else {
            await disconnect()
            connectionState = .disconnected
            lastInteraction = "Agent disconnected"
            return
        }

        let updatedSecurity = await service.securityState()
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
        flushTask?.cancel()
        flushTask = nil
        pointerBuffer = PointerEventBuffer()
        _ = heldState.releaseAll()
        isDragging = false
        connectionState = .unavailable(error.localizedDescription)
        lastInteraction = "Input stopped"
        await service.disconnect()
    }

    private static var nowMilliseconds: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }

    private var pairingCredentialAccount: String {
        usesMockAgent ? "pairing-credential.mock" : "pairing-credential.live"
    }
}
