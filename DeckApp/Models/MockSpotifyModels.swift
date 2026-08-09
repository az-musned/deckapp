import Foundation

struct MockSpotifyTrack: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artworkSymbol: String
    var durationSeconds: Double
}

struct MockSpotifyPlaylist: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var trackIDs: [String] = []
}

struct MockSpotifyState: Codable, Sendable, Equatable {
    static let library: [MockSpotifyTrack] = [
        MockSpotifyTrack(id: "solar-sails", title: "Solar Sails", artist: "Kepler Drift", album: "Departure Vectors", artworkSymbol: "water.waves", durationSeconds: 221),
        MockSpotifyTrack(id: "night-drive", title: "Night Drive", artist: "Neon Atlas", album: "Skyline EP", artworkSymbol: "road.lanes", durationSeconds: 198),
        MockSpotifyTrack(id: "low-orbit", title: "Low Orbit", artist: "Kepler Drift", album: "Departure Vectors", artworkSymbol: "moon.stars.fill", durationSeconds: 255)
    ]

    var availability: DeviceAvailability = .available
    var isPlaying = true
    var trackIndex = 0
    var progressSeconds = 84.0
    var likedTrackIDs: Set<String> = ["solar-sails"]
    var playlists: [MockSpotifyPlaylist] = [
        MockSpotifyPlaylist(id: "late-night-coding", name: "Late Night Coding", trackIDs: ["low-orbit"]),
        MockSpotifyPlaylist(id: "workout", name: "Workout"),
        MockSpotifyPlaylist(id: "chill", name: "Chill", trackIDs: ["solar-sails"])
    ]

    var currentTrack: MockSpotifyTrack { Self.library[trackIndex] }

    func isLiked(_ trackID: String) -> Bool { likedTrackIDs.contains(trackID) }

    func playlists(containing trackID: String) -> Set<String> {
        Set(playlists.filter { $0.trackIDs.contains(trackID) }.map(\.id))
    }
}
