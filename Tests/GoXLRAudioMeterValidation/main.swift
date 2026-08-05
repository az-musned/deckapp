import Foundation

@main
struct GoXLRAudioMeterValidation {
    static func main() throws {
        let json = #"{"type":"audio.meters","sequence":1842,"timestamp":1785912800123,"channels":[{"id":"mic","endpointId":null,"available":true,"linearPeak":1.4,"decibels":-14.9,"displayLevel":0.72,"peakHold":0.84,"clipping":false}]}"#
        let message = try JSONDecoder().decode(AudioMetersMessage.self, from: Data(json.utf8))
        precondition(message.type == "audio.meters" && message.channels[0].endpointId == nil)
        precondition(message.channels[0].clamped.linearPeak == 1)

        var tracker = AudioMeterSequenceTracker()
        precondition(tracker.accepts(10))
        precondition(!tracker.accepts(9) && !tracker.accepts(10))
        precondition(tracker.accepts(11))
        tracker.reset()
        precondition(tracker.accepts(0), "Sequence zero must be accepted after reconnect.")

        var channels = [GoXLRChannelState(control: WindowsGoXLRChannelState(id: "mic", name: "Mic", level: 1, isMuted: false))]
        let updateDate = Date(timeIntervalSince1970: 100)
        GoXLRChannelStateReducer.apply(message, to: &channels, now: updateDate)
        precondition(channels[0].volume == 1, "Live meter must not overwrite the configured fader.")
        precondition(channels[0].linearPeak == 1 && channels[0].displayLevel == 0.72)
        precondition(channels[0].lastMeterUpdate == updateDate)

        let controlJSON = #"{"type":"audio.meters","sequence":1843,"timestamp":1785912800124,"channels":[{"id":"mic","endpointId":null,"available":true,"linearPeak":0.4,"decibels":-20,"displayLevel":0.5,"peakHold":0.6,"clipping":false,"level":0.33,"isMuted":true}]}"#
        let controlMessage = try JSONDecoder().decode(AudioMetersMessage.self, from: Data(controlJSON.utf8))
        GoXLRChannelStateReducer.apply(controlMessage, to: &channels, now: updateDate)
        precondition(channels[0].volume == 0.33 && channels[0].isMuted, "Optional live control state must be applied.")
        channels[0].volume = 0.8
        channels[0].isMuted = false
        GoXLRChannelStateReducer.apply(
            controlMessage,
            to: &channels,
            now: updateDate,
            preservingControlIDs: ["mic"]
        )
        precondition(channels[0].volume == 0.8 && !channels[0].isMuted, "An active local interaction must win over live control state.")
        GoXLRChannelStateReducer.decay(&channels, elapsed: 5)
        precondition(channels[0].displayLevel == 0 && channels[0].peakHold == 0)

        let mappingData = try JSONEncoder().encode(AudioChannelMappingRequest(endpointId: "render-1"))
        let mappingObject = try JSONSerialization.jsonObject(with: mappingData) as? [String: String]
        precondition(mappingObject?["endpointId"] == "render-1")

        print("GoXLR meter decoding, clamping, sequence, channel update/decay, and mapping encoding validation passed.")
    }
}
