import Foundation

@main
struct RemoteInputValidation {
    static func main() async throws {
        var buffer = PointerEventBuffer()
        buffer.enqueuePointer(deltaX: 2, deltaY: 3, timestampMilliseconds: 1_000)
        buffer.enqueuePointer(deltaX: 4, deltaY: -1, timestampMilliseconds: 1_008)
        buffer.enqueueScroll(deltaX: 0, deltaY: 5, timestampMilliseconds: 1_010)
        let coalesced = buffer.drain(nowMilliseconds: 1_016, acceleration: true, precision: false)
        precondition(coalesced == [
            .relativePointer(deltaX: 6, deltaY: 2, acceleration: true, precision: false),
            .scroll(deltaX: 0, deltaY: 5)
        ])

        buffer.enqueuePointer(deltaX: 10, deltaY: 10, timestampMilliseconds: 1_000)
        precondition(buffer.drain(nowMilliseconds: 1_200, acceleration: true, precision: false).isEmpty)

        let clicks: [RemoteInputPayload] = [
            .mouseButton(.left, isDown: true),
            .mouseButton(.left, isDown: false),
            .mouseButton(.right, isDown: true),
            .mouseButton(.right, isDown: false)
        ]
        precondition(clicks[1].isReleasePriority)
        precondition(clicks[3].isReleasePriority)

        let arabic = RemoteInputPayload.unicodeText("مرحبا بالعالم")
        let encoded = try JSONEncoder().encode(arabic)
        let decodedArabic = try JSONDecoder().decode(RemoteInputPayload.self, from: encoded)
        precondition(decodedArabic == arabic)

        let localEndpoint = try WindowsAgentEndpoint("https://192.168.137.1:8732")
        precondition(localEndpoint.route == .local)
        let inputEndpoint = try localEndpoint.url(path: "/api/v1/agent/input", webSocket: true)
        let vpnEndpoint = try WindowsAgentEndpoint("https://100.90.1.2:8732")
        let remoteEndpoint = try WindowsAgentEndpoint("https://pc.example.com:8732")
        precondition(inputEndpoint.absoluteString == "wss://192.168.137.1:8732/api/v1/agent/input")
        precondition(vpnEndpoint.route == .vpn)
        precondition(remoteEndpoint.route == .remote)
        do {
            _ = try WindowsAgentEndpoint("http://192.168.137.1:8732")
            preconditionFailure("Insecure Windows Agent endpoint was accepted")
        } catch WindowsAgentEndpointError.requiresHTTPS {
            // Expected.
        }
        do {
            _ = try WindowsAgentEndpoint("https://127.0.0.1:8732")
            preconditionFailure("iPad loopback endpoint was accepted as a PC")
        } catch WindowsAgentEndpointError.loopbackAddress {
            // Expected.
        }
        do {
            _ = try WindowsAgentEndpoint("https://user:secret@192.168.137.1:8732")
            preconditionFailure("Credentials were accepted inside an Agent URL")
        } catch WindowsAgentEndpointError.containsCredentials {
            // Expected.
        }

        let wireEvent = RemoteInputEvent(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sequence: 42,
            timestampMilliseconds: 1_785_776_400_000,
            payload: .mouseButton(.right, isDown: false)
        )
        let wireData = try JSONEncoder().encode(WindowsAgentInputBatch(protocolVersion: 1, events: [wireEvent]))
        let wireJSON = try JSONSerialization.jsonObject(with: wireData) as? [String: Any]
        let wireEvents = wireJSON?["events"] as? [[String: Any]]
        let wirePayload = wireEvents?.first?["payload"] as? [String: Any]
        let wireButton = wirePayload?["mouseButton"] as? [String: Any]
        precondition(wireJSON?["protocolVersion"] as? Int == 1)
        precondition(wireEvents?.first?["sequence"] as? Int == 42)
        precondition(wireButton?["_0"] as? String == "right")
        precondition(wireButton?["isDown"] as? Bool == false)

        var held = HeldRemoteInputState(modifiers: [.control, .shift], mouseButtons: [.left])
        precondition(held.releaseAll() == .releaseAll)
        precondition(held.modifiers.isEmpty && held.mouseButtons.isEmpty)

        precondition(RemoteClipboardPolicy.payload(text: "secret", pasteAfterCopy: false, userInitiated: false) == nil)
        precondition(RemoteClipboardPolicy.payload(text: "hello", pasteAfterCopy: true, userInitiated: true) == .clipboardText("hello", pasteAfterCopy: true))

        let rejected = MockWindowsRemoteInputService(paired: false)
        do {
            _ = try await rejected.connect()
            preconditionFailure("Unpaired client was accepted")
        } catch WindowsRemoteInputError.unpairedClient {
            // Expected.
        }

        let disabled = MockWindowsRemoteInputService(remoteInputAllowed: false)
        do {
            _ = try await disabled.connect()
            preconditionFailure("Remote input permission was bypassed")
        } catch WindowsRemoteInputError.remoteInputDisabled {
            // Expected.
        }

        let pairingService = MockWindowsRemoteInputService(paired: false)
        let challenge = try await pairingService.beginPairing(deviceName: "Test iPad")
        do {
            _ = try await pairingService.confirmPairing(challengeID: challenge.id, code: "000000")
            preconditionFailure("Invalid pairing code was accepted")
        } catch WindowsRemoteInputError.invalidPairingCode {
            // Expected.
        }
        let pairingResult = try await pairingService.confirmPairing(challengeID: challenge.id, code: "482913")
        precondition(pairingResult.agent.protocolVersion == 1)
        let restoredPairingState = await pairingService.pairingState()
        precondition(restoredPairingState.isPaired)
        let pairedSession = try await pairingService.connect()
        precondition(pairedSession.authenticated && pairedSession.protocolVersion == 1)
        await pairingService.revokePairing()
        do {
            _ = try await pairingService.connect()
            preconditionFailure("Revoked pairing was accepted")
        } catch WindowsRemoteInputError.unpairedClient {
            // Expected.
        }

        let emergencyDisabled = MockWindowsRemoteInputService(emergencyInputDisabled: true)
        do {
            _ = try await emergencyDisabled.connect()
            preconditionFailure("Emergency Disable Input was bypassed")
        } catch WindowsRemoteInputError.emergencyInputDisabled {
            // Expected.
        }

        let service = MockWindowsRemoteInputService()
        let capabilitySnapshot = await service.capabilitySnapshot()
        precondition(capabilitySnapshot.applications.contains { $0.kind == .game })
        precondition(capabilitySnapshot.audioSessions.count == 3)
        precondition(capabilitySnapshot.goXLRConnected && capabilitySnapshot.goXLRChannels.count == 3)

        let launchResult = try await service.perform(.launchApplication(id: "game.primary"))
        precondition(launchResult.confirmed)
        precondition(launchResult.snapshot.applications.first { $0.id == "game.primary" }?.isRunning == true)
        let volumeResult = try await service.perform(.setAudioVolume(id: "music", volume: 2))
        precondition(volumeResult.snapshot.audioSessions.first { $0.id == "music" }?.volume == 1)
        let muteResult = try await service.perform(.setGoXLRMuted(id: "mic", muted: true))
        precondition(muteResult.snapshot.goXLRChannels.first { $0.id == "mic" }?.isMuted == true)

        let inputPermissionIndependentService = MockWindowsRemoteInputService(remoteInputAllowed: false)
        let independentResult = try await inputPermissionIndependentService.perform(.setAudioMuted(id: "music", muted: true))
        precondition(independentResult.confirmed)

        do {
            _ = try await rejected.perform(.launchApplication(id: "game.primary"))
            preconditionFailure("Unpaired capability command was accepted")
        } catch WindowsRemoteInputError.unpairedClient {
            // Expected.
        }

        do {
            _ = try await service.perform(.setGoXLRLevel(id: "missing", level: 0.5))
            preconditionFailure("Missing capability was treated as available")
        } catch WindowsRemoteInputError.capabilityUnavailable {
            // Expected.
        }
        _ = try await service.connect()
        let events = clicks.enumerated().map { index, payload in
            RemoteInputEvent(sequence: UInt64(index + 1), timestampMilliseconds: 2_000, payload: payload)
        }
        try await service.send(events)
        let captured = await service.capturedEvents()
        precondition(captured.first?.payload.isReleasePriority == true)

        let sensitive = [
            RemoteInputEvent(sequence: 20, timestampMilliseconds: 2_100, payload: .unicodeText("private text")),
            RemoteInputEvent(sequence: 21, timestampMilliseconds: 2_100, payload: .clipboardText("private clipboard", pasteAfterCopy: false))
        ]
        try await service.send(sensitive)
        let redacted = await service.capturedEvents().suffix(2).map(\.payload)
        precondition(redacted == [.unicodeText("<redacted>"), .clipboardText("<redacted>", pasteAfterCopy: false)])

        print("Remote input coalescing, safety, Unicode, and authentication validation passed")
    }
}
