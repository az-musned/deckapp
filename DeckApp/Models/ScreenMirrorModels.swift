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

    mutating func accepts(_ sequence: UInt32) -> Bool {
        guard let latest else {
            self.latest = sequence
            return true
        }
        guard sequence > latest || latest - sequence > UInt32.max / 2 else { return false }
        self.latest = sequence
        return true
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

// CMSampleBuffer predates Swift's Sendable checking but is safe for this single-owner
// handoff from the decode call site to the MainActor store that enqueues it for display --
// the same pattern AVFoundation's own capture-output delegates rely on.
nonisolated struct ScreenStreamFrame: @unchecked Sendable {
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
