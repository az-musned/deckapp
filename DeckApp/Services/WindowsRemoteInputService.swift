import Foundation

protocol WindowsRemoteInputServing: Sendable {
    func restoreCredential(_ token: String?) async
    func pairingState() async -> WindowsAgentPairingState
    func beginPairing(deviceName: String) async throws -> WindowsAgentPairingChallenge
    func confirmPairing(challengeID: UUID, code: String) async throws -> WindowsAgentPairingResult
    func revokePairing() async
    func securityState() async -> WindowsAgentSecurityState
    func refreshedSecurityState() async throws -> WindowsAgentSecurityState
    func capabilitySnapshot() async -> WindowsAgentCapabilitySnapshot
    func perform(_ command: WindowsAgentCapabilityCommand) async throws -> WindowsAgentCommandResult
    func connect() async throws -> RemoteAgentSession
    func isConnected() async -> Bool
    func currentLatencyMilliseconds() async -> Int?
    func disconnectReason() async -> String?
    func send(_ events: [RemoteInputEvent]) async throws
    func disconnect() async
    func sendHotkey(keyCode: Int, modifiers: Int) async throws
}

enum WindowsRemoteInputError: LocalizedError, Equatable {
    case unpairedClient
    case remoteInputDisabled
    case disconnected
    case inputInjectionUnavailable
    case invalidPairingCode
    case pairingExpired
    case emergencyInputDisabled
    case capabilityUnavailable
    case invalidAddress
    case invalidResponse
    case protocolMismatch

    var errorDescription: String? {
        switch self {
        case .unpairedClient: "The Windows Agent rejected this unpaired device."
        case .remoteInputDisabled: "Allow Remote Input is disabled on the Windows PC."
        case .disconnected: "The Windows Agent connection is unavailable."
        case .inputInjectionUnavailable: "Windows input injection is unavailable in the current desktop state."
        case .invalidPairingCode: "The pairing code was rejected by the Windows Agent."
        case .pairingExpired: "The pairing request expired. Start pairing again."
        case .emergencyInputDisabled: "The Windows Agent emergency Disable Input control is active."
        case .capabilityUnavailable: "The requested Windows Agent capability is unavailable."
        case .invalidAddress: "Enter a valid HTTPS Windows Agent address."
        case .invalidResponse: "The Windows Agent returned an invalid or unsuccessful response."
        case .protocolMismatch: "The Windows Agent protocol version is incompatible with this app."
        }
    }
}

