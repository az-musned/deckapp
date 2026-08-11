import Foundation

/// Keeps one authenticated input session active while allowing the controller to
/// prefer a low-latency LAN route and fall back to a private VPN route.
actor FailoverWindowsAgentService: WindowsRemoteInputServing {
    private let clients: [WindowsAgentClient]
    private var activeIndex: Int?
    private var pairingIndex: Int?

    init(addresses: [String], defaults: UserDefaults = .standard) {
        clients = addresses.enumerated().map { index, address in
            // The first endpoint is the preferred LAN route. Bound its probe so
            // moving to cellular does not hold up the reachable VPN fallback.
            WindowsAgentClient(
                address: address,
                defaults: defaults,
                requestTimeout: index == 0 ? 1.5 : 5
            )
        }
    }

    func restoreCredential(_ token: String?) async {
        for client in clients { await client.restoreCredential(token) }
    }

    func pairingState() async -> WindowsAgentPairingState {
        for index in preferredIndices {
            let state = await clients[index].pairingState()
            if state.isPaired {
                activeIndex = index
                return state
            }
        }
        return .unpaired
    }

    func beginPairing(deviceName: String) async throws -> WindowsAgentPairingChallenge {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                let challenge = try await clients[index].beginPairing(deviceName: deviceName)
                pairingIndex = index
                activeIndex = index
                return challenge
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func confirmPairing(challengeID: UUID, code: String) async throws -> WindowsAgentPairingResult {
        guard let index = pairingIndex else { throw WindowsRemoteInputError.pairingExpired }
        let result = try await clients[index].confirmPairing(challengeID: challengeID, code: code)
        activeIndex = index
        pairingIndex = nil
        return result
    }

    func revokePairing() async {
        if let index = activeIndex {
            await clients[index].revokePairing()
        }
        for client in clients { await client.disconnect() }
        activeIndex = nil
        pairingIndex = nil
    }

    func securityState() async -> WindowsAgentSecurityState {
        do { return try await refreshedSecurityState() }
        catch {
            return WindowsAgentSecurityState(
                remoteInputAllowed: false,
                inputInjectionAvailable: false,
                emergencyInputDisabled: false
            )
        }
    }

    func refreshedSecurityState() async throws -> WindowsAgentSecurityState {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                let state = try await clients[index].refreshedSecurityState()
                activeIndex = index
                return state
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func capabilitySnapshot() async -> WindowsAgentCapabilitySnapshot {
        for index in preferredIndices {
            let snapshot = await clients[index].capabilitySnapshot()
            if !snapshot.isEmpty {
                activeIndex = index
                return snapshot
            }
        }
        return WindowsAgentCapabilitySnapshot(applications: [], audioSessions: [], goXLRChannels: [], goXLRConnected: false)
    }

    func perform(_ command: WindowsAgentCapabilityCommand) async throws -> WindowsAgentCommandResult {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                let result = try await clients[index].perform(command)
                activeIndex = index
                return result
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func connect() async throws -> RemoteAgentSession {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                let session = try await clients[index].connect()
                activeIndex = index
                return session
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func isConnected() async -> Bool {
        guard let activeIndex else { return false }
        return await clients[activeIndex].isConnected()
    }

    func currentLatencyMilliseconds() async -> Int? {
        guard let activeIndex else { return nil }
        return await clients[activeIndex].currentLatencyMilliseconds()
    }

    func disconnectReason() async -> String? {
        guard let activeIndex else { return nil }
        return await clients[activeIndex].disconnectReason()
    }

    func send(_ events: [RemoteInputEvent]) async throws {
        guard let activeIndex else { throw WindowsRemoteInputError.disconnected }
        try await clients[activeIndex].send(events)
    }

    func disconnect() async {
        for client in clients { await client.disconnect() }
        activeIndex = nil
    }

    func sendHotkey(keyCode: Int, modifiers: Int) async throws {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                try await clients[index].sendHotkey(keyCode: keyCode, modifiers: modifiers)
                activeIndex = index
                return
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func shutdown() async throws {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for index in preferredIndices {
            do {
                try await clients[index].shutdown()
                activeIndex = index
                return
            } catch {
                lastError = error
                if !Self.canFailOver(after: error) { throw error }
            }
        }
        throw lastError
    }

    func isReachable() async -> Bool {
        for index in preferredIndices {
            if await clients[index].isReachable() {
                activeIndex = index
                return true
            }
        }
        return false
    }

    private var preferredIndices: [Int] {
        let all = Array(clients.indices)
        guard let activeIndex, all.contains(activeIndex) else { return all }
        return [activeIndex] + all.filter { $0 != activeIndex }
    }

    nonisolated private static func canFailOver(after error: Error) -> Bool {
        guard let remoteError = error as? WindowsRemoteInputError else { return true }
        switch remoteError {
        case .disconnected, .invalidAddress, .invalidResponse:
            return true
        case .unpairedClient, .remoteInputDisabled, .inputInjectionUnavailable,
             .invalidPairingCode, .pairingExpired, .emergencyInputDisabled,
             .capabilityUnavailable, .protocolMismatch:
            return false
        }
    }
}

nonisolated private extension WindowsAgentCapabilitySnapshot {
    var isEmpty: Bool {
        applications.isEmpty && audioSessions.isEmpty && goXLRChannels.isEmpty && !goXLRConnected
    }
}
