import Foundation

enum ConnectionRoute: String, Sendable {
    case local = "Local"
    case remote = "Remote"
    case offline = "Offline"
}

enum ConnectionHealth: String, Sendable {
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    case unavailable = "Unavailable"
}

struct ConnectionState: Identifiable, Sendable {
    let id: UUID
    let service: String
    var route: ConnectionRoute
    var health: ConnectionHealth

    init(id: UUID = UUID(), service: String, route: ConnectionRoute, health: ConnectionHealth) {
        self.id = id
        self.service = service
        self.route = route
        self.health = health
    }
}

struct LightDevice: Identifiable, Sendable {
    let id: UUID
    let name: String
    var brightness: Double
    var isOn: Bool

    init(id: UUID = UUID(), name: String, brightness: Double, isOn: Bool = true) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.isOn = isOn
    }
}

struct ClimateState: Sendable {
    var currentTemperature: Double
    var targetTemperature: Double
    var isCooling: Bool
}

struct TVState: Sendable {
    var source: String
    var isPlaying: Bool
    var volume: Double
}

struct ScenePreset: Identifiable, Sendable {
    let id: UUID
    let name: String
    let subtitle: String
    let symbol: String
    let tintName: String

    init(id: UUID = UUID(), name: String, subtitle: String, symbol: String, tintName: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.symbol = symbol
        self.tintName = tintName
    }
}

struct MediaState: Sendable {
    var source: String
    var title: String
    var artist: String
    var destination: String
    var isPlaying: Bool
    var progress: Double
}

struct PCState: Sendable {
    var isOnline: Bool
    var volume: Double
    var microphoneMuted: Bool
}

struct RoomDashboard: Sendable {
    var roomName: String
    var temperature: Double
    var lights: [LightDevice]
    var climate: ClimateState
    var tv: TVState
    var scenes: [ScenePreset]
    var media: MediaState
    var pc: PCState
    var connections: [ConnectionState]

    static let preview = RoomDashboard(
        roomName: "My Room",
        temperature: 24.6,
        lights: [
            LightDevice(name: "All Lights", brightness: 1),
            LightDevice(name: "TV Lights", brightness: 0.8),
            LightDevice(name: "Console Lights", brightness: 0.6)
        ],
        climate: ClimateState(currentTemperature: 24, targetTemperature: 22, isCooling: true),
        tv: TVState(source: "HDMI 1", isPlaying: true, volume: 0.45),
        scenes: [
            ScenePreset(name: "Movie Mode", subtitle: "Relax and enjoy", symbol: "movieclapper.fill", tintName: "purple"),
            ScenePreset(name: "Gaming Mode", subtitle: "Game on", symbol: "gamecontroller.fill", tintName: "green"),
            ScenePreset(name: "Sleep Mode", subtitle: "Wind down", symbol: "moon.fill", tintName: "blue"),
            ScenePreset(name: "All Off", subtitle: "Power down", symbol: "power", tintName: "red")
        ],
        media: MediaState(source: "Spotify", title: "The Midnight", artist: "Sunset", destination: "Bedroom TV", isPlaying: true, progress: 0.34),
        pc: PCState(isOnline: true, volume: 0.6, microphoneMuted: true),
        connections: [
            ConnectionState(service: "Home Assistant", route: .local, health: .connected),
            ConnectionState(service: "Companion", route: .offline, health: .unavailable)
        ]
    )
}
