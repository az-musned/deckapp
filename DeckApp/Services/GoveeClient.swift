import Foundation

protocol GoveeServing: Sendable {
    func discoverDevices(apiKey: String) async throws -> [GoveeDevice]
    func control(_ action: GoveeDeviceAction, apiKey: String) async throws
}

actor GoveeClient: GoveeServing {
    private struct DeviceEnvelope: Decodable {
        let code: Int
        let message: String
        let data: [GoveeDevice]
    }

    private struct ResponseEnvelope: Decodable {
        let code: Int
        let message: String
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://openapi.api.govee.com")!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func discoverDevices(apiKey: String) async throws -> [GoveeDevice] {
        let key = try normalized(apiKey)
        var request = URLRequest(url: baseURL.appending(path: "router/api/v1/user/devices"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let envelope = try decode(DeviceEnvelope.self, from: data)
        try validateAPI(code: envelope.code, message: envelope.message)
        return envelope.data
    }

    func control(_ action: GoveeDeviceAction, apiKey: String) async throws {
        let key = try normalized(apiKey)
        var request = URLRequest(url: baseURL.appending(path: "router/api/v1/device/control"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GoveeControlRequest(action: action))

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let envelope = try decode(ResponseEnvelope.self, from: data)
        try validateAPI(code: envelope.code, message: envelope.message)
    }

    private func normalized(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GoveeClientError.missingAPIKey }
        return normalized
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw GoveeClientError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw GoveeClientError.unauthorized
        case 429: throw GoveeClientError.rateLimited
        default: throw GoveeClientError.invalidResponse
        }
    }

    private func validateAPI(code: Int, message: String) throws {
        switch code {
        case 200: return
        case 401: throw GoveeClientError.unauthorized
        case 429: throw GoveeClientError.rateLimited
        default: throw GoveeClientError.rejected(message.isEmpty ? "Govee rejected the command." : message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GoveeClientError.invalidResponse }
    }
}
