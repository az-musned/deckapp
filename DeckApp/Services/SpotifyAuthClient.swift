import AuthenticationServices
import CryptoKit
import Foundation

nonisolated struct SpotifyAuthConfiguration: Sendable {
    let clientID: String
    let redirectURI: String

    static let redirectURI = "deckapp://spotify-callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-modify-private playlist-modify-public"
}

nonisolated enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case userCancelled
    case invalidCallback
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Spotify app's Client ID first."
        case .userCancelled: "Sign-in was cancelled."
        case .invalidCallback: "Spotify did not return a valid authorization response."
        case .tokenExchangeFailed(let message): message
        }
    }
}

@MainActor
final class SpotifyAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let session: URLSession
    private var activeSession: ASWebAuthenticationSession?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            self.session = URLSession(configuration: configuration)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    func authorize(configuration: SpotifyAuthConfiguration) async throws -> SpotifyTokenSet {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw SpotifyAuthError.missingClientID }
        guard let redirectScheme = URL(string: configuration.redirectURI)?.scheme else {
            throw SpotifyAuthError.invalidCallback
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: SpotifyAuthConfiguration.scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizeURL = components.url else { throw SpotifyAuthError.invalidCallback }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let authSession = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: redirectScheme) { [weak self] url, error in
                self?.activeSession = nil
                if let url {
                    continuation.resume(returning: url)
                } else if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                    continuation.resume(throwing: SpotifyAuthError.userCancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyAuthError.invalidCallback)
                }
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            activeSession = authSession
            if !authSession.start() {
                activeSession = nil
                continuation.resume(throwing: SpotifyAuthError.invalidCallback)
            }
        }

        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw SpotifyAuthError.invalidCallback
        }

        return try await exchange(code: code, verifier: verifier, clientID: clientID, redirectURI: configuration.redirectURI)
    }

    func refresh(tokens: SpotifyTokenSet, clientID: String) async throws -> SpotifyTokenSet {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeTokenResponse(data, fallbackRefreshToken: tokens.refreshToken)
    }

    private func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws -> SpotifyTokenSet {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeTokenResponse(data, fallbackRefreshToken: nil)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private static func decodeTokenResponse(_ data: Data, fallbackRefreshToken: String?) throws -> SpotifyTokenSet {
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = decoded.refresh_token ?? fallbackRefreshToken else {
            throw SpotifyAuthError.tokenExchangeFailed("Spotify did not return a refresh token.")
        }
        return SpotifyTokenSet(
            accessToken: decoded.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Token request failed."
            throw SpotifyAuthError.tokenExchangeFailed(message)
        }
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        params.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
