import Foundation

protocol DiscordBridgeServing: Sendable {
    func start(
        addresses: [String],
        credential: String,
        transport: @escaping @Sendable (AudioMeterConnectionState) -> Void,
        status: @escaping @Sendable (DiscordStatusMessage) -> Void,
        guilds: @escaping @Sendable ([DiscordGuildSummary]) -> Void,
        channels: @escaping @Sendable (String, [DiscordChannelSummary]) -> Void
    ) async
    func stop() async
    func send(_ command: DiscordCommand) async
}

/// Talks to the Windows Agent's `/api/v1/discord/ws` bridge. Mirrors `GoXLRAudioMeterClient`'s
/// reconnect-with-backoff shape, but bidirectional: besides receiving pushed state it also sends
/// mute/deafen/join/leave/list commands over the same socket.
actor DiscordClient: DiscordBridgeServing {
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
            self.session = WindowsAgentURLSessionFactory.make(configuration: configuration)
        }
    }

    func start(
        addresses: [String],
        credential: String,
        transport: @escaping @Sendable (AudioMeterConnectionState) -> Void,
        status: @escaping @Sendable (DiscordStatusMessage) -> Void,
        guilds: @escaping @Sendable ([DiscordGuildSummary]) -> Void,
        channels: @escaping @Sendable (String, [DiscordChannelSummary]) -> Void
    ) async {
        await stop()
        guard !addresses.isEmpty, !credential.isEmpty else {
            transport(.failed("Pair the Windows Agent before connecting Discord."))
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        runTask = Task(priority: .utility) { [weak self] in
            await self?.run(
                generation: currentGeneration,
                addresses: addresses,
                credential: credential,
                transport: transport,
                status: status,
                guilds: guilds,
                channels: channels
            )
        }
    }

    func stop() async {
        generation = UUID()
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func send(_ command: DiscordCommand) async {
        guard let socket, socket.state == .running,
              let data = try? JSONEncoder().encode(command.body),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }

    private func run(
        generation: UUID,
        addresses: [String],
        credential: String,
        transport: @escaping @Sendable (AudioMeterConnectionState) -> Void,
        status: @escaping @Sendable (DiscordStatusMessage) -> Void,
        guilds: @escaping @Sendable ([DiscordGuildSummary]) -> Void,
        channels: @escaping @Sendable (String, [DiscordChannelSummary]) -> Void
    ) async {
        var attempt = 0
        while !Task.isCancelled, self.generation == generation {
            transport(attempt == 0 ? .connecting : .reconnecting)
            var lastError: Error = WindowsRemoteInputError.disconnected
            for address in addresses where !Task.isCancelled {
                do {
                    try await receiveStream(
                        address: address,
                        credential: credential,
                        generation: generation,
                        transport: transport,
                        status: status,
                        guilds: guilds,
                        channels: channels
                    )
                } catch {
                    lastError = error
                }
                guard self.generation == generation else { return }
            }
            attempt += 1
            transport(.failed(lastError.localizedDescription))
            let delay = min(pow(2, Double(min(attempt - 1, 4))) * 0.5, 8)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveStream(
        address: String,
        credential: String,
        generation: UUID,
        transport: @escaping @Sendable (AudioMeterConnectionState) -> Void,
        status: @escaping @Sendable (DiscordStatusMessage) -> Void,
        guilds: @escaping @Sendable ([DiscordGuildSummary]) -> Void,
        channels: @escaping @Sendable (String, [DiscordChannelSummary]) -> Void
    ) async throws {
        let endpoint = try WindowsAgentEndpoint(address)
        var request = URLRequest(url: try endpoint.url(path: "/api/v1/discord/ws", webSocket: true))
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let currentSocket = session.webSocketTask(with: request)
        socket = currentSocket
        currentSocket.resume()

        let heartbeat = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                currentSocket.sendPing { error in
                    if error != nil { currentSocket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        defer {
            heartbeat.cancel()
            currentSocket.cancel(with: .goingAway, reason: nil)
            if socket === currentSocket { socket = nil }
        }

        var announcedConnected = false
        while !Task.isCancelled, self.generation == generation {
            let received = try await currentSocket.receive()
            guard let data = Self.data(from: received) else { continue }
            guard let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data) else { continue }
            if !announcedConnected {
                transport(.connected)
                announcedConnected = true
            }
            switch envelope.type {
            case "status":
                if let message = try? JSONDecoder().decode(DiscordStatusMessage.self, from: data) { status(message) }
            case "guilds":
                if let message = try? JSONDecoder().decode(DiscordGuildListMessage.self, from: data) { guilds(message.guilds) }
            case "channels":
                if let message = try? JSONDecoder().decode(DiscordChannelListMessage.self, from: data) { channels(message.guildId, message.channels) }
            default:
                break
            }
        }
    }

    nonisolated private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): data
        case .string(let value): Data(value.utf8)
        @unknown default: nil
        }
    }

    private struct MessageEnvelope: Decodable { let type: String }
}
