import Foundation

struct MockLightState: Codable, Sendable, Equatable {
    var isOn = true
    var brightness = 72.0
    var colorTemperature = 3800.0
    var availability: DeviceAvailability = .available
}

struct MockClimateState: Codable, Sendable, Equatable {
    var isOn = true
    var currentTemperature = 24.0
    var targetTemperature = 22.0
    var hvacMode = "Cool"
    var fanMode = "Auto"
    var swingMode = "Off"
    var availability: DeviceAvailability = .available
}

struct MockTelevisionState: Codable, Sendable, Equatable {
    var isOnline = true
    var isOn = true
    var volume = 34.0
    var isMuted = false
    var source = "HDMI 1"
    var application = "Game Console"
    var isPlaying = true
    var lastRemoteCommand: String?
    var availability: DeviceAvailability = .available
}

enum MockPlugState: String, Codable, Sendable {
    case off
    case turningOn
    case on
    case unavailable
}

enum MockPCBootState: Codable, Sendable, Equatable {
    case offline
    case supplyingPower
    case booting(progress: Double)
    case online
    case failed(String)

    var title: String {
        switch self {
        case .offline: "Offline"
        case .supplyingPower: "Supplying power"
        case .booting(let progress): "Booting \(Int(progress * 100))%"
        case .online: "Online"
        case .failed: "Failed"
        }
    }
}

struct MockPCPowerState: Codable, Sendable, Equatable {
    var plugState: MockPlugState = .off
    var pcState: MockPCBootState = .offline
    var backendReachable = false
}

struct MockMixerChannel: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var level: Double
    var isMuted: Bool
}

struct MockGoXLRState: Codable, Sendable, Equatable {
    var isConnected = true
    var channels = [
        MockMixerChannel(id: "mic", name: "Mic", level: 0.76, isMuted: false),
        MockMixerChannel(id: "chat", name: "Chat", level: 0.68, isMuted: false),
        MockMixerChannel(id: "music", name: "Music", level: 0.62, isMuted: false),
        MockMixerChannel(id: "system", name: "System", level: 0.55, isMuted: false),
        MockMixerChannel(id: "game", name: "Game", level: 0.52, isMuted: true),
        MockMixerChannel(id: "line", name: "Line In", level: 0.40, isMuted: false)
    ]
}

struct MockRoomControlState: Codable, Sendable, Equatable {
    var light = MockLightState()
    var climate = MockClimateState()
    var television = MockTelevisionState()
    var pcPower = MockPCPowerState()
    var goXLR = MockGoXLRState()
    var spotify = MockSpotifyState()

    static let preview = MockRoomControlState()
}
