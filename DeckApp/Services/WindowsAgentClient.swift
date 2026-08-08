import Foundation

actor WindowsAgentClient: WindowsRemoteInputServing {
    private struct PairingStartBody: Encodable {
        let clientDeviceId: String
        let deviceName: String
    }

    private struct PairingChallengeDTO: Decodable {
        let challengeId: UUID
        let expiresAt: String
        let agentDisplayName: String
    }

    private struct PairingConfirmBody: Encodable {
        let challengeId: UUID
        let clientDeviceId: String
        let code: String
    }

    private struct PairingConfirmDTO: Decodable {
        let pairedDeviceId: UUID
        let credentialToken: String
        let protocolVersion: Int
    }

    private struct SecurityDTO: Decodable {
        let remoteInputAllowed: Bool
        let emergencyInputDisabled: Bool
        let inputInjectionAvailable: Bool
        let screenShareAllowed: Bool?
        let protocolVersion: Int
    }

    private struct InputHelloDTO: Decodable {
        let sessionId: UUID
        let protocolVersion: Int
        let status: String
        let serverTimestampMilliseconds: Int64
    }

    private struct InputAcknowledgement: Decodable {
        let lastAcceptedSequence: UInt64
        let appliedCount: Int
        let droppedCount: Int
        let status: String
        let serverTimestampMilliseconds: Int64
    }

    private struct ProtocolErrorDTO: Decodable {
        let status: String
        let message: String
    }

    private struct CapabilitySnapshotDTO: Decodable {
        let applications: [WindowsAgentApplication]
        let audioSessions: [WindowsAudioSessionState]
        let goXlrChannels: [WindowsGoXLRChannelState]
        let goXlrConnected: Bool
        let protocolVersion: Int

        var snapshot: WindowsAgentCapabilitySnapshot {
            WindowsAgentCapabilitySnapshot(
                applications: applications,
                audioSessions: audioSessions,
                goXLRChannels: goXlrChannels,
                goXLRConnected: goXlrConnected
            )
        }
    }

    private struct CapabilityCommandBody: Encodable {
        let command: String
        let id: String
        let value: Double?
        let muted: Bool?
    }

    private struct CapabilityCommandResultDTO: Decodable {
        let confirmed: Bool
        let message: String
        let snapshot: CapabilitySnapshotDTO
        let protocolVersion: Int
    }

    private let protocolVersion = 1
    private let address: String
    private let requestSession: URLSession
    private let webSocketSession: URLSession
    private let clientDeviceID: String
    private var credentialToken: String?
    private var activeChallenge: WindowsAgentPairingChallenge?
    private var pairedAgent: PairedWindowsAgent?
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingAcknowledgements: [UInt64: Date] = [:]
    private(set) var measuredLatencyMilliseconds: Int?
    private var lastKnownSecurityState = WindowsAgentSecurityState(
        remoteInputAllowed: false,
        inputInjectionAvailable: false,
        emergencyInputDisabled: false
    )
    private var lastDisconnectReason: String?

    init(
        address: String,
        session: URLSession? = nil,
        defaults: UserDefaults = .standard,
        requestTimeout: TimeInterval = 8
    ) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            requestSession = session
            webSocketSession = session
        } else {
            let requestConfiguration = URLSessionConfiguration.default
            requestConfiguration.waitsForConnectivity = true
            requestConfiguration.timeoutIntervalForRequest = requestTimeout
            requestConfiguration.timeoutIntervalForResource = max(requestTimeout * 2, requestTimeout)
            requestSession = WindowsAgentURLSessionFactory.make(configuration: requestConfiguration)

            let webSocketConfiguration = URLSessionConfiguration.default
            webSocketConfiguration.waitsForConnectivity = true
            webSocketConfiguration.timeoutIntervalForRequest = 30
            // A WebSocket is an ongoing resource. Keep the long default-scale
            // lifetime and use ping/pong to detect an unhealthy peer instead.
            webSocketConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
            webSocketSession = WindowsAgentURLSessionFactory.make(configuration: webSocketConfiguration)
        }
        let key = "windowsAgent.clientDeviceID"
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            clientDeviceID = saved
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: key)
            clientDeviceID = generated
        }
    }

    func restoreCredential(_ token: String?) async {
        credentialToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if credentialToken?.isEmpty == true { credentialToken = nil }
    }

    func pairingState() async -> WindowsAgentPairingState {
        if let activeChallenge { return .pairing(challengeID: activeChallenge.id, expiresAt: activeChallenge.expiresAt) }
        if let pairedAgent { return .paired(pairedAgent) }
        guard credentialToken != nil else { return .unpaired }
        do {
            let security = try await fetchSecurityState()
            let agent = PairedWindowsAgent(
                id: UUID(),
                displayName: try endpoint().baseURL.host ?? "Windows PC",
                pairedAt: .now,
                protocolVersion: security.protocolVersion
            )
            pairedAgent = agent
            return .paired(agent)
        } catch WindowsRemoteInputError.unpairedClient {
            credentialToken = nil
            return .unpaired
        } catch {
            return .unknown
        }
    }

    func beginPairing(deviceName: String) async throws -> WindowsAgentPairingChallenge {
        let body = try JSONEncoder().encode(PairingStartBody(clientDeviceId: clientDeviceID, deviceName: deviceName))
        let response: PairingChallengeDTO = try await request(method: "POST", path: "/api/v1/pairing/start", body: body, authenticated: false)
        let challenge = WindowsAgentPairingChallenge(
            id: response.challengeId,
            expiresAt: try Self.parseISO8601(response.expiresAt),
            agentDisplayName: response.agentDisplayName
        )
        activeChallenge = challenge
        pairedAgent = nil
        return challenge
    }

    func confirmPairing(challengeID: UUID, code: String) async throws -> WindowsAgentPairingResult {
        guard let challenge = activeChallenge, challenge.id == challengeID, challenge.expiresAt > .now else {
            throw WindowsRemoteInputError.pairingExpired
        }
        let body = try JSONEncoder().encode(PairingConfirmBody(
            challengeId: challengeID,
            clientDeviceId: clientDeviceID,
            code: code
        ))
        let response: PairingConfirmDTO
        do {
            response = try await request(method: "POST", path: "/api/v1/pairing/confirm", body: body, authenticated: false)
        } catch WindowsRemoteInputError.unpairedClient {
            throw WindowsRemoteInputError.invalidPairingCode
        }
        guard response.protocolVersion == protocolVersion else { throw WindowsRemoteInputError.protocolMismatch }
        let agent = PairedWindowsAgent(
            id: response.pairedDeviceId,
            displayName: challenge.agentDisplayName,
            pairedAt: .now,
            protocolVersion: response.protocolVersion
        )
        credentialToken = response.credentialToken
        pairedAgent = agent
        activeChallenge = nil
        return WindowsAgentPairingResult(agent: agent, credentialToken: response.credentialToken)
    }

    func revokePairing() async {
        await disconnect()
        if credentialToken != nil {
            try? await requestWithoutResponse(method: "DELETE", path: "/api/v1/agent/pairing", authenticated: true)
        }
        credentialToken = nil
        pairedAgent = nil
        activeChallenge = nil
    }

    func securityState() async -> WindowsAgentSecurityState {
        for attempt in 0..<3 {
            do {
                return (try await fetchSecurityState()).state
            } catch {
                guard attempt < 2 else { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return lastKnownSecurityState
    }

    func refreshedSecurityState() async throws -> WindowsAgentSecurityState {
        try await fetchSecurityState().state
    }

    func capabilitySnapshot() async -> WindowsAgentCapabilitySnapshot {
        do {
            let response: CapabilitySnapshotDTO = try await request(
                method: "GET", path: "/api/v1/agent/capabilities", body: nil, authenticated: true
            )
            guard response.protocolVersion == protocolVersion else { return Self.emptyCapabilitySnapshot }
            return response.snapshot
        } catch {
            return Self.emptyCapabilitySnapshot
        }
    }

    func perform(_ command: WindowsAgentCapabilityCommand) async throws -> WindowsAgentCommandResult {
        let body: CapabilityCommandBody
        switch command {
        case .launchApplication(let id):
            body = CapabilityCommandBody(command: "launchApplication", id: id, value: nil, muted: nil)
        case .setAudioVolume(let id, let volume):
            body = CapabilityCommandBody(command: "setAudioVolume", id: id, value: volume, muted: nil)
        case .setAudioMuted(let id, let muted):
            body = CapabilityCommandBody(command: "setAudioMuted", id: id, value: nil, muted: muted)
        case .setGoXLRLevel(let id, let level):
            body = CapabilityCommandBody(command: "setGoXlrLevel", id: id, value: level, muted: nil)
        case .setGoXLRMuted(let id, let muted):
            body = CapabilityCommandBody(command: "setGoXlrMuted", id: id, value: nil, muted: muted)
        }
        let response: CapabilityCommandResultDTO = try await request(
            method: "POST",
            path: "/api/v1/agent/commands",
            body: try JSONEncoder().encode(body),
            authenticated: true
        )
        guard response.protocolVersion == protocolVersion,
              response.snapshot.protocolVersion == protocolVersion else {
            throw WindowsRemoteInputError.protocolMismatch
        }
        return WindowsAgentCommandResult(
            command: command,
            confirmed: response.confirmed,
            message: response.message,
            snapshot: response.snapshot.snapshot
        )
    }

    func connect() async throws -> RemoteAgentSession {
        lastDisconnectReason = nil
        let security = try await fetchSecurityState()
        guard security.protocolVersion == protocolVersion else { throw WindowsRemoteInputError.protocolMismatch }
        guard !security.state.emergencyInputDisabled else { throw WindowsRemoteInputError.emergencyInputDisabled }
        guard security.state.remoteInputAllowed else { throw WindowsRemoteInputError.remoteInputDisabled }
        guard security.state.inputInjectionAvailable else { throw WindowsRemoteInputError.inputInjectionUnavailable }
        guard let credentialToken else { throw WindowsRemoteInputError.unpairedClient }

        await disconnect()
        var request = URLRequest(url: try endpoint().url(path: "/api/v1/agent/input", webSocket: true))
        request.setValue("Bearer \(credentialToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let socket = webSocketSession.webSocketTask(with: request)
        let startedAt = Date()
        socket.resume()

        do {
            let message = try await receiveHello(from: socket)
            let hello: InputHelloDTO = try decode(message)
            guard hello.status == "ready", hello.protocolVersion == protocolVersion else {
                throw WindowsRemoteInputError.protocolMismatch
            }
            let latency = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            measuredLatencyMilliseconds = latency
            webSocket = socket
            receiveTask = Task { [weak self] in await self?.receiveLoop(socket: socket) }
            heartbeatTask = Task { [weak self] in await self?.heartbeatLoop(socket: socket) }
            return RemoteAgentSession(
                sessionID: hello.sessionId,
                protocolVersion: hello.protocolVersion,
                route: try endpoint().route,
                latencyMilliseconds: latency,
                remoteInputAllowed: true,
                authenticated: true
            )
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    func send(_ events: [RemoteInputEvent]) async throws {
        guard !events.isEmpty else { return }
        guard let socket = webSocket, socket.state == .running else { throw WindowsRemoteInputError.disconnected }
        let data = try JSONEncoder().encode(WindowsAgentInputBatch(protocolVersion: protocolVersion, events: events))
        guard let text = String(data: data, encoding: .utf8) else { throw WindowsRemoteInputError.invalidResponse }
        if let sequence = events.map(\.sequence).max() { pendingAcknowledgements[sequence] = .now }
        try await socket.send(.string(text))
    }

    func isConnected() async -> Bool {
        webSocket?.state == .running
    }

    func currentLatencyMilliseconds() async -> Int? {
        measuredLatencyMilliseconds
    }

    func disconnectReason() async -> String? {
        lastDisconnectReason
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pendingAcknowledgements.removeAll()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }

    private func fetchSecurityState() async throws -> (state: WindowsAgentSecurityState, protocolVersion: Int) {
        let response: SecurityDTO = try await request(method: "GET", path: "/api/v1/agent/security", body: nil, authenticated: true)
        guard response.protocolVersion == protocolVersion else { throw WindowsRemoteInputError.protocolMismatch }
        let state = WindowsAgentSecurityState(
            remoteInputAllowed: response.remoteInputAllowed,
            inputInjectionAvailable: response.inputInjectionAvailable,
            emergencyInputDisabled: response.emergencyInputDisabled,
            screenShareAllowed: response.screenShareAllowed ?? false
        )
        lastKnownSecurityState = state
        return (
            state,
            response.protocolVersion
        )
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, socket.state == .running {
                let message = try await socket.receive()
                if let acknowledgement: InputAcknowledgement = try? decode(message) {
                    if let sentAt = pendingAcknowledgements.removeValue(forKey: acknowledgement.lastAcceptedSequence) {
                        measuredLatencyMilliseconds = max(1, Int(Date().timeIntervalSince(sentAt) * 1_000))
                    }
                    pendingAcknowledgements = pendingAcknowledgements.filter { $0.key > acknowledgement.lastAcceptedSequence }
                } else if let error: ProtocolErrorDTO = try? decode(message) {
                    lastDisconnectReason = error.message
                    socket.cancel(with: .policyViolation, reason: nil)
                    break
                }
            }
        } catch {
            if !Task.isCancelled {
                lastDisconnectReason = error.localizedDescription
            }
        }
        if webSocket === socket {
            if lastDisconnectReason == nil {
                if let reason = socket.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty {
                    lastDisconnectReason = reason
                } else {
                    lastDisconnectReason = "Windows Agent closed the input connection."
                }
            }
            webSocket = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            pendingAcknowledgements.removeAll()
        }
    }

    private func heartbeatLoop(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, webSocket === socket, socket.state == .running else { return }
                try await sendPing(on: socket)
            } catch {
                guard !Task.isCancelled else { return }
                lastDisconnectReason = "Heartbeat failed: \(error.localizedDescription)"
                socket.cancel(with: .goingAway, reason: nil)
                if webSocket === socket {
                    webSocket = nil
                    receiveTask?.cancel()
                    receiveTask = nil
                    pendingAcknowledgements.removeAll()
                }
                return
            }
        }
    }

    private func sendPing(on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receiveHello(from socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw WindowsRemoteInputError.disconnected
            }
            guard let first = try await group.next() else { throw WindowsRemoteInputError.disconnected }
            group.cancelAll()
            return first
        }
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        body: Data?,
        authenticated: Bool
    ) async throws -> Response {
        let (data, _) = try await performRequest(method: method, path: path, body: body, authenticated: authenticated)
        guard !data.isEmpty else { throw WindowsRemoteInputError.invalidResponse }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw WindowsRemoteInputError.invalidResponse }
    }

    private func requestWithoutResponse(method: String, path: String, authenticated: Bool) async throws {
        _ = try await performRequest(method: method, path: path, body: nil, authenticated: authenticated)
    }

    private func performRequest(
        method: String,
        path: String,
        body: Data?,
        authenticated: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try endpoint().url(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            guard let credentialToken else { throw WindowsRemoteInputError.unpairedClient }
            request.setValue("Bearer \(credentialToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, urlResponse) = try await requestSession.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else { throw WindowsRemoteInputError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw WindowsRemoteInputError.unpairedClient
        case 409:
            throw path == "/api/v1/agent/commands"
                ? WindowsRemoteInputError.capabilityUnavailable
                : WindowsRemoteInputError.inputInjectionUnavailable
        default: throw WindowsRemoteInputError.invalidResponse
        }
    }

    private func endpoint() throws -> WindowsAgentEndpoint {
        do { return try WindowsAgentEndpoint(address) }
        catch { throw WindowsRemoteInputError.invalidAddress }
    }

    private func decode<T: Decodable>(_ message: URLSessionWebSocketTask.Message) throws -> T {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw WindowsRemoteInputError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func parseISO8601(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        throw WindowsRemoteInputError.invalidResponse
    }

    nonisolated private static var emptyCapabilitySnapshot: WindowsAgentCapabilitySnapshot {
        WindowsAgentCapabilitySnapshot(applications: [], audioSessions: [], goXLRChannels: [], goXLRConnected: false)
    }

}
