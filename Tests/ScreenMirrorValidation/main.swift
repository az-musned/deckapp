import Foundation

@main
struct ScreenMirrorValidation {
    static func main() throws {
        let helloJSON = #"{"type":"screen.hello","width":1920,"height":1080,"fps":30,"format":"h264","protocolVersion":1,"mode":"mirror"}"#
        let hello = try JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: Data(helloJSON.utf8))
        precondition(hello.format == "h264" && hello.fps == 30 && hello.mode == .mirror)

        let extendHelloJSON = #"{"type":"screen.hello","width":2388,"height":1668,"fps":30,"format":"h264","protocolVersion":1,"mode":"extend"}"#
        let extendHello = try JSONDecoder().decode(ScreenMirrorHelloMessage.self, from: Data(extendHelloJSON.utf8))
        precondition(extendHello.mode == .extend)

        // Round-trip the signaling message shape exchanged over /api/v1/screen/mirror/ws --
        // this is the JSON contract with DeckWindowsAgent's ScreenStreamSignal, so a field
        // rename on either side that breaks Codable conformance should fail here.
        let offer = ScreenStreamSignal(type: "offer", sdp: "v=0...", candidate: nil, sdpMid: nil, sdpMLineIndex: nil)
        let offerData = try JSONEncoder().encode(offer)
        let decodedOffer = try JSONDecoder().decode(ScreenStreamSignal.self, from: offerData)
        precondition(decodedOffer.type == "offer" && decodedOffer.sdp == "v=0..." && decodedOffer.candidate == nil)

        let ice = ScreenStreamSignal(type: "ice", sdp: nil, candidate: "candidate:1 1 UDP 2130706431 192.168.1.5 5000 typ host", sdpMid: "0", sdpMLineIndex: 0)
        let iceData = try JSONEncoder().encode(ice)
        let decodedIce = try JSONDecoder().decode(ScreenStreamSignal.self, from: iceData)
        precondition(decodedIce.type == "ice" && decodedIce.candidate == ice.candidate && decodedIce.sdpMLineIndex == 0)

        print("Screen mirror hello decoding and signaling message round-trip validation passed.")
    }
}