actor MockWindowsRemoteInputService: WindowsRemoteInputServing {
    private var paired: Bool
    private let remoteInputAllowed: Bool
    private let route: RemoteConnectionRoute
    private let latencyMilliseconds: Int
    private let inputInjectionAvailable: Bool
    private let emergencyInputDisabled: Bool
    private var activeChallenge: WindowsAgentPairingChallenge?
    private var pairedAgent: PairedWindowsAgent?
    private var connected = false
    private var receivedEvents: [RemoteInputEvent] = []
    private var applications = [
        WindowsAgentApplication(id: "steam", name: "Steam", kind: .application, isRunning: true),
        WindowsAgentApplication(id: "game.primary", name: "Configured Game", kind: .game, isRunning: false)
    ]
    private var audioSessions = [
        WindowsAudioSessionState(id: "system", name: "System", volume: 0.55, isMuted: false),
        WindowsAudioSessionState(id: "music", name: "Music", volume: 0.62, isMuted: false),
        WindowsAudioSessionState(id: "voice", name: "Voice Chat", volume: 0.78, isMuted: false)
    ]
    private var goXLRChannels = [
        WindowsGoXLRChannelState(id: "mic", name: "Mic", level: 0.76, isMuted: false),
        WindowsGoXLRChannelState(id: "music", name: "Music", level: 0.62, isMuted: false),
        WindowsGoXLRChannelState(id: "system", name: "System", level: 0.55, isMuted: false)
    ]

    init(
        paired: Bool = true,
        remoteInputAllowed: Bool = true,
        route: RemoteConnectionRoute = .local,
        latencyMilliseconds: Int = 9,
        inputInjectionAvailable: Bool = true,
        emergencyInputDisabled: Bool = false
    ) {
        self.paired = paired
        self.remoteInputAllowed = remoteInputAllowed
        self.route = route
        self.latencyMilliseconds = latencyMilliseconds
        self.inputInjectionAvailable = inputInjectionAvailable
        self.emergencyInputDisabled = emergencyInputDisabled
        if paired {
            pairedAgent = PairedWindowsAgent(id: UUID(), displayName: "Mock Windows PC", pairedAt: .now, protocolVersion: 1)
        }
    }

    func restoreCredential(_ token: String?) async {
        if token != nil, pairedAgent == nil {
            paired = true
            pairedAgent = PairedWindowsAgent(id: UUID(), displayName: "Mock Windows PC", pairedAt: .now, protocolVersion: 1)
        }
    }

    func pairingState() async -> WindowsAgentPairingState {
        if let activeChallenge { return .pairing(challengeID: activeChallenge.id, expiresAt: activeChallenge.expiresAt) }
        if let pairedAgent, paired { return .paired(pairedAgent) }
        return .unpaired
    }

    func beginPairing(deviceName: String) async throws -> WindowsAgentPairingChallenge {
        let challenge = WindowsAgentPairingChallenge(id: UUID(), expiresAt: .now.addingTimeInterval(120), agentDisplayName: "Mock Windows PC")
        activeChallenge = challenge
        paired = false
        pairedAgent = nil
        return challenge
    }

    func confirmPairing(challengeID: UUID, code: String) async throws -> WindowsAgentPairingResult {
        guard let challenge = activeChallenge, challenge.id == challengeID else { throw WindowsRemoteInputError.pairingExpired }
        guard challenge.expiresAt > .now else { activeChallenge = nil; throw WindowsRemoteInputError.pairingExpired }
        guard code == "482913" else { throw WindowsRemoteInputError.invalidPairingCode }
        let agent = PairedWindowsAgent(id: UUID(), displayName: challenge.agentDisplayName, pairedAt: .now, protocolVersion: 1)
        paired = true
        pairedAgent = agent
        activeChallenge = nil
        return WindowsAgentPairingResult(agent: agent, credentialToken: UUID().uuidString)
    }

    func revokePairing() async {
        connected = false
        paired = false
        pairedAgent = nil
        activeChallenge = nil
    }

    func securityState() async -> WindowsAgentSecurityState {
        WindowsAgentSecurityState(
            remoteInputAllowed: remoteInputAllowed,
            inputInjectionAvailable: inputInjectionAvailable,
            emergencyInputDisabled: emergencyInputDisabled
        )
    }

    func refreshedSecurityState() async throws -> WindowsAgentSecurityState {
        await securityState()
    }

    func capabilitySnapshot() async -> WindowsAgentCapabilitySnapshot {
        WindowsAgentCapabilitySnapshot(
            applications: applications,
            audioSessions: audioSessions,
            goXLRChannels: goXLRChannels,
            goXLRConnected: true
        )
    }

    func perform(_ command: WindowsAgentCapabilityCommand) async throws -> WindowsAgentCommandResult {
        // Capability commands require a trusted client, but intentionally do not
        // depend on the separate Allow Remote Input permission.
        guard paired else { throw WindowsRemoteInputError.unpairedClient }
        try await Task.sleep(for: .milliseconds(180))

        let message: String
        switch command {
        case .launchApplication(let id):
            guard let index = applications.firstIndex(where: { $0.id == id }) else {
                throw WindowsRemoteInputError.capabilityUnavailable
            }
            let application = applications[index]
            applications[index] = WindowsAgentApplication(
                id: application.id,
                name: application.name,
                kind: application.kind,
                isRunning: true
            )
            message = applications[index].isRunning
                ? "Confirmed running by Windows Agent state."
                : "The application did not report a running state."

        case .setAudioVolume(let id, let volume):
            guard let index = audioSessions.firstIndex(where: { $0.id == id }) else {
                throw WindowsRemoteInputError.capabilityUnavailable
            }
            let session = audioSessions[index]
            audioSessions[index] = WindowsAudioSessionState(
                id: session.id,
                name: session.name,
                volume: min(max(volume, 0), 1),
                isMuted: session.isMuted
            )
            message = "Confirmed by Windows audio-session state."

        case .setAudioMuted(let id, let muted):
            guard let index = audioSessions.firstIndex(where: { $0.id == id }) else {
                throw WindowsRemoteInputError.capabilityUnavailable
            }
            let session = audioSessions[index]
            audioSessions[index] = WindowsAudioSessionState(
                id: session.id,
                name: session.name,
                volume: session.volume,
                isMuted: muted
            )
            message = "Confirmed by Windows audio-session state."

        case .setGoXLRLevel(let id, let level):
            guard let index = goXLRChannels.firstIndex(where: { $0.id == id }) else {
                throw WindowsRemoteInputError.capabilityUnavailable
            }
            let channel = goXLRChannels[index]
            goXLRChannels[index] = WindowsGoXLRChannelState(
                id: channel.id,
                name: channel.name,
                level: min(max(level, 0), 1),
                isMuted: channel.isMuted
            )
            message = "Confirmed by GoXLR channel state."

        case .setGoXLRMuted(let id, let muted):
            guard let index = goXLRChannels.firstIndex(where: { $0.id == id }) else {
                throw WindowsRemoteInputError.capabilityUnavailable
            }
            let channel = goXLRChannels[index]
            goXLRChannels[index] = WindowsGoXLRChannelState(
                id: channel.id,
                name: channel.name,
                level: channel.level,
                isMuted: muted
            )
            message = "Confirmed by GoXLR channel state."
        }

        return WindowsAgentCommandResult(
            command: command,
            confirmed: true,
            message: message,
            snapshot: await capabilitySnapshot()
        )
    }

    func connect() async throws -> RemoteAgentSession {
        guard paired else { throw WindowsRemoteInputError.unpairedClient }
        guard !emergencyInputDisabled else { throw WindowsRemoteInputError.emergencyInputDisabled }
        guard remoteInputAllowed else { throw WindowsRemoteInputError.remoteInputDisabled }
        guard inputInjectionAvailable else { throw WindowsRemoteInputError.inputInjectionUnavailable }
        try await Task.sleep(for: .milliseconds(220))
        connected = true
        return RemoteAgentSession(
            sessionID: UUID(),
            protocolVersion: 1,
            route: route,
            latencyMilliseconds: latencyMilliseconds,
            remoteInputAllowed: true,
            authenticated: true
        )
    }

    func isConnected() async -> Bool { connected }

    func currentLatencyMilliseconds() async -> Int? { latencyMilliseconds }

    func disconnectReason() async -> String? { nil }

    func send(_ events: [RemoteInputEvent]) async throws {
        guard connected else { throw WindowsRemoteInputError.disconnected }
        guard remoteInputAllowed else { throw WindowsRemoteInputError.remoteInputDisabled }

        let prioritized = events.sorted { lhs, rhs in
            lhs.payload.isReleasePriority && !rhs.payload.isReleasePriority
        }
        receivedEvents.append(contentsOf: prioritized.map(redactedForMockCapture))
    }

    func disconnect() async {
        connected = false
    }

    func sendHotkey(keyCode: Int, modifiers: Int) async throws {
        guard paired else { throw WindowsRemoteInputError.unpairedClient }
        try await Task.sleep(for: .milliseconds(120))
    }

    func capturedEvents() -> [RemoteInputEvent] {
        receivedEvents
    }

    private func redactedForMockCapture(_ event: RemoteInputEvent) -> RemoteInputEvent {
        let payload: RemoteInputPayload
        switch event.payload {
        case .unicodeText:
            payload = .unicodeText("<redacted>")
        case .clipboardText(_, let pasteAfterCopy):
            payload = .clipboardText("<redacted>", pasteAfterCopy: pasteAfterCopy)
        default:
            payload = event.payload
        }
        return RemoteInputEvent(
            id: event.id,
            sequence: event.sequence,
            timestampMilliseconds: event.timestampMilliseconds,
            payload: payload
        )
    }
}
