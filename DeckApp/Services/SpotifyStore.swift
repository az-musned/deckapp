import Foundation
import Observation

@MainActor
@Observable
final class SpotifyStore {
    private(set) var connectionStatus: SpotifyConnectionStatus = .notConnected
    private(set) var playback = SpotifyPlaybackState()
    private(set) var isLikedCurrentTrack = false
    private(set) var playlists: [SpotifyPlaylist] = []
    private(set) var playlistMembership: Set<String> = []
    var clientID: String {
        didSet { defaults.set(clientID, forKey: clientIDKey) }
    }

    @ObservationIgnored private let authClient: SpotifyAuthClient
    @ObservationIgnored private let webClient: any SpotifyServing
    @ObservationIgnored private let keychain: KeychainSecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clientIDKey = "spotify.clientID"
    @ObservationIgnored private let tokenAccount = "tokens"
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackID: String?

    var isConnected: Bool { if case .connected = connectionStatus { return true } else { return false } }

    init(
        authClient: SpotifyAuthClient = SpotifyAuthClient(),
        webClient: any SpotifyServing = SpotifyClient(),
        keychain: KeychainSecretStore = KeychainSecretStore(service: "com.example.DeckApp.spotify"),
        defaults: UserDefaults = .standard
    ) {
        self.authClient = authClient
        self.webClient = webClient
        self.keychain = keychain
        self.defaults = defaults
        clientID = defaults.string(forKey: clientIDKey) ?? ""
        if loadTokens() != nil {
            connectionStatus = .connecting
            Task { await self.confirmExistingSession() }
        }
    }

    func connect() async {
        connectionStatus = .connecting
        do {
            let tokens = try await authClient.authorize(configuration: SpotifyAuthConfiguration(clientID: clientID, redirectURI: SpotifyAuthConfiguration.redirectURI))
            try saveTokens(tokens)
            let name = try? await webClient.fetchDisplayName(accessToken: tokens.accessToken)
            connectionStatus = .connected(displayName: name)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        try? keychain.delete(account: tokenAccount)
        connectionStatus = .notConnected
        playback = SpotifyPlaybackState()
        playlists = []
        playlistMembership = []
        pollTask?.cancel()
        pollTask = nil
    }

    func startWatching() async {
        consumers += 1
        guard consumers == 1, isConnected else { return }
        beginPolling()
    }

    func stopWatching() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func togglePlayback() async {
        guard let token = await validAccessToken() else { return }
        try? await webClient.setPlaying(!playback.isPlaying, accessToken: token)
        await refreshPlayback()
    }

    func skip(forward: Bool) async {
        guard let token = await validAccessToken() else { return }
        try? await webClient.skip(forward: forward, accessToken: token)
        try? await Task.sleep(for: .milliseconds(400))
        await refreshPlayback()
    }

    func toggleLike() async {
        guard let token = await validAccessToken(), let trackID = playback.track?.id else { return }
        let newValue = !isLikedCurrentTrack
        isLikedCurrentTrack = newValue
        do {
            try await webClient.setTrackSaved(newValue, trackID: trackID, accessToken: token)
        } catch {
            isLikedCurrentTrack = !newValue
        }
    }

    func togglePlaylistMembership(playlistID: String) async {
        guard let token = await validAccessToken(), let trackID = playback.track?.id else { return }
        let contains = playlistMembership.contains(playlistID)
        if contains {
            playlistMembership.remove(playlistID)
        } else {
            playlistMembership.insert(playlistID)
        }
        do {
            try await webClient.setPlaylistMembership(!contains, playlistID: playlistID, trackID: trackID, accessToken: token)
        } catch {
            if contains { playlistMembership.insert(playlistID) } else { playlistMembership.remove(playlistID) }
        }
    }

    func loadPlaylistsIfNeeded() async {
        guard playlists.isEmpty, let token = await validAccessToken() else { return }
        playlists = (try? await webClient.fetchPlaylists(accessToken: token)) ?? []
        await refreshPlaylistMembership()
    }

    // MARK: - Private

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshPlayback()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshPlayback() async {
        guard let token = await validAccessToken() else { return }
        guard let state = try? await webClient.fetchPlaybackState(accessToken: token) else { return }
        playback = state
        if state.track?.id != lastTrackID {
            lastTrackID = state.track?.id
            isLikedCurrentTrack = false
            playlistMembership = []
            if let trackID = state.track?.id {
                isLikedCurrentTrack = (try? await webClient.isTrackSaved(trackID, accessToken: token)) ?? false
                await refreshPlaylistMembership()
            }
        }
    }

    private func refreshPlaylistMembership() async {
        guard let token = await validAccessToken(), let trackID = playback.track?.id, !playlists.isEmpty else { return }
        playlistMembership = (try? await webClient.playlistsContaining(trackID: trackID, playlists: playlists, accessToken: token)) ?? []
    }

    private func confirmExistingSession() async {
        guard let token = await validAccessToken() else {
            connectionStatus = .notConnected
            return
        }
        let name = try? await webClient.fetchDisplayName(accessToken: token)
        connectionStatus = .connected(displayName: name)
        if consumers > 0 { beginPolling() }
    }

    private func validAccessToken() async -> String? {
        guard var tokens = loadTokens() else { return nil }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            tokens = try await authClient.refresh(tokens: tokens, clientID: clientID)
            try saveTokens(tokens)
            return tokens.accessToken
        } catch {
            connectionStatus = .failed("Spotify session expired. Reconnect your account.")
            return nil
        }
    }

    private func loadTokens() -> SpotifyTokenSet? {
        guard let raw = try? keychain.load(account: tokenAccount), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpotifyTokenSet.self, from: data)
    }

    private func saveTokens(_ tokens: SpotifyTokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        try keychain.save(String(data: data, encoding: .utf8)!, account: tokenAccount)
    }
}
