import Foundation

nonisolated struct SpotifyTokenSet: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-30) }
}

nonisolated enum SpotifyConnectionStatus: Equatable, Sendable {
    case notConnected
    case connecting
    case connected(displayName: String?)
    case failed(String)

    var title: String {
        switch self {
        case .notConnected: "Not Connected"
        case .connecting: "Connecting…"
        case .connected(let name): name ?? "Connected"
        case .failed: "Failed"
        }
    }
}

nonisolated struct SpotifyTrack: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var durationMS: Int
}

nonisolated struct SpotifyPlaybackState: Sendable, Equatable {
    var track: SpotifyTrack?
    var isPlaying = false
    var progressMS = 0
}

nonisolated struct SpotifyPlaylist: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
}

nonisolated enum SpotifyClientError: LocalizedError {
    case transport
    case unauthorized
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .transport: "Could not reach Spotify."
        case .unauthorized: "Spotify session expired. Reconnect your account."
        case .http(let code, let message): "Spotify error \(code): \(message)"
        }
    }
}
