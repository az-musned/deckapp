import Foundation

@main
struct ScreenMirrorValidation {
    static func main() throws {
        var tracker = ScreenStreamSequenceTracker()
        precondition(tracker.accepts(10) == (true, false))
        precondition(tracker.accepts(9) == (false, false) && tracker.accepts(10) == (false, false))
        precondition(tracker.accepts(11) == (true, false), "Consecutive sequence numbers must not be flagged as a gap.")
        precondition(tracker.accepts(15) == (true, true), "A skipped sequence range must be flagged as a gap.")
        tracker.reset()
        precondition(tracker.accepts(0) == (true, false), "Sequence zero must be accepted after reconnect, and not flagged as a gap.")

        let helloJSON = #"{"type":"screen.hello","width":1920,"height":1080,"fps":30,"format":"h264","protocolVersion":1,"mode":"mirror"}"#
        let hello = try JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: Data(helloJSON.utf8))
        precondition(hello.format == "h264" && hello.fps == 30 && hello.mode == .mirror)

        let extendHelloJSON = #"{"type":"screen.hello","width":2388,"height":1668,"fps":30,"format":"h264","protocolVersion":1,"mode":"extend"}"#
        let extendHello = try JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: Data(extendHelloJSON.utf8))
        precondition(extendHello.mode == .extend)

        // A synthetic Annex-B access unit: not real encoded video, just NAL-shaped bytes
        // sufficient to exercise the wire header parser (VTDecompressionSession behavior
        // itself isn't unit-testable without a device/simulator).
        let annexB = Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0xCC])
        var header = Data(count: 26)
        header.withUnsafeMutableBytes { raw in
            raw[0] = 1
            raw[1] = 0x01 // keyframe flag set
            raw.storeBytes(of: UInt32(42).littleEndian, toByteOffset: 2, as: UInt32.self)
            raw.storeBytes(of: Int64(1_785_912_800_123).littleEndian, toByteOffset: 6, as: Int64.self)
            raw.storeBytes(of: UInt32(1920).littleEndian, toByteOffset: 14, as: UInt32.self)
            raw.storeBytes(of: UInt32(1080).littleEndian, toByteOffset: 18, as: UInt32.self)
            raw.storeBytes(of: UInt32(annexB.count).littleEndian, toByteOffset: 22, as: UInt32.self)
        }
        let framePacket = header + annexB
        let wireFrame = ScreenStreamWireFrameParser.parse(framePacket)
        precondition(wireFrame != nil, "A well-formed frame packet must parse.")
        precondition(wireFrame?.sequence == 42)
        precondition(wireFrame?.timestampMilliseconds == 1_785_912_800_123)
        precondition(wireFrame?.width == 1920 && wireFrame?.height == 1080)
        precondition(wireFrame?.isKeyframe == true, "The keyframe flag bit must be parsed from byte 1.")
        precondition(wireFrame?.annexB == annexB)

        var nonKeyframeHeader = header
        nonKeyframeHeader[1] = 0
        let nonKeyframePacket = nonKeyframeHeader + annexB
        precondition(ScreenStreamWireFrameParser.parse(nonKeyframePacket)?.isKeyframe == false)

        let truncatedPacket = header + annexB.prefix(annexB.count - 1)
        precondition(ScreenStreamWireFrameParser.parse(truncatedPacket) == nil, "A truncated packet must not parse.")

        print("Screen mirror sequence tracking, hello decoding, and wire frame header parsing validation passed.")
    }
}
