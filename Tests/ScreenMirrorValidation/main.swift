import CoreGraphics
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

@main
struct ScreenMirrorValidation {
    static func main() throws {
        var tracker = ScreenStreamSequenceTracker()
        precondition(tracker.accepts(10))
        precondition(!tracker.accepts(9) && !tracker.accepts(10))
        precondition(tracker.accepts(11))
        tracker.reset()
        precondition(tracker.accepts(0), "Sequence zero must be accepted after reconnect.")

        let helloJSON = #"{"type":"screen.hello","width":1920,"height":1080,"fps":15,"format":"mjpeg","protocolVersion":1}"#
        let hello = try JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: Data(helloJSON.utf8))
        precondition(hello.format == "mjpeg" && hello.fps == 15)

        let jpegBytes = Self.makeSingleColorJpeg(width: 4, height: 4)
        var header = Data(count: 26)
        header.withUnsafeMutableBytes { raw in
            raw[0] = 1
            raw[1] = 0
            raw.storeBytes(of: UInt32(42).littleEndian, toByteOffset: 2, as: UInt32.self)
            raw.storeBytes(of: Int64(1_785_912_800_123).littleEndian, toByteOffset: 6, as: Int64.self)
            raw.storeBytes(of: UInt32(4).littleEndian, toByteOffset: 14, as: UInt32.self)
            raw.storeBytes(of: UInt32(4).littleEndian, toByteOffset: 18, as: UInt32.self)
            raw.storeBytes(of: UInt32(jpegBytes.count).littleEndian, toByteOffset: 22, as: UInt32.self)
        }
        let framePacket = header + jpegBytes
        let decoded = ScreenStreamFrameDecoder.decode(framePacket)
        precondition(decoded != nil, "A well-formed frame packet must decode.")
        precondition(decoded?.sequence == 42)
        precondition(decoded?.timestampMilliseconds == 1_785_912_800_123)
        precondition(decoded?.width == 4 && decoded?.height == 4)

        let truncatedPacket = header + jpegBytes.prefix(jpegBytes.count - 1)
        precondition(ScreenStreamFrameDecoder.decode(truncatedPacket) == nil, "A truncated packet must not decode.")

        print("Screen mirror sequence tracking, hello decoding, and frame packet decoding validation passed.")
    }

    private static func makeSingleColorJpeg(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
