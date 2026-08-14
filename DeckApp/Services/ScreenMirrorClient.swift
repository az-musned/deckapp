import Foundation
@preconcurrency import WebRTC

protocol ScreenMirrorServing: Sendable {
    func start(
        addresses: [String],
        credential: String,
        mode: ScreenMirrorMode,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void,
        stats: @escaping @Sendable (String) -> Void
    ) async
    func stop() async
}

/// Connects to the Agent's screen-mirror endpoint and negotiates a WebRTC connection over it.
/// The WebSocket at /api/v1/screen/mirror/ws now only carries signaling (SDP offer/answer,
/// trickled ICE candidates, the keyframe-request control message) -- video itself flows over
/// the RTP/SRTP connection WebRTC negotiates, replacing the old custom 26-byte-header binary
/// frame protocol entirely (no more per-frame decode callback: once negotiation completes,
/// the remote `RTCVideoTrack` is handed to the caller once via `track`, and WebRTC's own
/// decoder/jitter buffer/renderer pipeline takes it from there).
actor ScreenMirrorClient: ScreenMirrorServing {
    private var runTask: Task<Void, Never>?
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
        mode: ScreenMirrorMode,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void,
        stats: @escaping @Sendable (String) -> Void
    ) async {
        await stop()
        guard !addresses.isEmpty, !credential.isEmpty else {
            state(.failed("Pair the Windows Agent before starting screen mirroring."))
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        runTask = Task(priority: .utility) { [weak self] in
            await self?.run(
                generation: currentGeneration,
                addresses: addresses,
                credential: credential,
                mode: mode,
                track: track,
                state: state,
                stats: stats
            )
        }
    }

    func stop() async {
        generation = UUID()
        runTask?.cancel()
        runTask = nil
    }

    private func run(
        generation: UUID,
        addresses: [String],
        credential: String,
        mode: ScreenMirrorMode,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void,
        stats: @escaping @Sendable (String) -> Void
    ) async {
        var attempt = 0
        while !Task.isCancelled, self.generation == generation {
            state(attempt == 0 ? .connecting : .reconnecting)
            var lastError: Error = WindowsRemoteInputError.disconnected
            for address in addresses where !Task.isCancelled {
                do {
                    try await negotiate(
                        address: address,
                        credential: credential,
                        mode: mode,
                        generation: generation,
                        track: track,
                        state: state,
                        stats: stats
                    )
                } catch {
                    lastError = error
                }
                guard self.generation == generation else { return }
            }
            track(nil)
            attempt += 1
            state(.failed(lastError.localizedDescription))
            let delay = min(pow(2, Double(min(attempt - 1, 4))) * 0.5, 8)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func negotiate(
        address: String,
        credential: String,
        mode: ScreenMirrorMode,
        generation: UUID,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void,
        stats: @escaping @Sendable (String) -> Void
    ) async throws {
        let endpoint = try WindowsAgentEndpoint(address)
        let baseURL = try endpoint.url(path: "/api/v1/screen/mirror/ws", webSocket: true)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        guard let socketURL = components?.url else { throw WindowsRemoteInputError.disconnected }
        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let socket = session.webSocketTask(with: request)
        socket.resume()

        let signaling = SignalingSession(socket: socket)
        let peer = PeerConnectionSession(signaling: signaling, track: track, state: state, stats: stats)
        defer {
            peer.close()
            socket.cancel(with: .goingAway, reason: nil)
        }

        let heartbeat = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                socket.sendPing { error in
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        defer { heartbeat.cancel() }

        var receivedHello = false
        while !Task.isCancelled, self.generation == generation {
            let received: URLSessionWebSocketTask.Message
            if receivedHello {
                received = try await socket.receive()
            } else {
                received = try await Self.receiveFirstMessage(from: socket)
            }

            guard case .string(let text) = received, let data = text.data(using: .utf8) else { continue }

            if !receivedHello {
                receivedHello = true
                guard (try? JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: data)) != nil else { continue }
                // The phone offers; the agent just answers -- see PeerConnectionSession.
                try await peer.beginNegotiation()
                continue
            }

            guard let signal = try? JSONDecoder().decode(ScreenStreamSignal.self, from: data) else { continue }
            await peer.handle(signal)
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
}
