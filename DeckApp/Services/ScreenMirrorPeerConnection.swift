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
    private let onStats: @Sendable (String) -> Void
    private let peerConnection: RTCPeerConnection
    private let lock = NSLock()
    private var closed = false
    // ICE has no built-in timeout of its own -- with iceServers = [] (LAN-only host
    // candidates, no STUN/TURN) a network path that can't actually reach the Agent (wrong
    // subnet, a firewall dropping the UDP candidates, a NAT between phone and PC) leaves the
    // connection sitting in .checking indefinitely with no error and no track, which is
    // indistinguishable in the UI from "still negotiating". Bound it so that turns into a
    // visible, specific failure instead of an infinite "Connecting..." spinner.
    private var connectTimeoutTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var hasConnected = false

    init(
        signaling: SignalingSession,
        track: @escaping @Sendable (RTCVideoTrack?) -> Void,
        state: @escaping @Sendable (ScreenMirrorConnectionState) -> Void,
        stats: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.signaling = signaling
        self.onTrack = track
        self.onState = state
        self.onStats = stats

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

        let onState = self.onState
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.isConnected != true else { return }
            onState(.failed("Timed out waiting for ICE connectivity with the Windows Agent. Check that the phone and PC are on the same network/VPN and no firewall is blocking UDP."))
        }
    }

    private var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasConnected
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
        connectTimeoutTask?.cancel()
        statsTask?.cancel()
        guard !alreadyClosed else { return }
        peerConnection.close()
    }

    private func markConnected() {
        lock.lock()
        hasConnected = true
        lock.unlock()
        connectTimeoutTask?.cancel()
        startStatsPolling()
    }

    // TEMPORARY: diagnosing the "connects but renders ~1fps" report. Mirrors
    // WindowsAgent/DeckWindowsAgent/Screen/ScreenStreamService.cs's per-second DIAG logging
    // on the sender side, from the receiver side, so the two can be compared. Remove once
    // that's resolved (see ScreenMirrorView.swift's statsOverlay for the other half).
    private func startStatsPolling() {
        let peerConnection = self.peerConnection
        let onStats = self.onStats
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                let report = await peerConnection.statistics()
                guard let self, !Task.isCancelled else { return }
                if let line = Self.formatInboundVideoStats(report) {
                    onStats(line)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    nonisolated private static func formatInboundVideoStats(_ report: RTCStatisticsReport) -> String? {
        guard let stats = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video"
        }) else { return nil }
        let v = stats.values
        let received = (v["packetsReceived"] as? NSNumber)?.intValue ?? -1
        let lost = (v["packetsLost"] as? NSNumber)?.intValue ?? -1
        let framesReceived = (v["framesReceived"] as? NSNumber)?.intValue ?? -1
        let framesDecoded = (v["framesDecoded"] as? NSNumber)?.intValue ?? -1
        let framesDropped = (v["framesDropped"] as? NSNumber)?.intValue ?? -1
        let jitterMs = ((v["jitter"] as? NSNumber)?.doubleValue ?? 0) * 1000
        // Per-frame decode time is the key signal for "cleanly received but not keeping up":
        // a few ms/frame is normal hardware (VideoToolbox) decode; tens-to-hundreds of ms/frame
        // means it fell back to a slow software decoder, almost always because the negotiated
        // H.264 profile-level-id/packetization-mode isn't one VideoToolbox will hardware-accelerate.
        let totalDecodeTime = (v["totalDecodeTime"] as? NSNumber)?.doubleValue ?? 0
        let avgDecodeMs = framesDecoded > 0 ? (totalDecodeTime / Double(framesDecoded)) * 1000 : 0
        let decoderImpl = (v["decoderImplementation"] as? String) ?? "?"
        var codecInfo = ""
        if let codecId = v["codecId"] as? String, let codecStats = report.statistics[codecId] {
            let mime = (codecStats.values["mimeType"] as? String) ?? "?"
            let fmtp = (codecStats.values["sdpFmtpLine"] as? String) ?? "(no fmtp)"
            codecInfo = " codec=\(mime) fmtp=\(fmtp)"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off"
        return "recv=\(received) lost=\(lost) framesRecv=\(framesReceived) framesDec=\(framesDecoded) framesDrop=\(framesDropped) jitter=\(Int(jitterMs))ms decodeAvg=\(String(format: "%.1f", avgDecodeMs))ms decoder=\(decoderImpl) lowPower=\(lowPower)\(codecInfo)"
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

    // Required by the ObjC protocol but never called with `sdpSemantics = .unifiedPlan`
    // (see RTCPeerConnection.h) -- the real track/stream arrival signal under Unified Plan
    // is the receiver-based callback below. Without that one, ICE and DTLS still complete
    // but the app never learns a track is available: the UI stays on "Connecting..."
    // forever even though the connection itself succeeded.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        markConnected()
        onTrack(rtpReceiver.track as? RTCVideoTrack)
        onState(.connected)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
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

    // Fires per candidate the local ICE agent tried and failed to gather (e.g. no usable
    // local network interface). One failure here doesn't necessarily mean the whole
    // connection is doomed -- other candidates may still succeed -- so this only surfaces
    // through the bounded timeout above rather than failing immediately.
    func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {}
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

    func statistics() async -> RTCStatisticsReport {
        await withCheckedContinuation { continuation in
            self.statistics { report in
                continuation.resume(returning: report)
            }
        }
    }
}
