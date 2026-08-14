import Foundation
@preconcurrency import WebRTC

/// GoogleWebRTC's ObjC delegate/completion-handler types (RTCPeerConnection, RTCVideoTrack,
/// etc.) predate Swift's Sendable checking and aren't annotated for it -- `@preconcurrency`
/// on the WebRTC import tells the compiler to treat crossing those types over actor/closure
/// boundaries as pre-Swift-6 code, rather than raising strict-concurrency errors for a
/// framework that isn't going to gain real Sendable annotations.

/// Single app-wide RTCPeerConnectionFactory. Per stasel/WebRTC's guidance, creating more than
/// one is expensive and can cause codec/threading issues, so every mirror-stream connection
/// (mirror mode, extend mode, and any reconnect) shares this instance.
nonisolated enum WebRTCEnvironment {
    nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
}

/// Serializes writes to the signaling WebSocket. ICE candidates arrive asynchronously off
/// WebRTC's own threads (from RTCPeerConnectionDelegate callbacks) while the offer/answer
/// exchange is also writing to the same socket, and URLSessionWebSocketTask doesn't support
/// concurrent sends. An actor serializes this without blocking a thread the way a lock held
/// across an `await` would.
actor SignalingSession {
    private let socket: URLSessionWebSocketTask

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func send(_ signal: ScreenStreamSignal) async throws {
        let data = try JSONEncoder().encode(signal)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(text))
    }
}

/// Owns one RTCPeerConnection for a single mirror-stream connection attempt. The phone is
/// deliberately the offering side: the agent (DeckWindowsAgent/Screen/ScreenStreamWebSocketEndpoint.cs)
/// just waits for an offer and answers it, which is simpler than having the always-on agent
/// decide when to start negotiating. Reports the remote video track (once WebRTC's own
/// negotiation and jitter buffer produce one) and coarse connection-state transitions back
/// through the callbacks passed at init.
nonisolated final class PeerConnectionSession: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let signaling: SignalingSession
    private let onTrack: @Sendable (RTCVideoTrack?) -> Void
    private let onState: @Sendable (ScreenMirrorConnectionState) -> Void
    private let peerConnection: RTCPeerConnection
    private let lock = NSLock()
    private var closed = false

    init(
        signaling: SignalingSession,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void
    ) {
        self.signaling = signaling
        self.onTrack = track
        self.onState = state

        let configuration = RTCConfiguration()
        // LAN-only: the agent's PrivateNetworkGuard already restricts connections to
        // private/loopback addresses, so ICE only ever needs local host candidates.
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        self.peerConnection = WebRTCEnvironment.factory.peerConnection(
            with: configuration, constraints: constraints, delegate: nil)!

        super.init()
        peerConnection.delegate = self

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        peerConnection.addTransceiver(of: .video, init: transceiverInit)
    }

    func beginNegotiation() async throws {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await peerConnection.offer(for: constraints)
        try await peerConnection.setLocalDescription(offer)
        try await signaling.send(ScreenStreamSignal(type: "offer", sdp: offer.sdp, candidate: nil, sdpMid: nil, sdpMLineIndex: nil))
    }

    func handle(_ signal: ScreenStreamSignal) async {
        switch signal.type {
        case "answer":
            guard let sdp = signal.sdp else { return }
            try? await peerConnection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        case "ice":
            guard let candidate = signal.candidate else { return }
            let iceCandidate = RTCIceCandidate(
                sdp: candidate,
                sdpMLineIndex: Int32(signal.sdpMLineIndex ?? 0),
                sdpMid: signal.sdpMid)
            try? await peerConnection.add(iceCandidate)
        default:
            break
        }
    }

    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        peerConnection.close()
    }

    // MARK: - RTCPeerConnectionDelegate
    // Fired on WebRTC's own signaling thread, not the main thread or the caller's task.

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let signaling = self.signaling
        Task {
            try? await signaling.send(ScreenStreamSignal(
                type: "ice",
                sdp: nil,
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)))
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        onTrack(stream.videoTracks.first)
        onState(.connected)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        onTrack(nil)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .disconnected:
            onState(.reconnecting)
        case .failed, .closed:
            onState(.failed("The connection to the Windows Agent was lost."))
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
}

/// GoogleWebRTC's RTCVideoTrack is a thread-safe ObjC ref-counted wrapper around a native
/// track object -- safe to hand across threads/actors, just not annotated as such.
extension RTCVideoTrack: @retroactive @unchecked Sendable {}

/// Thin async/await wrappers over GoogleWebRTC's completion-handler APIs.
extension RTCPeerConnection {
    func offer(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            self.offer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? WindowsRemoteInputError.disconnected)
                }
            }
        }
    }

    func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func add(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
