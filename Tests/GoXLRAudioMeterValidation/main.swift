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
        precondition(channels[0].volume == 1 && !channels[0].isMuted, "Meter payload fields must never move or mute a fader.")

        channels.append(GoXLRChannelState(
            control: WindowsGoXLRChannelState(id: "LineIn", name: "Line In", level: 0.4, isMuted: false)
        ))
        let differentlyCasedMeter = AudioMetersMessage(
            type: "audio.meters",
            sequence: 1844,
            timestamp: 1785912800125,
            channels: [
                AudioMeterChannelPayload(
                    id: "linein",
                    endpointId: nil,
                    available: true,
                    linearPeak: 0.3,
                    decibels: -24,
                    displayLevel: 0.44,
                    peakHold: 0.5,
                    clipping: false
                )
            ]
        )
        GoXLRChannelStateReducer.apply(differentlyCasedMeter, to: &channels, now: updateDate)
        precondition(channels.count == 2, "Case differences between control and meter channel IDs must not create duplicates.")
        precondition(channels[1].displayLevel == 0.44)
        GoXLRChannelStateReducer.decay(&channels, elapsed: 5)
        precondition(channels[0].displayLevel == 0 && channels[0].peakHold == 0)

        let selectableChannels = [
            GoXLRChannelState(control: WindowsGoXLRChannelState(id: "microphone", name: "Microphone", level: 0.4, isMuted: false)),
            GoXLRChannelState(control: WindowsGoXLRChannelState(id: "chatMic", name: "Chat", level: 0.5, isMuted: false)),
            GoXLRChannelState(control: WindowsGoXLRChannelState(id: "music", name: "Music", level: 0.6, isMuted: false))
        ]
        let resolved = GoXLRChannelSelectionResolver.resolve(
            selectedIDs: ["mic", "chat", "music", "system"],
            from: selectableChannels
        )
        precondition(resolved.map(\.displayName) == ["Microphone", "Chat", "Music", "System"])
        precondition(resolved.map(\.id) == ["microphone", "chatMic", "music", "system"])
        precondition(resolved.last?.isAvailable == false)

        var scaledChannel = GoXLRChannelState(
            control: WindowsGoXLRChannelState(id: "music", name: "Music", level: 0.5, isMuted: false)
        )
        scaledChannel.displayLevel = 0.8
        scaledChannel.peakHold = 1
        scaledChannel.decibels = -6
        precondition(abs(scaledChannel.volumeScaledDisplayLevel - 0.4) < 0.0001)
        precondition(abs(scaledChannel.volumeScaledPeakHold - 0.5) < 0.0001)
        precondition(abs(scaledChannel.volumeScaledDecibels - -12.0206) < 0.001)
        scaledChannel.volume = 0
        precondition(scaledChannel.volumeScaledDisplayLevel == 0)
        precondition(scaledChannel.volumeScaledPeakHold == 0)
        precondition(scaledChannel.volumeScaledDecibels == -120)

        let mappingData = try JSONEncoder().encode(AudioChannelMappingRequest(endpointId: "render-1"))
        let mappingObject = try JSONSerialization.jsonObject(with: mappingData) as? [String: String]
        precondition(mappingObject?["endpointId"] == "render-1")

        print("GoXLR meter decoding, clamping, sequence, channel update/decay, and mapping encoding validation passed.")
    }
}
