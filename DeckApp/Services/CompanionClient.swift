import Foundation

protocol CompanionServing: Sendable {
    func testConnection(to endpoint: CompanionEndpoint) async throws
    func pressButton(at location: CompanionButtonLocation, on endpoint: CompanionEndpoint) async throws -> CompanionRequestReceipt
}

struct CompanionClient: CompanionServing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testConnection(to endpoint: CompanionEndpoint) async throws {
        var request = URLRequest(url: endpoint.baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionClientError.invalidResponse
        }
        guard (200..<500).contains(httpResponse.statusCode) else {
            throw CompanionClientError.unhealthyStatus(httpResponse.statusCode)
        }
    }

    func pressButton(
        at location: CompanionButtonLocation,
        on endpoint: CompanionEndpoint
    ) async throws -> CompanionRequestReceipt {
        let path = "api/location/\(location.page)/\(location.row)/\(location.column)/press"
        let url = endpoint.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionClientError.invalidResponse
        }

        return CompanionRequestReceipt(
            accepted: (200..<300).contains(httpResponse.statusCode),
            statusCode: httpResponse.statusCode
        )
    }
}

enum CompanionClientError: LocalizedError {
    case invalidResponse
    case unhealthyStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Companion returned an invalid response."
        case .unhealthyStatus(let code):
            "Companion responded with HTTP \(code)."
        }
    }
}
