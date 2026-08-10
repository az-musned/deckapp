import Foundation

protocol SpotifyServing: Sendable {
    func fetchDisplayName(accessToken: String) async throws -> String?
    func fetchPlaybackState(accessToken: String) async throws -> SpotifyPlaybackState?
    func setPlaying(_ playing: Bool, accessToken: String) async throws
    func skip(forward: Bool, accessToken: String) async throws
    func isTrackSaved(_ trackID: String, accessToken: String) async throws -> Bool
    func setTrackSaved(_ saved: Bool, trackID: String, accessToken: String) async throws
    func fetchPlaylists(accessToken: String) async throws -> [SpotifyPlaylist]
    func playlistsContaining(trackID: String, playlists: [SpotifyPlaylist], accessToken: String) async throws -> Set<String>
    func setPlaylistMembership(_ contains: Bool, playlistID: String, trackID: String, accessToken: String) async throws
}

actor SpotifyClient: SpotifyServing {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.spotify.com/v1")!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchDisplayName(accessToken: String) async throws -> String? {
        struct Profile: Decodable { let display_name: String? }
        let profile: Profile = try await get("me", accessToken: accessToken)
        return profile.display_name
    }

    func fetchPlaybackState(accessToken: String) async throws -> SpotifyPlaybackState? {
        var request = authorizedRequest(path: "me/player", accessToken: accessToken)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        let http = try validated(response)
        if http.statusCode == 204 || data.isEmpty { return nil }
        try checkStatus(http, data: data)

        struct Item: Decodable {
            let id: String
            let name: String
            let duration_ms: Int
            let artists: [Artist]
            let album: Album
            struct Artist: Decodable { let name: String }
            struct Album: Decodable {
                let name: String
                let images: [Image]
                struct Image: Decodable { let url: String }
            }
        }
        struct Envelope: Decodable {
            let item: Item?
            let is_playing: Bool
            let progress_ms: Int?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let item = envelope.item else {
            return SpotifyPlaybackState(track: nil, isPlaying: envelope.is_playing, progressMS: envelope.progress_ms ?? 0)
        }
        let track = SpotifyTrack(
            id: item.id,
            title: item.name,
            artist: item.artists.map(\.name).joined(separator: ", "),
            album: item.album.name,
            artworkURL: item.album.images.first.flatMap { URL(string: $0.url) },
            durationMS: item.duration_ms
        )
        return SpotifyPlaybackState(track: track, isPlaying: envelope.is_playing, progressMS: envelope.progress_ms ?? 0)
    }

    func setPlaying(_ playing: Bool, accessToken: String) async throws {
        var request = authorizedRequest(path: "me/player/\(playing ? "play" : "pause")", accessToken: accessToken)
        request.httpMethod = "PUT"
        try await sendIgnoringNoActiveDevice(request)
    }

    func skip(forward: Bool, accessToken: String) async throws {
        var request = authorizedRequest(path: "me/player/\(forward ? "next" : "previous")", accessToken: accessToken)
        request.httpMethod = "POST"
        try await sendIgnoringNoActiveDevice(request)
    }

    func isTrackSaved(_ trackID: String, accessToken: String) async throws -> Bool {
        var request = authorizedRequest(path: "me/tracks/contains", query: [URLQueryItem(name: "ids", value: trackID)], accessToken: accessToken)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try checkStatus(try validated(response), data: data)
        return (try? JSONDecoder().decode([Bool].self, from: data))?.first ?? false
    }

    func setTrackSaved(_ saved: Bool, trackID: String, accessToken: String) async throws {
        var request = authorizedRequest(path: "me/tracks", query: [URLQueryItem(name: "ids", value: trackID)], accessToken: accessToken)
        request.httpMethod = saved ? "PUT" : "DELETE"
        let (data, response) = try await session.data(for: request)
        try checkStatus(try validated(response), data: data)
    }

    func fetchPlaylists(accessToken: String) async throws -> [SpotifyPlaylist] {
        struct Envelope: Decodable {
            struct Item: Decodable { let id: String; let name: String }
            let items: [Item]
        }
        let envelope: Envelope = try await get("me/playlists", query: [URLQueryItem(name: "limit", value: "50")], accessToken: accessToken)
        return envelope.items.map { SpotifyPlaylist(id: $0.id, name: $0.name) }
    }

    func playlistsContaining(trackID: String, playlists: [SpotifyPlaylist], accessToken: String) async throws -> Set<String> {
        var result = Set<String>()
        for playlist in playlists {
            struct Envelope: Decodable {
                struct Item: Decodable { struct Track: Decodable { let id: String? }; let track: Track? }
                let items: [Item]
            }
            let envelope: Envelope = try await get(
                "playlists/\(playlist.id)/tracks",
                query: [URLQueryItem(name: "fields", value: "items(track(id))"), URLQueryItem(name: "limit", value: "100")],
                accessToken: accessToken
            )
            if envelope.items.contains(where: { $0.track?.id == trackID }) {
                result.insert(playlist.id)
            }
        }
        return result
    }

    func setPlaylistMembership(_ contains: Bool, playlistID: String, trackID: String, accessToken: String) async throws {
        var request = authorizedRequest(path: "playlists/\(playlistID)/tracks", accessToken: accessToken)
        request.httpMethod = contains ? "POST" : "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let uri = "spotify:track:\(trackID)"
        let body: [String: Any] = contains ? ["uris": [uri]] : ["tracks": [["uri": uri]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try checkStatus(try validated(response), data: data)
    }

    // MARK: - Helpers

    private func authorizedRequest(path: String, query: [URLQueryItem] = [], accessToken: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], accessToken: String) async throws -> T {
        var request = authorizedRequest(path: path, query: query, accessToken: accessToken)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try checkStatus(try validated(response), data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendIgnoringNoActiveDevice(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        let http = try validated(response)
        // 404 with reason NO_ACTIVE_DEVICE means nothing is currently playing on any Spotify device.
        if http.statusCode == 404 { return }
        try checkStatus(http, data: data)
    }

    private func validated(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw SpotifyClientError.transport }
        return http
    }

    private func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw SpotifyClientError.unauthorized }
        let message = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw SpotifyClientError.http(http.statusCode, message)
    }
}
