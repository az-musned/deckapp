import Foundation
import Network
import Security
import CryptoKit
import Darwin

protocol LGTVDevicePersisting: Sendable {
    func loadDevices() -> [LGTVDevice]
    func saveDevices(_ devices: [LGTVDevice])
    func loadSelectedDeviceID() -> UUID?
    func saveSelectedDeviceID(_ id: UUID?)
}

struct LGTVDevicePersistence: LGTVDevicePersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let devicesKey = "lgWebOS.devices"
    private let selectedKey = "lgWebOS.selectedDeviceID"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadDevices() -> [LGTVDevice] {
        guard let data = defaults.data(forKey: devicesKey) else { return [] }
        return (try? JSONDecoder().decode([LGTVDevice].self, from: data)) ?? []
    }

    func saveDevices(_ devices: [LGTVDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: devicesKey)
    }

    func loadSelectedDeviceID() -> UUID? {
        defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
    }

    func saveSelectedDeviceID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedKey)
    }
}

protocol LGTVDiscovering: Sendable {
    func discover(timeout: TimeInterval) async throws -> [LGTVDevice]
}

actor LGTVSSDPDiscoveryService: LGTVDiscovering {
    func discover(timeout: TimeInterval = 3) async throws -> [LGTVDevice] {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { throw POSIXError(.ENETDOWN) }
            defer { close(descriptor) }

            var timeoutValue = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(1900).bigEndian
            inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)

            let queries = [
                "urn:lge-com:service:webos-second-screen:1",
                "urn:schemas-upnp-org:device:MediaRenderer:1"
            ].map { target in
                "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            }
            var sentQuery = false
            for query in queries {
                query.withCString { pointer in
                    withUnsafePointer(to: &address) { addressPointer in
                        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            if sendto(descriptor, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) >= 0 {
                                sentQuery = true
                            }
                        }
                    }
                }
            }

            var devicesByHost: [String: LGTVDevice] = [:]
            if sentQuery {
                let deadline = Date().addingTimeInterval(timeout)
                var buffer = [UInt8](repeating: 0, count: 8192)
                while Date() < deadline, !Task.isCancelled {
                    let count = recv(descriptor, &buffer, buffer.count, 0)
                    guard count > 0 else { continue }
                    let response = String(decoding: buffer.prefix(count), as: UTF8.self)
                    let headers = Self.parseHeaders(response)
                    guard let location = headers["location"], let url = URL(string: location), let host = url.host else { continue }
                    let server = headers["server"] ?? "LG webOS TV"
                    let name = server.localizedCaseInsensitiveContains("webos") ? "LG webOS TV" : server
                    devicesByHost[host] = LGTVDevice(name: name, host: host, modelName: server, lastSeen: .now)
                }
            }

            // Physical iOS devices require Apple's restricted multicast entitlement for SSDP.
            // A user-initiated, rate-limited /24 TCP probe keeps discovery useful without it.
            if devicesByHost.isEmpty, let localAddress = Self.localWiFiIPv4Address() {
                for candidate in Self.scanWebOSPorts(near: localAddress) {
                    devicesByHost[candidate.host] = candidate
                }
            }
            return devicesByHost.values.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        }.value
    }

    nonisolated static func parseHeaders(_ response: String) -> [String: String] {
        response.components(separatedBy: "\r\n").dropFirst().reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
    }

    nonisolated static func candidateHosts(near localAddress: String) -> [String] {
        let octets = localAddress.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return [] }
        let prefix = octets.prefix(3).joined(separator: ".")
        return (1...254).map { "\(prefix).\($0)" }.filter { $0 != localAddress }
    }

    private nonisolated static func localWiFiIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: interface.ifa_name)
            if name == "en0" { return value }
            if value.hasPrefix("10.") || value.hasPrefix("192.168.") || value.hasPrefix("172.") { fallback = fallback ?? value }
        }
        return fallback
    }

    private nonisolated static func scanWebOSPorts(near localAddress: String) -> [LGTVDevice] {
        let hosts = candidateHosts(near: localAddress)
        let nonSecure = hostsWithOpenPort(3000, among: hosts)
        let secure = hostsWithOpenPort(3001, among: hosts.filter { !nonSecure.contains($0) })
        return nonSecure.map { LGTVDevice(name: "Possible LG webOS TV", host: $0, lastSeen: .now) }
            + secure.map { LGTVDevice(name: "Possible LG webOS TV", host: $0, useSecureConnection: true, lastSeen: .now) }
    }

    private nonisolated static func hostsWithOpenPort(_ port: UInt16, among hosts: [String]) -> [String] {
        var openHosts: [String] = []
        for start in stride(from: 0, to: hosts.count, by: 32) {
            guard !Task.isCancelled else { break }
            let batch = Array(hosts[start..<min(start + 32, hosts.count)])
            var sockets: [(descriptor: Int32, host: String)] = []
            for host in batch {
                let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard descriptor >= 0 else { continue }
                _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(port).bigEndian
                inet_pton(AF_INET, host, &address.sin_addr)
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                sockets.append((descriptor, host))
            }
            usleep(180_000)
            for candidate in sockets {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(candidate.descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 {
                    openHosts.append(candidate.host)
                }
                close(candidate.descriptor)
            }
        }
        return openHosts
    }
}

