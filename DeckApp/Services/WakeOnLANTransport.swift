import Foundation
import Darwin

/// Shared Wake-on-LAN magic-packet construction and UDP broadcast, used by both
/// the LG TV and PC wake flows so neither backend needs Home Assistant or any
/// other intermediary to wake a device on the local network.
nonisolated enum WakeOnLANTransport {
    enum TransportError: Error {
        case invalidMACAddress
    }

    static func magicPacket(macAddress: String) throws -> Data {
        let normalized = macAddress.replacingOccurrences(of: "-", with: ":")
        let bytes = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw TransportError.invalidMACAddress }
        return Data(repeating: 0xFF, count: 6) + Data(Array(repeating: bytes, count: 16).flatMap { $0 })
    }

    static func send(packet: Data, targets: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { throw POSIXError(.ENETDOWN) }
            defer { close(descriptor) }
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(.EPERM)
            }
            var sentAtLeastOnce = false
            for _ in 0..<3 {
                for target in targets {
                    for port: UInt16 in [9, 7] {
                        var address = sockaddr_in()
                        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        address.sin_family = sa_family_t(AF_INET)
                        address.sin_port = in_port_t(port).bigEndian
                        inet_pton(AF_INET, target, &address.sin_addr)
                        let sent = packet.withUnsafeBytes { bytes in
                            withUnsafePointer(to: &address) { addressPointer in
                                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                        sentAtLeastOnce = sentAtLeastOnce || sent == packet.count
                    }
                }
                usleep(80_000)
            }
            guard sentAtLeastOnce else { throw POSIXError(.EIO) }
        }.value
    }
}
