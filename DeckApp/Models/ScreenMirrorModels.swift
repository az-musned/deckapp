import CoreGraphics
import Foundation
import ImageIO

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

nonisolated struct ScreenStreamFrame: Sendable {
    let sequence: UInt32
    let timestampMilliseconds: Int64
    let width: Int
    let height: Int
    let image: CGImage
}

nonisolated enum ScreenStreamFrameDecoder {
    private static let headerLength = 26

    static func decode(_ data: Data) -> ScreenStreamFrame? {
        guard data.count > headerLength else { return nil }
        var sequence: UInt32 = 0
        var timestamp: Int64 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var jpegLength: UInt32 = 0
        data.withUnsafeBytes { raw in
            sequence = raw.loadUnaligned(fromByteOffset: 2, as: UInt32.self).littleEndian
            timestamp = raw.loadUnaligned(fromByteOffset: 6, as: Int64.self).littleEndian
            width = raw.loadUnaligned(fromByteOffset: 14, as: UInt32.self).littleEndian
            height = raw.loadUnaligned(fromByteOffset: 18, as: UInt32.self).littleEndian
            jpegLength = raw.loadUnaligned(fromByteOffset: 22, as: UInt32.self).littleEndian
        }
        guard data.count >= headerLength + Int(jpegLength) else { return nil }
        let jpegData = data.subdata(in: headerLength..<(headerLength + Int(jpegLength)))
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ScreenStreamFrame(
            sequence: sequence,
            timestampMilliseconds: timestamp,
            width: Int(width),
            height: Int(height),
            image: image
        )
    }
}