protocol LGTVWakeOnLANServing: Sendable {
    func wake(macAddress: String, host: String) async throws
}

actor LGTVWakeOnLANService: LGTVWakeOnLANServing {
    nonisolated static func magicPacket(macAddress: String) throws -> Data {
        do { return try WakeOnLANTransport.magicPacket(macAddress: macAddress) }
        catch { throw LGTVProtocolError.wakeOnLANNotConfigured }
    }

    nonisolated static func broadcastTargets(for host: String) -> [String] {
        var targets = ["255.255.255.255"]
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            targets.insert(octets.prefix(3).joined(separator: ".") + ".255", at: 0)
        }
        return Array(Set(targets)).sorted { lhs, rhs in
            lhs == "255.255.255.255" ? false : (rhs == "255.255.255.255" ? true : lhs < rhs)
        }
    }

    func wake(macAddress: String, host: String) async throws {
        let packet = try Self.magicPacket(macAddress: macAddress)
        try await WakeOnLANTransport.send(packet: packet, targets: Self.broadcastTargets(for: host))
    }
}

final class LGTVLocalWebSocketTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedHost: String
    private let pinnedCertificateSHA256: String?
    private let lock = NSLock()
    private var _observedCertificateSHA256: String?

    init(expectedHost: String, pinnedCertificateSHA256: String?) {
        self.expectedHost = expectedHost
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }

    var observedCertificateSHA256: String? {
        lock.withLock { _observedCertificateSHA256 }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(expectedHost) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let certificateData = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: certificateData).map { String(format: "%02X", $0) }.joined(separator: ":")
        if let pinnedCertificateSHA256, pinnedCertificateSHA256 != fingerprint {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        guard subject.localizedCaseInsensitiveContains("LGE") || subject.localizedCaseInsensitiveContains("LG") else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // LG's port 3001 certificate identifies its private TV chain rather than the local IP.
        // Validate that chain and dates, scope it to this exact endpoint, then pin the leaf after pairing.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [chain.last ?? leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.withLock { _observedCertificateSHA256 = fingerprint }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
protocol LGTVConnectionServing: AnyObject {
    var onDisconnect: (@MainActor (Error?) -> Void)? { get set }
    func connect(to device: LGTVDevice, clientKey: String?, pairingChanged: @escaping @MainActor (Bool) -> Void) async throws -> LGTVConnectionResult
    func disconnect()
    func request(_ request: LGTVRequest) async throws -> LGTVProtocolMessage
    func subscribe(_ request: LGTVRequest, handler: @escaping @MainActor (LGTVProtocolMessage) -> Void) async throws
    func sendRemoteButton(_ button: LGTVRemoteButton) async throws
}

@MainActor
final class LGTVConnectionClient: LGTVConnectionServing {
    var onDisconnect: (@MainActor (Error?) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pointerTask: URLSessionWebSocketTask?
    private var pointerConnectTask: Task<URLSessionWebSocketTask, Error>?
    private var nextRequestID = 1
    private var pending: [String: CheckedContinuation<LGTVProtocolMessage, Error>] = [:]
    private var subscriptions: [String: @MainActor (LGTVProtocolMessage) -> Void] = [:]

    func connect(to device: LGTVDevice, clientKey: String?, pairingChanged: @escaping @MainActor (Bool) -> Void) async throws -> LGTVConnectionResult {
        disconnect()
        guard let url = device.webSocketURL else { throw LGTVProtocolError.invalidAddress }
        let delegate = device.useSecureConnection
            ? LGTVLocalWebSocketTrustDelegate(expectedHost: device.host, pinnedCertificateSHA256: device.certificateSHA256)
            : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        try await send(LGTVProtocolCodec.registration(clientKey: clientKey), on: task)
        if clientKey == nil { pairingChanged(true) }

        let pairingDeadline = Date().addingTimeInterval(60)
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            task.cancel(with: .policyViolation, reason: nil)
        }
        defer { timeoutTask.cancel() }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() }
            catch {
                if Date() >= pairingDeadline { throw LGTVProtocolError.pairingTimedOut }
                throw error
            }
            let decoded = try decode(message)
            switch LGTVProtocolCodec.registrationOutcome(decoded) {
            case .registered(let key):
                pairingChanged(false)
                startReceiveLoop(task)
                return LGTVConnectionResult(clientKey: key, certificateSHA256: delegate?.observedCertificateSHA256)
            case .rejected(let reason):
                throw LGTVProtocolError.rejected(reason)
            case .awaitingConfirmation:
                pairingChanged(true)
            case .unrelated:
                break
            }
        }
        throw CancellationError()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        pointerTask?.cancel(with: .goingAway, reason: nil)
        pointerConnectTask?.cancel()
        session?.invalidateAndCancel()
        task = nil
        pointerTask = nil
        pointerConnectTask = nil
        session = nil
        let continuations = pending.values
        pending.removeAll()
        subscriptions.removeAll()
        continuations.forEach { $0.resume(throwing: LGTVProtocolError.notConnected) }
    }

    func request(_ request: LGTVRequest) async throws -> LGTVProtocolMessage {
        guard let task else { throw LGTVProtocolError.notConnected }
        let id = "request_\(nextRequestID)"
        nextRequestID += 1
        let message = LGTVProtocolCodec.request(request, id: id)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
                continuation.resume(throwing: LGTVProtocolError.requestTimedOut)
            }
            Task { @MainActor in
                do { try await self.send(message, on: task) }
                catch {
                    if let continuation = self.pending.removeValue(forKey: id) { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func subscribe(_ request: LGTVRequest, handler: @escaping @MainActor (LGTVProtocolMessage) -> Void) async throws {
        guard let task else { throw LGTVProtocolError.notConnected }
        let id = "subscribe_\(nextRequestID)"
        nextRequestID += 1
        subscriptions[id] = handler
        try await send(LGTVProtocolCodec.request(LGTVRequest(uri: request.uri, payload: request.payload, subscribes: true), id: id), on: task)
    }

    func sendRemoteButton(_ button: LGTVRemoteButton) async throws {
        guard let session else { throw LGTVProtocolError.notConnected }
        if pointerTask == nil {
            if pointerConnectTask == nil {
                pointerConnectTask = Task { @MainActor [weak self] in
                    guard let self else { throw LGTVProtocolError.notConnected }
                    let response = try await self.request(LGTVRequests.pointerSocket)
                    guard let path = response.payload?["socketPath"]?.stringValue,
                          let url = URL(string: path) else {
                        throw LGTVProtocolError.missingPointerSocket
                    }
                    let pointer = session.webSocketTask(with: url)
                    pointer.resume()
                    return pointer
                }
            }
            do {
                pointerTask = try await pointerConnectTask?.value
                pointerConnectTask = nil
            } catch {
                pointerConnectTask = nil
                throw error
            }
        }
        guard let pointerTask else { throw LGTVProtocolError.missingPointerSocket }
        let message = "type:button\nname:\(button.rawValue)\n\n"
        try await pointerTask.send(.string(message))
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                do { try await self?.sendPing(on: task) }
                catch {
                    self?.onDisconnect?(error)
                    return
                }
            }
        }
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let decoded = try self.decode(message)
                    if let id = decoded.id, let subscription = self.subscriptions[id] {
                        subscription(decoded)
                    } else if let id = decoded.id, let continuation = self.pending.removeValue(forKey: id) {
                        if decoded.type == "error" {
                            continuation.resume(throwing: LGTVProtocolError.rejected(decoded.error ?? decoded.payload?["errorText"]?.stringValue ?? "TV request failed."))
                        } else {
                            continuation.resume(returning: decoded)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.onDisconnect?(error)
            }
        }
    }

    private func send(_ message: LGTVProtocolMessage, on task: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(message)
        guard let string = String(data: data, encoding: .utf8) else { throw LGTVProtocolError.invalidMessage }
        try await task.send(.string(string))
    }

    private func sendPing(on task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) throws -> LGTVProtocolMessage {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw LGTVProtocolError.invalidMessage
        }
        return try JSONDecoder().decode(LGTVProtocolMessage.self, from: data)
    }
}
