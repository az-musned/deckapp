import Foundation

nonisolated enum GreeClimateAvailability: String, Codable, Sendable, Equatable {
    case unknown
    case reachable
    case unreachable
}

/// Distinguishes a live MQTT read from a last-known value carried across
/// backgrounding, since iOS does not keep the cloud socket alive in the background.
nonisolated enum GreeStateConfidence: String, Codable, Sendable, Equatable {
    case confirmed
    case pending
    case stale
}

nonisolated enum GreeHVACMode: Int, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case auto = 0
    case cool = 1
    case dry = 2
    case fan = 3
    case heat = 4

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .cool: "Cool"
        case .dry: "Dry"
        case .fan: "Fan"
        case .heat: "Heat"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "sparkles"
        case .cool: "snowflake"
        case .dry: "humidity"
        case .fan: "wind"
        case .heat: "flame.fill"
        }
    }
}

nonisolated enum GreeFanSpeed: Int, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case auto = 0
    case low = 1
    case mediumLow = 2
    case medium = 3
    case mediumHigh = 4
    case high = 5

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        case .mediumLow: "Medium-Low"
        case .medium: "Medium"
        case .mediumHigh: "Medium-High"
        case .high: "High"
        }
    }

    var symbol: String { "wind" }
}

nonisolated enum GreeSwingPosition: Int, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case defaultPosition = 0
    case full = 1
    case position1 = 2
    case position2 = 3
    case position3 = 4
    case position4 = 5
    case position5 = 6

    var id: Self { self }

    var title: String {
        switch self {
        case .defaultPosition: "Default"
        case .full: "Full Swing"
        case .position1: "Position 1"
        case .position2: "Position 2"
        case .position3: "Position 3"
        case .position4: "Position 4"
        case .position5: "Position 5"
        }
    }
}

nonisolated struct GreeClimateState: Codable, Sendable, Equatable {
    var power: Bool
    var currentTemperature: Double?
    var targetTemperature: Double
    var hvacMode: GreeHVACMode
    var fanMode: GreeFanSpeed
    var verticalSwing: GreeSwingPosition
    var horizontalSwing: GreeSwingPosition
    var availability: GreeClimateAvailability
    var confidence: GreeStateConfidence
    var lastUpdated: Date

    static let unknown = GreeClimateState(
        power: false,
        currentTemperature: nil,
        targetTemperature: 24,
        hvacMode: .cool,
        fanMode: .auto,
        verticalSwing: .defaultPosition,
        horizontalSwing: .defaultPosition,
        availability: .unknown,
        confidence: .stale,
        lastUpdated: .distantPast
    )
}

nonisolated enum GreeClimateCommand: Sendable, Equatable {
    case setPower(Bool)
    case setTargetTemperature(Double)
    case setMode(GreeHVACMode)
    case setFanMode(GreeFanSpeed)
    case setSwing(vertical: GreeSwingPosition?, horizontal: GreeSwingPosition?)

    var title: String {
        switch self {
        case .setPower(let isOn): isOn ? "Turn on" : "Turn off"
        case .setTargetTemperature: "Change target temperature"
        case .setMode: "Change mode"
        case .setFanMode: "Change fan speed"
        case .setSwing: "Change swing"
        }
    }
}

nonisolated struct GreeClimateCommandExecution: Identifiable, Sendable {
    let id: UUID
    let command: GreeClimateCommand
    var status: CommandStatus
    var message: String

    init(
        id: UUID = UUID(),
        command: GreeClimateCommand,
        status: CommandStatus,
        message: String
    ) {
        self.id = id
        self.command = command
        self.status = status
        self.message = message
    }
}

nonisolated enum GreeConnectionStatus: Sendable, Equatable {
    case notConfigured
    case authenticating
    case connected(deviceCount: Int)
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .authenticating: "Signing in…"
        case .connected(let count): "Connected · \(count) device\(count == 1 ? "" : "s")"
        case .failed: "Unavailable"
        }
    }
}

nonisolated struct GreeDevice: Identifiable, Codable, Sendable, Equatable {
    let mac: String
    let name: String
    let key: String

    var id: String { mac }
}

nonisolated enum GreeClimateError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case loginFailed(String)
    case noDevicesFound
    case notConnected
    case commandTimedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter your Gree+ account email and password."
        case .loginFailed(let message): message
        case .noDevicesFound: "No Gree air conditioners were found on this account."
        case .notConnected: "Not connected to the Gree cloud service."
        case .commandTimedOut: "The command was sent but the Gree cloud service did not confirm it."
        case .invalidResponse: "Gree's cloud service returned an unexpected response."
        }
    }
}
