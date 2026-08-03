import Foundation

@main
struct HomeAssistantFoundationValidation {
    static func main() throws {
        let local = try HomeAssistantWebSocketClient.webSocketURL(
            from: URL(string: "http://homeassistant.local:8123")!
        )
        precondition(local.absoluteString == "ws://homeassistant.local:8123/api/websocket")

        let remote = try HomeAssistantWebSocketClient.webSocketURL(
            from: URL(string: "https://ha.example.com/base?ignored=yes")!
        )
        precondition(remote.absoluteString == "wss://ha.example.com/api/websocket")

        let message: [String: Any] = [
            "type": "event",
            "event": [
                "event_type": "state_changed",
                "data": [
                    "new_state": [
                        "entity_id": "light.room",
                        "state": "on",
                        "attributes": [
                            "friendly_name": "Room Lights",
                            "brightness": 128
                        ],
                        "last_changed": "2026-08-03T12:00:00+00:00",
                        "last_updated": "2026-08-03T12:00:00+00:00"
                    ]
                ]
            ]
        ]

        let entity = HomeAssistantWebSocketClient.stateEntity(from: message)
        precondition(entity?.entityID == "light.room")
        precondition(entity?.state == "on")
        precondition(entity?.attributes["friendly_name"] == .string("Room Lights"))
        precondition(entity?.attributes["brightness"] == .number(128))

        precondition(HomeAssistantWebSocketClient.stateEntity(from: ["type": "result"]) == nil)

        let climate = HAEntityState(
            entityID: "climate.bedroom", state: "cool",
            attributes: [
                "current_temperature": .number(24), "temperature": .number(22),
                "min_temp": .number(16), "max_temp": .number(30), "target_temp_step": .number(0.5),
                "temperature_unit": .string("°C"),
                "hvac_modes": .array([.string("off"), .string("cool"), .string("dry")]),
                "fan_modes": .array([.string("auto"), .string("high")])
            ], lastChanged: nil, lastUpdated: nil
        )
        let climateCapabilities = HomeAssistantCapabilityDiscovery.capabilities(for: climate)
        precondition(climateCapabilities.first(where: { $0.kind == .temperature })?.numericRange?.minimum == 16)
        precondition(climateCapabilities.first(where: { $0.kind == .hvacMode })?.selection?.options == ["off", "cool", "dry"])
        precondition(climateCapabilities.contains { $0.kind == .fanMode })
        precondition(!climateCapabilities.contains { $0.kind == .swingMode })

        let television = HAEntityState(
            entityID: "media_player.lg_tv", state: "playing",
            attributes: [
                "volume_level": .number(0.35), "is_volume_muted": .bool(false),
                "source": .string("HDMI 1"), "source_list": .array([.string("HDMI 1"), .string("Netflix")]),
                "supported_features": .number(2061)
            ], lastChanged: nil, lastUpdated: nil
        )
        let televisionCapabilities = HomeAssistantCapabilityDiscovery.capabilities(for: television)
        precondition(televisionCapabilities.first(where: { $0.kind == .volume })?.numericRange?.currentValue == 35)
        precondition(televisionCapabilities.first(where: { $0.kind == .sourceSelection })?.selection?.options.count == 2)
        precondition(televisionCapabilities.contains { $0.kind == .mediaPlayback })

        let limitedTelevision = HAEntityState(
            entityID: "media_player.limited", state: "on",
            attributes: ["volume_level": .number(0.5), "supported_features": .number(128)],
            lastChanged: nil, lastUpdated: nil
        )
        let limitedCapabilities = HomeAssistantCapabilityDiscovery.capabilities(for: limitedTelevision)
        precondition(limitedCapabilities.contains { $0.kind == .power })
        precondition(!limitedCapabilities.contains { $0.kind == .volume })

        let remoteEntity = HAEntityState(entityID: "remote.lg_tv", state: "on", attributes: [:], lastChanged: nil, lastUpdated: nil)
        precondition(HomeAssistantCapabilityDiscovery.capabilities(for: remoteEntity).contains { $0.kind == .directionalRemote })

        var wake = WakeOnLANConfiguration(macAddress: "00-11-22-aa-BB-ff", broadcastAddress: "192.168.1.255")
        precondition(wake.normalizedMACAddress == "00:11:22:AA:BB:FF")
        wake.macAddress = "not-a-mac"
        precondition(wake.normalizedMACAddress == nil)

        let pcOnline = HAEntityState(entityID: "binary_sensor.pc_online", state: "on", attributes: ["device_class": .string("connectivity")], lastChanged: nil, lastUpdated: nil)
        precondition(HomeAssistantCapabilityDiscovery.capabilities(for: pcOnline).first?.isWritable == false)

        let script = HAEntityState(entityID: "script.launch_game", state: "off", attributes: [:], lastChanged: nil, lastUpdated: nil)
        precondition(HomeAssistantCapabilityDiscovery.capabilities(for: script).first?.kind == .action)

        let scene = HAEntityState(entityID: "scene.movie", state: "2026-08-03T12:00:00+00:00", attributes: [:], lastChanged: nil, lastUpdated: nil)
        precondition(HomeAssistantCapabilityDiscovery.capabilities(for: scene).first?.kind == .sceneActivation)

        print("Home Assistant WebSocket, state-event, and capability-discovery validation passed")
    }
}
