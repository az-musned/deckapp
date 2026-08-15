import Foundation

enum RemoteConnectionRoute: String, Codable, Sendable {
    case local = "Local"
    case vpn = "VPN"
    case remote = "Remote"
}

enum WindowsAgentConnectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case local
    case vpn

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .local: "Local"
        case .vpn: "VPN"
        }
    }
}

enum RemoteConnectionState: Codable, Sendable, Equatable {
    case disconnected
    case connecting
    case connected(route: RemoteConnectionRoute, latencyMilliseconds: Int)
    case highLatency(route: RemoteConnectionRoute, latencyMilliseconds: Int)
    case permissionDisabled
    case emergencyDisabled
    case authenticationRejected
    case unavailable(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected(let route, _): route.rawValue
        case .highLatency: "High Latency"
        case .permissionDisabled: "Input Disabled"
        case .emergencyDisabled: "Emergency Disabled"
        case .authenticationRejected: "Pairing Rejected"
        case .unavailable: "Unavailable"
        }
    }

    var latencyMilliseconds: Int? {
        switch self {
        case .connected(_, let latency), .highLatency(_, let latency): latency
        default: nil
        }
    }

    var acceptsInput: Bool {
        switch self {
        case .connected, .highLatency: true
        default: false
        }
    }
}

/// The PC remote's extra panel, shown below the always-visible touchpad and media row.
enum RemoteControlMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case keyboard
    case agent
    case shortcuts

    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .agent: "Agent"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: "keyboard.fill"
        case .agent: "cpu.fill"
        case .shortcuts: "command"
        }
    }
}

struct RemoteModifiers: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int

    static let control = RemoteModifiers(rawValue: 1 << 0)
    static let alt = RemoteModifiers(rawValue: 1 << 1)
    static let shift = RemoteModifiers(rawValue: 1 << 2)
    static let windows = RemoteModifiers(rawValue: 1 << 3)

    static let allCases: [(modifier: RemoteModifiers, title: String, symbol: String)] = [
        (.control, "Ctrl", "control"),
        (.alt, "Alt", "option"),
        (.shift, "Shift", "shift.fill"),
        (.windows, "Win", "command")
    ]
}

enum RemoteMouseButton: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case middle
}

/// Extend mode's touch phases, mirroring UIKit's touchesBegan/Moved/Ended/Cancelled so a
/// touch's full down-drag-up lifecycle maps 1:1 onto the Windows Agent's absolute pointer.
enum RemoteTouchPhase: String, Codable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

enum RemoteVirtualKey: String, Codable, CaseIterable, Sendable {
    case enter
    case tab
    case escape
    case backspace
    case delete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case altTab
    case copy
    case paste
    case undo
    case redo
    case desktop
    case function1
    case function2
    case function3
    case function4
    case function5
    case function6
    case function7
    case function8
    case function9
    case function10
    case function11
    case function12
    case mediaPlayPause
    case mediaPrevious
    case mediaNext
    case volumeDown
    case volumeUp
    case volumeMute

    var displayTitle: String {
        switch self {
        case .escape: "Esc"
        case .altTab: "Alt+Tab"
        case .desktop: "Desktop"
        case .copy: "Copy"
        case .paste: "Paste"
        case .undo: "Undo"
        case .redo: "Redo"
        default: rawValue
        }
    }

    var displaySymbol: String {
        switch self {
        case .escape: "escape"
        case .altTab: "rectangle.on.rectangle"
        case .desktop: "macwindow"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        default: "keyboard"
        }
    }
}

enum RemoteInputPayload: Codable, Sendable, Equatable {
    case relativePointer(deltaX: Double, deltaY: Double, acceleration: Bool, precision: Bool)
    case scroll(deltaX: Double, deltaY: Double)
    case mouseButton(RemoteMouseButton, isDown: Bool)
    case virtualKey(RemoteVirtualKey, isDown: Bool, modifiers: RemoteModifiers)
    case modifier(RemoteModifiers, isDown: Bool)
    case unicodeText(String)
    case clipboardText(String, pasteAfterCopy: Bool)
    case absoluteTouch(xFraction: Double, yFraction: Double, phase: RemoteTouchPhase)
    case releaseAll

    nonisolated var isReleasePriority: Bool {
        switch self {
        case .mouseButton(_, false), .virtualKey(_, false, _), .modifier(_, false), .releaseAll:
            true
        case .absoluteTouch(_, _, let phase):
            phase == .ended || phase == .cancelled
        default:
            false
        }
    }
}

struct RemoteInputEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sequence: UInt64
    let timestampMilliseconds: UInt64
    let payload: RemoteInputPayload

    nonisolated init(
        id: UUID = UUID(),
        sequence: UInt64,
        timestampMilliseconds: UInt64,
        payload: RemoteInputPayload
    ) {
        self.id = id
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.payload = payload
    }
}

