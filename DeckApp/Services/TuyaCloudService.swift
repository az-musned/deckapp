import Foundation
import CryptoKit

/// The Tuya IoT Platform data center your Tuya Cloud project and linked
/// SmartLife account live in. Pick whichever region you registered under.
enum TuyaDataCenter: String, Codable, CaseIterable, Sendable {
    case china
    case westAmerica
    case eastAmerica
    case centralEurope
    case westEurope
    case india

    var displayName: String {
        switch self {
        case .china: "China"
        case .westAmerica: "Western America"
        case .eastAmerica: "Eastern America"
        case .centralEurope: "Central Europe"
        case .westEurope: "Western Europe"
        case .india: "India"
        }
    }

    var baseURL: URL {
        switch self {
        case .china: URL(string: "https://openapi.tuyacn.com")!
        case .westAmerica: URL(string: "https://openapi.tuyaus.com")!
        case .eastAmerica: URL(string: "https://openapi-ueaz.tuyaus.com")!
        case .centralEurope: URL(string: "https://openapi.tuyaeu.com")!
        case .westEurope: URL(string: "https://openapi-weaz.tuyaeu.com")!
        case .india: URL(string: "https://openapi.tuyain.com")!
        }
    }
}

/// Turns a Tuya/SmartLife smart plug on directly through the Tuya Cloud (IoT
/// Platform) API, with no Home Assistant or third-party automation service in
/// between. Implements Tuya's HMAC-SHA256 request signing exactly as the
/// official tuya-connector-python SDK does it.
protocol SmartPlugTriggering: Sendable {
    func turnOn(deviceID: String, switchCode: String) async throws
}

enum TuyaCloudError: LocalizedError {
    case invalidConfiguration
    case authenticationFailed(String)
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid Tuya access ID, access secret, and device ID."
        case .authenticationFailed(let message): "Tuya sign-in failed: \(message)"
        case .commandFailed(let message): "Tuya rejected the command: \(message)"
        case .invalidResponse: "Tuya returned an unexpected response."
        }
    }
}

actor TuyaCloudService: SmartPlugTriggering {
    private struct TokenEnvelope: Decodable {
        struct Result: Decodable {
            let access_token: String
            let expire_time: Int?
            let expire: Int?
        }
        let success: Bool
        let msg: String?
        let result: Result?
    }

    private struct CommandEnvelope: Decodable {
        let success: Bool
        let msg: String?
    }

    private let accessID: String
    private let accessSecret: String
    private let baseURL: URL
    private let session: URLSession
    private var cachedToken: (value: String, expiresAt: Date)?

    init(accessID: String, accessSecret: String, dataCenter: TuyaDataCenter, session: URLSession = .shared) {
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.baseURL = dataCenter.baseURL
        self.session = session
    }

    func turnOn(deviceID: String, switchCode: String) async throws {
        guard !accessID.isEmpty, !accessSecret.isEmpty, !deviceID.isEmpty else {
            throw TuyaCloudError.invalidConfiguration
        }
        let token = try await validToken()
        let body = try JSONEncoder().encode(CommandBody(commands: [Command(code: switchCode, value: true)]))
        let envelope: CommandEnvelope = try await send(
            method: "POST",
            path: "/v1.0/devices/\(deviceID)/commands",
            query: nil,
            body: body,
            accessToken: token
        )
        guard envelope.success else { throw TuyaCloudError.commandFailed(envelope.msg ?? "Unknown error") }
    }

    private struct Command: Encodable { let code: String; let value: Bool }
    private struct CommandBody: Encodable { let commands: [Command] }

    private func validToken() async throws -> String {
        if let cachedToken, cachedToken.expiresAt > Date().addingTimeInterval(60) {
            return cachedToken.value
        }
        let envelope: TokenEnvelope = try await send(
            method: "GET",
            path: "/v1.0/token",
            query: ["grant_type": "1"],
            body: nil,
            accessToken: nil
        )
        guard envelope.success, let result = envelope.result, !result.access_token.isEmpty else {
            throw TuyaCloudError.authenticationFailed(envelope.msg ?? "No access token returned")
        }
        let expiresInSeconds = result.expire ?? result.expire_time ?? 0
        let token = result.access_token
        cachedToken = (token, Date().addingTimeInterval(TimeInterval(expiresInSeconds)))
        return token
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        query: [String: String]?,
        body: Data?,
        accessToken: String?
    ) async throws -> Response {
        let (sign, timestamp) = self.sign(method: method, path: path, query: query, body: body, accessToken: accessToken)

        var urlString = baseURL.absoluteString + path
        if let query, !query.isEmpty {
            let canonical = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
            urlString += "?" + canonical
        }
        guard let url = URL(string: urlString) else { throw TuyaCloudError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessID, forHTTPHeaderField: "client_id")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        request.setValue(accessToken ?? "", forHTTPHeaderField: "access_token")
        request.setValue(String(timestamp), forHTTPHeaderField: "t")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TuyaCloudError.invalidResponse
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw TuyaCloudError.invalidResponse }
    }

    /// https://developer.tuya.com/en/docs/iot/new-singnature — mirrors the official SDKs'
    /// string-to-sign construction exactly (method, content-sha256, headers, url), then
    /// HMAC-SHA256(accessID + [accessToken] + timestamp + stringToSign, accessSecret).
    private func sign(
        method: String,
        path: String,
        query: [String: String]?,
        body: Data?,
        accessToken: String?
    ) -> (sign: String, timestamp: Int64) {
        var stringToSign = method + "\n"
        stringToSign += SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined() + "\n"
        stringToSign += "\n"
        stringToSign += path
        if let query, !query.isEmpty {
            let canonical = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
            stringToSign += "?" + canonical
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var message = accessID
        if let accessToken { message += accessToken }
        message += String(timestamp) + stringToSign

        let key = SymmetricKey(data: Data(accessSecret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let sign = hmac.map { String(format: "%02X", $0) }.joined()
        return (sign, timestamp)
    }
}
