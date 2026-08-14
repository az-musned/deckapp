import Foundation

/// Wakes the PC directly from this device over the LAN/VPN via a Wake-on-LAN
/// magic packet — no smart plug, cloud integration, or Home Assistant involved.
/// This only works if the PC keeps standby power when shut down (WOL enabled in
/// BIOS/Windows) rather than having its mains power physically cut.
protocol PCWakeOnLANServing: Sendable {
    func wake(macAddress: String, broadcastAddress: String) async throws
}

actor PCWakeOnLANService: PCWakeOnLANServing {
    func wake(macAddress: String, broadcastAddress: String) async throws {
        let packet = try WakeOnLANTransport.magicPacket(macAddress: macAddress)
        var targets = ["255.255.255.255"]
        let broadcast = broadcastAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !broadcast.isEmpty { targets.insert(broadcast, at: 0) }
        try await WakeOnLANTransport.send(packet: packet, targets: Array(Set(targets)))
    }
}