struct RemoteInputPreferences: Codable, Sendable, Equatable {
    var pointerSensitivity = 1.0
    var scrollSensitivity = 1.0
    var naturalScrolling = true
    var pointerAcceleration = true
    var precisionMode = false
    var twoFingerRightClick = true
    var shortcutRow: [RemoteVirtualKey] = [.escape, .altTab, .desktop]
}

struct PointerEventBuffer: Sendable, Equatable {
    private(set) var pointerDeltaX = 0.0
    private(set) var pointerDeltaY = 0.0
    private(set) var scrollDeltaX = 0.0
    private(set) var scrollDeltaY = 0.0
    private(set) var latestTimestampMilliseconds: UInt64?

    var isEmpty: Bool {
        pointerDeltaX == 0 && pointerDeltaY == 0 && scrollDeltaX == 0 && scrollDeltaY == 0
    }

    mutating func enqueuePointer(deltaX: Double, deltaY: Double, timestampMilliseconds: UInt64) {
        pointerDeltaX += deltaX
        pointerDeltaY += deltaY
        latestTimestampMilliseconds = timestampMilliseconds
    }

    mutating func enqueueScroll(deltaX: Double, deltaY: Double, timestampMilliseconds: UInt64) {
        scrollDeltaX += deltaX
        scrollDeltaY += deltaY
        latestTimestampMilliseconds = timestampMilliseconds
    }

    mutating func drain(
        nowMilliseconds: UInt64,
        staleAfterMilliseconds: UInt64 = 100,
        acceleration: Bool,
        precision: Bool
    ) -> [RemoteInputPayload] {
        guard let latestTimestampMilliseconds,
              nowMilliseconds >= latestTimestampMilliseconds,
              nowMilliseconds - latestTimestampMilliseconds <= staleAfterMilliseconds else {
            self = PointerEventBuffer()
            return []
        }

        var payloads: [RemoteInputPayload] = []
        if pointerDeltaX != 0 || pointerDeltaY != 0 {
            payloads.append(.relativePointer(
                deltaX: pointerDeltaX,
                deltaY: pointerDeltaY,
                acceleration: acceleration,
                precision: precision
            ))
        }
        if scrollDeltaX != 0 || scrollDeltaY != 0 {
            payloads.append(.scroll(deltaX: scrollDeltaX, deltaY: scrollDeltaY))
        }
        self = PointerEventBuffer()
        return payloads
    }
}

struct HeldRemoteInputState: Sendable, Equatable {
    var modifiers: RemoteModifiers = []
    var mouseButtons: Set<RemoteMouseButton> = []

    mutating func releaseAll() -> RemoteInputPayload {
        modifiers = []
        mouseButtons = []
        return .releaseAll
    }
}

struct RemoteAgentSession: Codable, Sendable, Equatable {
    let sessionID: UUID
    let protocolVersion: Int
    let route: RemoteConnectionRoute
    let latencyMilliseconds: Int
    let remoteInputAllowed: Bool
    let authenticated: Bool
}

nonisolated enum WindowsAgentEndpointError: LocalizedError, Sendable, Equatable {
    case invalidAddress
    case requiresHTTPS
    case containsCredentials
    case loopbackAddress

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a valid Windows Agent address, including its hostname or IP address."
        case .requiresHTTPS: "The Windows Agent address must use HTTPS."
        case .containsCredentials: "Do not place credentials, query parameters, or fragments in the Agent address."
        case .loopbackAddress: "A loopback address points back to this iPhone or iPad, not to the Windows PC."
        }
    }
}

nonisolated struct WindowsAgentEndpoint: Sendable, Equatable {
    let baseURL: URL
    let route: RemoteConnectionRoute
    let displayAddress: String

    init(_ address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw WindowsAgentEndpointError.invalidAddress
        }
        guard scheme == "https" else { throw WindowsAgentEndpointError.requiresHTTPS }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WindowsAgentEndpointError.containsCredentials
        }
        guard host != "localhost", host != "::1", !host.hasPrefix("127.") else {
            throw WindowsAgentEndpointError.loopbackAddress
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.query = nil
        components?.fragment = nil
        guard let normalizedURL = components?.url else { throw WindowsAgentEndpointError.invalidAddress }

        baseURL = normalizedURL
        route = Self.route(for: host)
        displayAddress = url.port.map { "\(host):\($0)" } ?? host
    }

    func url(path: String, webSocket: Bool = false) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = webSocket ? "wss" : "https"
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard let endpoint = components?.url else { throw WindowsAgentEndpointError.invalidAddress }
        return endpoint
    }

    private static func route(for host: String) -> RemoteConnectionRoute {
        if host.hasSuffix(".ts.net") || isTailscaleIPv4(host) { return .vpn }
        if host.hasSuffix(".local") || isPrivateIPv4(host) || isPrivateIPv6(host) { return .local }
        return .remote
    }

    private static func ipv4Parts(_ host: String) -> [Int]? {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        let values = pieces.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return values
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        guard let parts = ipv4Parts(host) else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }

    private static func isTailscaleIPv4(_ host: String) -> Bool {
        guard let parts = ipv4Parts(host) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9")
    }
}

