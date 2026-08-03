import Foundation

protocol HomeAssistantServiceProtocol: Sendable {
    func testConnection(baseURL: URL, token: String) async throws -> Int
    func fetchStates(baseURL: URL, token: String) async throws -> [HAEntityState]
    func callService(_ call: HAServiceCall, baseURL: URL, token: String) async throws
}

struct HomeAssistantClient: HomeAssistantServiceProtocol {
    let session: URLSession = .shared

    func testConnection(baseURL: URL, token: String) async throws -> Int {
        let start = ContinuousClock.now
        let request = try request(baseURL: baseURL, path: "api/", token: token)
        let (_, response) = try await session.data(for: request)
        try validate(response)
        return Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
    }

    func fetchStates(baseURL: URL, token: String) async throws -> [HAEntityState] {
        let (data, response) = try await session.data(for: request(baseURL: baseURL, path: "api/states", token: token))
        try validate(response)
        return try JSONDecoder().decode([HAEntityState].self, from: data)
    }

    func callService(_ call: HAServiceCall, baseURL: URL, token: String) async throws {
        var request = try request(baseURL: baseURL, path: "api/services/\(call.domain)/\(call.service)", token: token)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(call.data)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func request(baseURL: URL, path: String, token: String) throws -> URLRequest {
        guard !token.isEmpty else { throw HAClientError.missingToken }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw HAClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HAClientError.http(http.statusCode) }
    }
}

enum HAClientError: LocalizedError { case missingToken, invalidResponse, http(Int) }
