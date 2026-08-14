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
    // Tracks the currently-live socket/peer connection (if any) so `stop()` can tear it down
    // synchronously. Task cancellation alone does not unblock an in-flight
    // `URLSessionWebSocketTask.receive()` -- the `while !Task.isCancelled` loop in `negotiate()`
    // only re-checks cancellation between messages, so a cancelled-but-still-blocked-on-receive
    // task leaves the socket (and the Agent's server-side reservation for it) alive until
    // something else eventually errors it out, e.g. the server's own keep-alive timeout tens of
    // seconds later. Explicitly cancelling the socket here makes that in-flight `receive()`
    // throw immediately, unwinding `negotiate()` to its `defer` cleanup right away.
    private var activeSocket: URLSessionWebSocketTask?
    private var activePeer: PeerConnectionSession?

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
        let previousRunTask = runTask
        runTask = nil
        previousRunTask?.cancel()
        let hadActiveConnection = activePeer != nil || activeSocket != nil
        activePeer?.close()
        activePeer = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        // `cancel(with:)` issues the WebSocket close frame but doesn't wait for it to reach
        // the Agent -- `start()` always calls `stop()` first, so without this, rapidly
        // reopening (as in "open Extend, close it, open again" in quick succession) can send
        // the new connection's upgrade request before the server has processed the old one's
        // close, leaving both briefly reserved server-side. Awaiting the cancelled run task
        // lets our own cleanup fully unwind before returning; the short delay after it gives
        // the close frame a moment to actually land before a fresh connection attempt starts.
        // Bounded: `cancel(with:)` *should* make a blocked `receive()` throw promptly, but
        // this must never be allowed to hang indefinitely if it doesn't -- `start()` awaits
        // `stop()` before doing anything else, so an unbounded wait here would deadlock the
        // entire client on the next connection attempt.
        if let previousRunTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await previousRunTask.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
        }
        if hadActiveConnection {
            try? await Task.sleep(for: .milliseconds(150))
        }
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
        activeSocket = socket

        let signaling = SignalingSession(socket: socket)
        let peer = PeerConnectionSession(signaling: signaling, track: track, state: state, stats: stats)
        activePeer = peer
        defer {
            peer.close()
            socket.cancel(with: .goingAway, reason: nil)
            // Only clear if these are still the ones we set -- a newer negotiate() attempt
            // (or a concurrent stop()) may have already replaced/cleared them, and this
            // defer must not stomp on that.
            if activeSocket === socket { activeSocket = nil }
            if activePeer === peer { activePeer = nil }
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