nonisolated struct WindowsAgentInputBatch: Codable, Sendable {
    let protocolVersion: Int
    let events: [RemoteInputEvent]
}

nonisolated enum WindowsAgentPairingState: Codable, Sendable, Equatable {
    case unknown
    case unpaired
    case pairing(challengeID: UUID, expiresAt: Date)
    case paired(PairedWindowsAgent)
    case revoked

    var title: String {
        switch self {
        case .unknown: "Checking…"
        case .unpaired: "Not paired"
        case .pairing: "Enter pairing code"
        case .paired(let agent): "Paired with \(agent.displayName)"
        case .revoked: "Pairing revoked"
        }
    }

    var isPaired: Bool {
        if case .paired = self { true } else { false }
    }
}

nonisolated struct PairedWindowsAgent: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let displayName: String
    let pairedAt: Date
    let protocolVersion: Int
}

nonisolated struct WindowsAgentPairingChallenge: Codable, Sendable, Equatable {
    let id: UUID
    let expiresAt: Date
    let agentDisplayName: String
}

nonisolated struct WindowsAgentPairingResult: Codable, Sendable, Equatable {
    let agent: PairedWindowsAgent
    let credentialToken: String
}

nonisolated struct WindowsAgentSecurityState: Codable, Sendable, Equatable {
    let remoteInputAllowed: Bool
    let inputInjectionAvailable: Bool
    let emergencyInputDisabled: Bool
    let screenShareAllowed: Bool

    init(remoteInputAllowed: Bool, inputInjectionAvailable: Bool, emergencyInputDisabled: Bool, screenShareAllowed: Bool = false) {
        self.remoteInputAllowed = remoteInputAllowed
        self.inputInjectionAvailable = inputInjectionAvailable
        self.emergencyInputDisabled = emergencyInputDisabled
        self.screenShareAllowed = screenShareAllowed
    }

    var acceptsRemoteInput: Bool {
        remoteInputAllowed && inputInjectionAvailable && !emergencyInputDisabled
    }
}

nonisolated enum WindowsAgentApplicationKind: String, Codable, Sendable {
    case application, game
}

nonisolated struct WindowsAgentApplication: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let kind: WindowsAgentApplicationKind
    let isRunning: Bool
}

nonisolated struct WindowsAudioSessionState: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let volume: Double
    let isMuted: Bool
}

nonisolated struct WindowsGoXLRChannelState: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let level: Double
    let isMuted: Bool
}

nonisolated struct WindowsAgentCapabilitySnapshot: Codable, Sendable, Equatable {
    let applications: [WindowsAgentApplication]
    let audioSessions: [WindowsAudioSessionState]
    let goXLRChannels: [WindowsGoXLRChannelState]
    let goXLRConnected: Bool
}

nonisolated enum WindowsAgentCapabilityCommand: Sendable, Equatable {
    case launchApplication(id: String)
    case setAudioVolume(id: String, volume: Double)
    case setAudioMuted(id: String, muted: Bool)
    case setGoXLRLevel(id: String, level: Double)
    case setGoXLRMuted(id: String, muted: Bool)

    var title: String {
        switch self {
        case .launchApplication: "Launch application"
        case .setAudioVolume: "Change app volume"
        case .setAudioMuted(_, let muted): muted ? "Mute app audio" : "Unmute app audio"
        case .setGoXLRLevel: "Change GoXLR level"
        case .setGoXLRMuted(_, let muted): muted ? "Mute GoXLR channel" : "Unmute GoXLR channel"
        }
    }
}

nonisolated struct WindowsAgentCommandResult: Sendable, Equatable {
    let command: WindowsAgentCapabilityCommand
    let confirmed: Bool
    let message: String
    let snapshot: WindowsAgentCapabilitySnapshot
}

nonisolated struct WindowsAgentCommandExecution: Identifiable, Sendable {
    let id: UUID
    let command: WindowsAgentCapabilityCommand
    var status: CommandStatus
    var message: String

    init(
        id: UUID = UUID(),
        command: WindowsAgentCapabilityCommand,
        status: CommandStatus,
        message: String
    ) {
        self.id = id
        self.command = command
        self.status = status
        self.message = message
    }
}

enum RemoteClipboardPolicy {
    nonisolated static func payload(
        text: String,
        pasteAfterCopy: Bool,
        userInitiated: Bool
    ) -> RemoteInputPayload? {
        guard userInitiated, !text.isEmpty else { return nil }
        return .clipboardText(text, pasteAfterCopy: pasteAfterCopy)
    }
}
