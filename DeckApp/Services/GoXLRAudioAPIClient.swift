import Foundation

protocol GoXLRAudioAPIServing: Sendable {
    func endpoints(addresses: [String], credential: String) async throws -> [WindowsAudioEndpoint]
    func channels(addresses: [String], credential: String) async throws -> [GoXLRAudioChannelMapping]
    func updateMapping(channelID: String, endpointID: String?, addresses: [String], credential: String) async throws
}

actor GoXLRAudioAPIClient: GoXLRAudioAPIServing {
    private struct EndpointEnvelope: Decodable { let endpoints: [WindowsAudioEndpoint] }
    private struct ChannelEnvelope: Decodable { let channels: [GoXLRAudioChannelMapping] }
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func endpoints(addresses: [String], credential: String) async throws -> [WindowsAudioEndpoint] {
        let data = try await request(method: "GET", path: "/api/v1/audio/endpoints", body: nil, addresses: addresses, credential: credential)
        if let direct = try? JSONDecoder().decode([WindowsAudioEndpoint].self, from: data) { return direct }
        return try JSONDecoder().decode(EndpointEnvelope.self, from: data).endpoints
    }

    func channels(addresses: [String], credential: String) async throws -> [GoXLRAudioChannelMapping] {
        let data = try await request(method: "GET", path: "/api/v1/audio/channels", body: nil, addresses: addresses, credential: credential)
        if let direct = try? JSONDecoder().decode([GoXLRAudioChannelMapping].self, from: data) { return direct }
        return try JSONDecoder().decode(ChannelEnvelope.self, from: data).channels
    }

    func updateMapping(channelID: String, endpointID: String?, addresses: [String], credential: String) async throws {
        _ = try await request(
            method: "PUT",
            path: "/api/v1/audio/channels/\(channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelID)/mapping",
            body: try Self.mappingRequestBody(endpointID: endpointID),
            addresses: addresses,
            credential: credential
        )
    }

    nonisolated static func mappingRequestBody(endpointID: String?) throws -> Data {
        try JSONEncoder().encode(AudioChannelMappingRequest(endpointId: endpointID))
    }

    private func request(method: String, path: String, body: Data?, addresses: [String], credential: String) async throws -> Data {
        var lastError: Error = WindowsRemoteInputError.disconnected
        for address in addresses {
            do {
                var request = URLRequest(url: try WindowsAgentEndpoint(address).url(path: path))
                request.httpMethod = method
                request.httpBody = body
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw WindowsRemoteInputError.invalidResponse }
                switch http.statusCode {
                case 200..<300: return data
                case 401: throw WindowsRemoteInputError.unpairedClient
                case 404, 409: throw WindowsRemoteInputError.capabilityUnavailable
                default: throw WindowsRemoteInputError.invalidResponse
                }
            } catch {
                lastError = error
                if error as? WindowsRemoteInputError == .unpairedClient { throw error }
            }
        }
        throw lastError
    }
}
