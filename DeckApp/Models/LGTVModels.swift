import Foundation

enum LGTVConnectionState: Equatable, Sendable {
    case disconnected
    case discovering
    case connecting
    case awaitingPairing
    case connected
    case reconnecting(attempt: Int)
    case unavailable(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .discovering: "Discovering"
        case .connecting: "Connecting"
        case .awaitingPairing: "Accept on TV"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        }
    }

    var isConnected: Bool { self == .connected }
}

struct LGTVDevice: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var modelName: String?
    var macAddress: String?
    var useSecureConnection: Bool
    var certificateSHA256: String?
    var lastSeen: Date?

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        host: String,
        modelName: String? = nil,
        macAddress: String? = nil,
        useSecureConnection: Bool = false,
        certificateSHA256: String? = nil,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName
        self.macAddress = macAddress
        self.useSecureConnection = useSecureConnection
        self.certificateSHA256 = certificateSHA256
        self.lastSeen = lastSeen
    }

    var port: Int { useSecureConnection ? 3001 : 3000 }
    var webSocketURL: URL? {
        URL(string: "\(useSecureConnection ? "wss" : "ws")://\(host):\(port)")
    }
}

struct LGTVConnectionResult: Equatable, Sendable {
    var clientKey: String
    var certificateSHA256: String?
}

struct LGTVInput: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var iconURL: URL?
}

struct LGTVApplication: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var iconURL: URL?
}

