import Foundation

protocol GoXLRAudioMeterServing: Sendable {
    func start(
        addresses: [String],
        credential: String,
        message: @escaping @Sendable (AudioMetersMessage) -> Void,
        state: @escaping @Sendable (AudioMeterConnectionState) -> Void
    ) async
    func stop() async
}

actor GoXLRAudioMeterClient: GoXLRAudioMeterServing {
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
        message: @escaping @Sendable (AudioMetersMessage) -> Void,
        state: @escaping @Sendable (AudioMeterConnectionState) -> Void
    ) async {
        await stop()
        guard !addresses.isEmpty, !credential.isEmpty else {
            state(.failed("Pair the Windows Agent before starting live meters."))
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        runTask = Task(priority: .utility) { [weak self] in
            await self?.run(
                generation: currentGeneration,
                addresses: addresses,
                credential: credential,
                message: message,
                state: state
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

    private func run(
        generation: UUID,
        addresses: [String],
        credential: String,
        message: @escaping @Sendable (AudioMetersMessage) -> Void,
        state: @escaping @Sendable (AudioMeterConnectionState) -> Void
    ) async {
        var attempt = 0
        while !Task.isCancelled, self.generation == generation {
            state(attempt == 0 ? .connecting : .reconnecting)
            var lastError: Error = WindowsRemoteInputError.disconnected
            for address in addresses where !Task.isCancelled {
                do {
                    try await receiveStream(
                        address: address,
                        credential: credential,
                        generation: generation,
                        message: message,
                        state: state
                    )
                } catch {
                    lastError = error
                }
                guard self.generation == generation else { return }
            }
            attempt += 1
            state(.failed(lastError.localizedDescription))
            let delay = min(pow(2, Double(min(attempt - 1, 4))) * 0.5, 8)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveStream(
        address: String,
        credential: String,
        generation: UUID,
        message: @escaping @Sendable (AudioMetersMessage) -> Void,
        state: @escaping @Sendable (AudioMeterConnectionState) -> Void
    ) async throws {
        let endpoint = try WindowsAgentEndpoint(address)
        var request = URLRequest(url: try endpoint.url(path: "/api/v1/audio/meters/ws", webSocket: true))
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let currentSocket = session.webSocketTask(with: request)
        socket = currentSocket
        var sequenceTracker = AudioMeterSequenceTracker()
        currentSocket.resume()

        let heartbeat = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
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

        var receivedFirstFrame = false
        var announcedConnected = false
        while !Task.isCancelled, self.generation == generation {
            let received: URLSessionWebSocketTask.Message
            if receivedFirstFrame {
                received = try await currentSocket.receive()
            } else {
                received = try await Self.receiveFirstMessage(from: currentSocket)
            }
            receivedFirstFrame = true
            guard let data = Self.data(from: received) else { continue }
            let type = try? JSONDecoder().decode(MessageType.self, from: data)
            guard type?.type == "audio.meters",
                  let decoded = try? JSONDecoder().decode(AudioMetersMessage.self, from: data),
                  sequenceTracker.accepts(decoded.sequence) else { continue }
            if !announcedConnected {
                state(.connected)
                announcedConnected = true
            }
            message(decoded)
        }
    }

    nonisolated private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): data
        case .string(let value): Data(value.utf8)
        @unknown default: nil
        }
    }

    nonisolated private static func receiveFirstMessage(
        from socket: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw WindowsRemoteInputError.disconnected
            }
            guard let result = try await group.next() else { throw WindowsRemoteInputError.disconnected }
            group.cancelAll()
            return result
        }
    }

    private struct MessageType: Decodable { let type: String }
}
