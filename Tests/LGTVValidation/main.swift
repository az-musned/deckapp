import Foundation

@main
struct LGTVValidation {
    static func main() throws {
        let registration = LGTVProtocolCodec.registration(clientKey: "saved-key")
        let registrationData = try JSONEncoder().encode(registration)
        let registrationObject = try JSONSerialization.jsonObject(with: registrationData) as? [String: Any]
        let registrationPayload = registrationObject?["payload"] as? [String: Any]
        precondition(registrationObject?["type"] as? String == "register")
        precondition(registrationPayload?["client-key"] as? String == "saved-key")
        precondition(registrationPayload?["pairingType"] as? String == "PROMPT")
        let manifest = registrationPayload?["manifest"] as? [String: Any]
        let permissions = manifest?["permissions"] as? [String]
        precondition(permissions?.contains("CONTROL_MOUSE_AND_KEYBOARD") == true)
        precondition(permissions?.contains("READ_INSTALLED_APPS") == true)
        precondition(manifest?["signed"] == nil && manifest?["signatures"] == nil)

        let registeredJSON = #"{"id":"register_0","type":"registered","payload":{"client-key":"new-key"}}"#
        let registered = try JSONDecoder().decode(LGTVProtocolMessage.self, from: Data(registeredJSON.utf8))
        precondition(LGTVProtocolCodec.registrationOutcome(registered) == .registered(clientKey: "new-key"))

        let promptJSON = #"{"id":"register_0","type":"response","payload":{"pairingType":"PROMPT"}}"#
        let prompt = try JSONDecoder().decode(LGTVProtocolMessage.self, from: Data(promptJSON.utf8))
        precondition(LGTVProtocolCodec.registrationOutcome(prompt) == .awaitingConfirmation)

        let rejection = LGTVProtocolMessage(id: "register_0", type: "error", payload: ["errorText": .string("denied")])
        precondition(LGTVProtocolCodec.registrationOutcome(rejection) == .rejected("denied"))

        let rateLimitJSON = #"{"id":"register_0","type":"error","error":"403 too many pairing requests"}"#
        let rateLimit = try JSONDecoder().decode(LGTVProtocolMessage.self, from: Data(rateLimitJSON.utf8))
        precondition(LGTVProtocolCodec.registrationOutcome(rateLimit) == .rejected("403 too many pairing requests"))

        let volumeRequest = LGTVProtocolCodec.request(LGTVRequests.setVolume(42), id: "request_1")
        precondition(volumeRequest.uri == "ssap://audio/setVolume")
        precondition(volumeRequest.payload?["volume"] == .number(42))
        let volumeSnapshot = LGTVProtocolCodec.request(LGTVRequests.volumeSnapshot, id: "request_volume")
        precondition(volumeSnapshot.type == "request")
        precondition(volumeSnapshot.uri == "ssap://audio/getVolume")
        let volumeSubscription = LGTVProtocolCodec.request(LGTVRequests.volume, id: "subscribe_volume")
        precondition(volumeSubscription.type == "subscribe")
        precondition(volumeSubscription.uri == volumeSnapshot.uri)
        let inputRequest = LGTVProtocolCodec.request(LGTVRequests.switchInput("HDMI_1"), id: "request_2")
        precondition(inputRequest.payload?["inputId"] == .string("HDMI_1"))
        precondition(LGTVRequests.applications.uri.hasSuffix("/listLaunchPoints"))

        let launchPoints: [String: LGTVJSONValue] = [
            "launchPoints": .array([
                .object(["id": .string("netflix"), "title": .string("Netflix"), "visible": .bool(true)]),
                .object(["id": .string("com.webos.app.settings"), "title": .string("Settings"), "visible": .bool(true)]),
                .object(["id": .string("hidden.app"), "title": .string("Hidden"), "visible": .bool(false)])
            ])
        ]
        precondition(LGTVApplicationParser.launcherApplications(from: launchPoints) == [LGTVApplication(id: "netflix", name: "Netflix")])

        var state = LGTVState(volume: 2, isMuted: false)
        LGTVStateReducer.applyVolumePayload(["volume": .number(160), "mute": .bool(true)], to: &state, now: Date(timeIntervalSince1970: 100))
        precondition(state.volume == 100 && state.isMuted)
        precondition(state.lastUpdated == Date(timeIntervalSince1970: 100))

        let headers = LGTVSSDPDiscoveryService.parseHeaders("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.20:3000/description.xml\r\nSERVER: webOS/7.3 UPnP/1.0\r\n\r\n")
        precondition(headers["location"] == "http://192.168.1.20:3000/description.xml")
        precondition(headers["server"] == "webOS/7.3 UPnP/1.0")
        let candidates = LGTVSSDPDiscoveryService.candidateHosts(near: "192.168.3.40")
        precondition(candidates.count == 253)
        precondition(candidates.contains("192.168.3.200") && !candidates.contains("192.168.3.40"))

        let packet = try LGTVWakeOnLANService.magicPacket(macAddress: "AA:BB:CC:DD:EE:FF")
        precondition(packet.count == 102)
        precondition(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        precondition(packet.suffix(6) == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        precondition(LGTVWakeOnLANService.broadcastTargets(for: "192.168.3.91") == ["192.168.3.255", "255.255.255.255"])
        precondition(LGTVWakeOnLANService.broadcastTargets(for: "tv.local") == ["255.255.255.255"])

        precondition(LGTVReconnectPolicy.delaySeconds(for: 1) == 1)
        precondition(LGTVReconnectPolicy.delaySeconds(for: 4) == 8)
        precondition(LGTVReconnectPolicy.delaySeconds(for: 9) == 8)

        let suiteName = "LGTVValidation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("Unable to create test defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = LGTVDevicePersistence(defaults: defaults)
        let television = LGTVDevice(name: "Living Room", host: "192.168.1.20", macAddress: "AA:BB:CC:DD:EE:FF")
        persistence.saveDevices([television])
        persistence.saveSelectedDeviceID(television.id)
        precondition(persistence.loadDevices() == [television])
        precondition(persistence.loadSelectedDeviceID() == television.id)

        print("LG webOS registration, pairing outcomes, commands, state reducer, SSDP parsing, WOL, retry policy, and persistence validation passed.")
    }
}
