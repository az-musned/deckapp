import Foundation

actor HomeAssistantWebSocketClient {
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    func connect(
        baseURL: URL,
        token: String,
        stateChanged: @escaping @Sendable (HAEntityState) -> Void,
        disconnected: @escaping @Sendable (String?) -> Void
    ) async throws {
        await disconnect()
        let socketURL = try Self.webSocketURL(from: baseURL)
        let task = URLSession.shared.webSocketTask(with: socketURL)
        self.task = task
        task.resume()

        let first = try await receiveObject(from: task)
        guard first["type"] as? String == "auth_required" else { throw HAWebSocketError.unexpectedHandshake }
        try await send(["type": "auth", "access_token": token], to: task)
        let auth = try await receiveObject(from: task)
        guard auth["type"] as? String == "auth_ok" else { throw HAWebSocketError.authenticationRejected }
        try await send(["id": 1, "type": "subscribe_events", "event_type": "state_changed"], to: task)

        receiveTask = Task { [weak self] in
            await self?.receiveEvents(
                from: task,
                stateChanged: stateChanged,
                disconnected: disconnected
            )
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    nonisolated static func webSocketURL(from baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw HAWebSocketError.invalidURL }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: throw HAWebSocketError.invalidURL
        }
        components.path = "/api/websocket"
        components.query = nil
        guard let url = components.url else { throw HAWebSocketError.invalidURL }
        return url
    }

    nonisolated static func stateEntity(from object: [String: Any]) -> HAEntityState? {
        guard object["type"] as? String == "event",
              let event = object["event"] as? [String: Any],
              event["event_type"] as? String == "state_changed",
              let data = event["data"] as? [String: Any],
              let state = data["new_state"] as? [String: Any],
              JSONSerialization.isValidJSONObject(state),
              let encoded = try? JSONSerialization.data(withJSONObject: state) else { return nil }
        return try? JSONDecoder().decode(HAEntityState.self, from: encoded)
    }

    private func receiveObject(from task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw HAWebSocketError.invalidMessage
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HAWebSocketError.invalidMessage }
        return object
    }

    private func receiveEvents(
        from task: URLSessionWebSocketTask,
        stateChanged: @escaping @Sendable (HAEntityState) -> Void,
        disconnected: @escaping @Sendable (String?) -> Void
    ) async {
        do {
            while !Task.isCancelled {
                let object = try await receiveObject(from: task)
                if let entity = Self.stateEntity(from: object) { stateChanged(entity) }
            }
        } catch {
            if !Task.isCancelled { disconnected(error.localizedDescription) }
        }
    }

    private func send(_ object: [String: Any], to task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.data(data))
    }
}

enum HAWebSocketError: LocalizedError {
    case invalidURL, unexpectedHandshake, authenticationRejected, invalidMessage
}
