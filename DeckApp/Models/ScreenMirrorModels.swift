import Foundation

nonisolated enum ScreenMirrorMode: String, Codable, Sendable {
    case mirror
    case extend
}

nonisolated struct ScreenMirrorHelloMessage: Decodable, Sendable, Equatable {
    let type: String
    let width: Int
    let height: Int
    let fps: Int
    let format: String
    let protocolVersion: Int
    let mode: ScreenMirrorMode
}

nonisolated enum ScreenMirrorConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Live"
        case .reconnecting: "Reconnecting"
        case .failed: "Unavailable"
        }
    }
}

/// A signaling message exchanged over /api/v1/screen/mirror/ws: SDP offer/answer or a
/// trickled ICE candidate. The socket no longer carries video bytes -- video flows over the
/// RTP/SRTP connection WebRTC negotiates once signaling completes -- so unlike the old
/// wire-frame protocol there's no sequencing/keyframe-gap logic needed here; RTP's own
/// jitter buffer and loss recovery live inside the WebRTC stack on both ends. Mirrors
/// DeckWindowsAgent's ScreenStreamSignal exactly (field-for-field, camelCase over the wire).
nonisolated struct ScreenStreamSignal: Codable, Sendable {
    let type: String
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int?
}
