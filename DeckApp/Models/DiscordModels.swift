import Foundation

/// Mirrors `DiscordBridgeState` on the Windows Agent exactly (raw values are the C# enum's `.ToString()` output).
nonisolated enum DiscordBridgeState: String, Codable, Sendable {
    case notConfigured = "NotConfigured"
    case disconnected = "Disconnected"
    case connectingToClient = "ConnectingToClient"
    case awaitingAuthorization = "AwaitingAuthorization"
    case authenticating = "Authenticating"
    case ready = "Ready"

    var title: String {
        switch self {
        case .notConfigured: "Not Configured"
        case .disconnected: "Disconnected"
        case .connectingToClient: "Connecting to Discord…"
        case .awaitingAuthorization: "Approve on PC…"
        case .authenticating: "Signing in…"
        case .ready: "Connected"
        }
    }
}

nonisolated struct DiscordVoiceParticipant: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let username: String
    let mute: Bool
    let deaf: Bool
    let selfMute: Bool
    let selfDeaf: Bool
}

nonisolated struct DiscordVoiceChannelState: Codable, Sendable, Equatable {
    let channelId: String?
    let channelName: String?
    let guildId: String?
    let selfMute: Bool
    let selfDeaf: Bool
    let participants: [DiscordVoiceParticipant]

    static let notConnected = DiscordVoiceChannelState(
        channelId: nil, channelName: nil, guildId: nil, selfMute: false, selfDeaf: false, participants: []
    )

    var isConnected: Bool { channelId != nil }
}

nonisolated struct DiscordGuildSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
}

nonisolated struct DiscordChannelSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
}

nonisolated struct DiscordBridgeConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}

nonisolated struct DiscordStatusMessage: Decodable, Sendable {
    let bridgeState: DiscordBridgeState
    let voice: DiscordVoiceChannelState
    let error: String?
}

nonisolated struct DiscordGuildListMessage: Decodable, Sendable {
    let guilds: [DiscordGuildSummary]
}

nonisolated struct DiscordChannelListMessage: Decodable, Sendable {
    let guildId: String
    let channels: [DiscordChannelSummary]
}

nonisolated enum DiscordCommand: Sendable {
    case mute(Bool)
    case deafen(Bool)
    case join(channelId: String)
    case leave
    case listGuilds
    case listChannels(guildId: String)

    var body: DiscordCommandBody {
        switch self {
        case .mute(let value): DiscordCommandBody(command: "mute", value: value, channelId: nil, guildId: nil)
        case .deafen(let value): DiscordCommandBody(command: "deafen", value: value, channelId: nil, guildId: nil)
        case .join(let channelId): DiscordCommandBody(command: "join", value: nil, channelId: channelId, guildId: nil)
        case .leave: DiscordCommandBody(command: "leave", value: nil, channelId: nil, guildId: nil)
        case .listGuilds: DiscordCommandBody(command: "listGuilds", value: nil, channelId: nil, guildId: nil)
        case .listChannels(let guildId): DiscordCommandBody(command: "listChannels", value: nil, channelId: nil, guildId: guildId)
        }
    }
}

nonisolated struct DiscordCommandBody: Encodable, Sendable {
    let command: String
    let value: Bool?
    let channelId: String?
    let guildId: String?
}
