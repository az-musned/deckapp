import CoreMedia
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

nonisolated struct ScreenStreamSequenceTracker: Sendable {
    private(set) var latest: UInt32?

    /// H.264 delta frames are differential -- each depends on the previous frame having
    /// decoded successfully. A gap here (a sequence number more than one past the last
    /// accepted one) means the Agent's broadcaster dropped one or more frames for
    /// backpressure, silently breaking the decoder's reference chain. `gapDetected` lets
    /// the caller request a fresh keyframe to resync instead of continuing to decode
    /// against a now-invalid reference (which shows up as corrupted/stale-looking frames).
    mutating func accepts(_ sequence: UInt32) -> (accepted: Bool, gapDetected: Bool) {
        guard let latest else {
            self.latest = sequence
            return (true, false)
        }
        guard sequence > latest || latest - sequence > UInt32.max / 2 else { return (false, false) }
        let gapDetected = sequence != latest &+ 1
        self.latest = sequence
        return (true, gapDetected)
    }

    mutating func reset() { latest = nil }
}

/// One binary WebSocket message as received from the Agent: the fixed 26-byte header plus
/// the raw H.264 Annex-B payload for that frame. Decoding to a displayable sample buffer
/// happens in `ScreenMirrorDecoder`, which needs per-connection state (a `VTDecompressionSession`)
/// that doesn't belong in a stateless parser.
nonisolated struct ScreenStreamWireFrame: Sendable {
    let sequence: UInt32
    let timestampMilliseconds: Int64
    let width: Int
    let height: Int
    let isKeyframe: Bool
    let annexB: Data
}

nonisolated struct ScreenStreamFrame: Sendable {
    let sequence: UInt32
    let timestampMilliseconds: Int64
    let sampleBuffer: CMSampleBuffer
}

nonisolated enum ScreenStreamWireFrameParser {
    private static let headerLength = 26
    private static let keyframeFlag: UInt8 = 0x01

    static func parse(_ data: Data) -> ScreenStreamWireFrame? {
        guard data.count > headerLength else { return nil }
        var flags: UInt8 = 0
        var sequence: UInt32 = 0
        var timestamp: Int64 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var payloadLength: UInt32 = 0
        data.withUnsafeBytes { raw in
            flags = raw.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            sequence = raw.loadUnaligned(fromByteOffset: 2, as: UInt32.self).littleEndian
            timestamp = raw.loadUnaligned(fromByteOffset: 6, as: Int64.self).littleEndian
            width = raw.loadUnaligned(fromByteOffset: 14, as: UInt32.self).littleEndian
            height = raw.loadUnaligned(fromByteOffset: 18, as: UInt32.self).littleEndian
            payloadLength = raw.loadUnaligned(fromByteOffset: 22, as: UInt32.self).littleEndian
        }
        guard data.count >= headerLength + Int(payloadLength) else { return nil }
        let annexB = data.subdata(in: headerLength..<(headerLength + Int(payloadLength)))
        return ScreenStreamWireFrame(
            sequence: sequence,
            timestampMilliseconds: timestamp,
            width: Int(width),
            height: Int(height),
            isKeyframe: (flags & keyframeFlag) != 0,
            annexB: annexB
        )
    }
}