enum LGTVApplicationParser {
    nonisolated static func launcherApplications(from payload: [String: LGTVJSONValue]) -> [LGTVApplication] {
        let values = payload["launchPoints"]?.arrayValue ?? payload["apps"]?.arrayValue ?? []
        let hiddenSystemIDs = [
            "com.webos.app.externalinput",
            "com.webos.app.hdmi",
            "com.webos.app.inputpicker",
            "com.webos.app.notificationcenter",
            "com.webos.app.quicksettings",
            "com.webos.app.screensaver",
            "com.webos.app.settings"
        ]
        var seen = Set<String>()
        return values.compactMap { value in
            guard let object = value.objectValue,
                  object["visible"]?.boolValue != false,
                  let id = object["id"]?.stringValue ?? object["appId"]?.stringValue,
                  !hiddenSystemIDs.contains(where: { id.localizedCaseInsensitiveContains($0) }),
                  seen.insert(id).inserted else { return nil }
            let name = object["title"]?.stringValue ?? object["name"]?.stringValue ?? id
            return LGTVApplication(
                id: id,
                name: name,
                iconURL: (object["largeIcon"]?.stringValue ?? object["icon"]?.stringValue).flatMap(URL.init(string:))
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct LGTVState: Equatable, Sendable {
    var isOn = false
    var volume = 0
    var isMuted = false
    var brightness: Int?
    var currentInputID: String?
    var foregroundApplicationID: String?
    var foregroundApplicationName: String?
    var inputs: [LGTVInput] = []
    var applications: [LGTVApplication] = []
    var lastUpdated: Date?
}

enum LGTVRemoteButton: String, CaseIterable, Sendable {
    case up = "UP"
    case down = "DOWN"
    case left = "LEFT"
    case right = "RIGHT"
    case enter = "ENTER"
    case back = "BACK"
    case home = "HOME"
    case menu = "MENU"
    case exit = "EXIT"
}

enum LGTVPlaybackCommand: String, Sendable {
    case play, pause, stop, rewind, fastForward
}

enum LGTVProtocolError: LocalizedError, Equatable {
    case invalidAddress
    case invalidMessage
    case rejected(String)
    case pairingTimedOut
    case requestTimedOut
    case notConnected
    case missingPointerSocket
    case wakeOnLANNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a valid local IP address or hostname."
        case .invalidMessage: "The TV returned an unreadable response."
        case .rejected(let reason): reason
        case .pairingTimedOut: "Pairing timed out. Accept the prompt shown on the TV and try again."
        case .requestTimedOut: "The television did not respond in time."
        case .notConnected: "The TV is not connected."
        case .missingPointerSocket: "The TV did not provide its remote-input socket."
        case .wakeOnLANNotConfigured: "Add the TV MAC address before using Wake on LAN."
        }
    }
}

enum LGTVJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LGTVJSONValue])
    case array([LGTVJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LGTVJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([LGTVJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    nonisolated var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    nonisolated var intValue: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    nonisolated var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    nonisolated var objectValue: [String: LGTVJSONValue]? { if case .object(let value) = self { value } else { nil } }
    nonisolated var arrayValue: [LGTVJSONValue]? { if case .array(let value) = self { value } else { nil } }
}

struct LGTVProtocolMessage: Codable, Equatable, Sendable {
    var id: String?
    var type: String
    var uri: String?
    var payload: [String: LGTVJSONValue]?
    var error: String? = nil
}

struct LGTVRequest: Equatable, Sendable {
    var uri: String
    var payload: [String: LGTVJSONValue] = [:]
    var subscribes = false
}

enum LGTVRegistrationOutcome: Equatable, Sendable {
    case awaitingConfirmation
    case registered(clientKey: String)
    case rejected(String)
    case unrelated
}

enum LGTVReconnectPolicy {
    static let maximumAttempts = 5
    nonisolated static func delaySeconds(for attempt: Int) -> Double {
        min(pow(2, Double(max(0, attempt - 1))), 8)
    }
}

enum LGTVStateReducer {
    nonisolated static func applyVolumePayload(_ payload: [String: LGTVJSONValue], to state: inout LGTVState, now: Date = .now) {
        if let volume = payload["volume"]?.intValue { state.volume = min(max(volume, 0), 100) }
        if let muted = payload["mute"]?.boolValue ?? payload["muted"]?.boolValue { state.isMuted = muted }
        state.lastUpdated = now
    }

    nonisolated static func applyPictureSettingsPayload(_ payload: [String: LGTVJSONValue], to state: inout LGTVState, now: Date = .now) {
        guard let settings = payload["settings"]?.objectValue else { return }
        if let raw = settings["brightness"] {
            let brightness = raw.intValue ?? raw.stringValue.flatMap { Int($0) }
            if let brightness { state.brightness = min(max(brightness, 0), 100) }
        }
        state.lastUpdated = now
    }
}

enum LGTVProtocolCodec {
    // Keep this list narrowly aligned with the controls DeckApp exposes. LG's
    // Connect SDK places protected and personal-activity grants in this outer
    // permissions array; an altered signed test manifest is not valid.
    static let requestedPermissions = [
        "LAUNCH",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_TV",
        "CONTROL_POWER",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS",
        "READ_INPUT_DEVICE_LIST",
        "READ_RUNNING_APPS"
    ]

    static func registration(clientKey: String?) -> LGTVProtocolMessage {
        var payload: [String: LGTVJSONValue] = [
            "forcePairing": .bool(false),
            "pairingType": .string("PROMPT"),
            "manifest": .object([
                "manifestVersion": .number(1),
                "appId": .string("com.example.DeckApp"),
                "vendorId": .string("com.example"),
                "localizedAppNames": .object(["": .string("DeckApp")]),
                "permissions": .array(requestedPermissions.map(LGTVJSONValue.string))
            ])
        ]
        if let clientKey, !clientKey.isEmpty { payload["client-key"] = .string(clientKey) }
        return LGTVProtocolMessage(id: "register_0", type: "register", uri: nil, payload: payload)
    }

    static func request(_ request: LGTVRequest, id: String) -> LGTVProtocolMessage {
        LGTVProtocolMessage(id: id, type: request.subscribes ? "subscribe" : "request", uri: request.uri, payload: request.payload)
    }

    nonisolated static func registrationOutcome(_ message: LGTVProtocolMessage) -> LGTVRegistrationOutcome {
        if message.type == "registered", let key = message.payload?["client-key"]?.stringValue {
            return .registered(clientKey: key)
        }
        if message.type == "error" {
            return .rejected(message.error ?? message.payload?["errorText"]?.stringValue ?? "The TV rejected pairing.")
        }
        if message.payload?["pairingType"]?.stringValue == "PROMPT" { return .awaitingConfirmation }
        return .unrelated
    }
}

enum LGTVRequests {
    static let volumeSnapshot = LGTVRequest(uri: "ssap://audio/getVolume")
    static let volume = LGTVRequest(uri: "ssap://audio/getVolume", subscribes: true)
    static let brightnessSnapshot = LGTVRequest(
        uri: "ssap://settings/getSystemSettings",
        payload: ["category": .string("picture"), "keys": .array([.string("brightness")])]
    )
    static let foregroundApp = LGTVRequest(uri: "ssap://com.webos.applicationManager/getForegroundAppInfo", subscribes: true)
    static let inputs = LGTVRequest(uri: "ssap://tv/getExternalInputList")
    static let applications = LGTVRequest(uri: "ssap://com.webos.applicationManager/listLaunchPoints")
    static let pointerSocket = LGTVRequest(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket")
    static let powerOff = LGTVRequest(uri: "ssap://system/turnOff")
    static let volumeUp = LGTVRequest(uri: "ssap://audio/volumeUp")
    static let volumeDown = LGTVRequest(uri: "ssap://audio/volumeDown")
    static let channelUp = LGTVRequest(uri: "ssap://tv/channelUp")
    static let channelDown = LGTVRequest(uri: "ssap://tv/channelDown")
    static func setVolume(_ volume: Int) -> LGTVRequest { LGTVRequest(uri: "ssap://audio/setVolume", payload: ["volume": .number(Double(volume))]) }
    static func setMute(_ muted: Bool) -> LGTVRequest { LGTVRequest(uri: "ssap://audio/setMute", payload: ["mute": .bool(muted)]) }
    static func setBrightness(_ value: Int) -> LGTVRequest {
        LGTVRequest(
            uri: "ssap://settings/setSystemSettings",
            payload: ["category": .string("picture"), "settings": .object(["brightness": .string(String(value))])]
        )
    }
    static func switchInput(_ id: String) -> LGTVRequest { LGTVRequest(uri: "ssap://tv/switchInput", payload: ["inputId": .string(id)]) }
    static func launch(_ id: String) -> LGTVRequest { LGTVRequest(uri: "ssap://system.launcher/launch", payload: ["id": .string(id)]) }
    static func playback(_ command: LGTVPlaybackCommand) -> LGTVRequest {
        let suffix = command == .fastForward ? "fastForward" : command.rawValue
        return LGTVRequest(uri: "ssap://media.controls/\(suffix)")
    }
}
