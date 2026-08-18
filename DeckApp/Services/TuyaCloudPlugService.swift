import Foundation
import CryptoKit

protocol TuyaCloudPlugServing: Sendable {
    func turnOn(deviceID: String, accessID: String, accessSecret: String, dataCenter: TuyaDataCenter) async throws
}

enum TuyaCloudError: LocalizedError, Equatable {
    case missingCredentials
    case invalidResponse
    case apiError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter your Tuya Access ID, Access Secret, and Device ID in Settings."
        case .invalidResponse: "Tuya's cloud API returned an unexpected response."
        case .apiError(let code, let message): "Tuya error \(code): \(message)"
        }
    }
}

/// Turns on a Tuya/SmartLife smart plug directly via Tuya's own cloud API -- the same account
/// SmartLife itself talks to. Unlike the Home Assistant "PC Power" plug path in
/// AppState.wakePCAndWait, this works even when nothing at home is reachable, including the PC
/// that hosts Home Assistant -- Tuya's cloud is independent of the home network entirely.
/// Replaces the Apple Shortcut -> Shortcuts app -> SmartLife detour previously used for exactly
/// that reason, without the app-switch that detour required.
///
/// Signing implements Tuya's current (2024+) request-signing scheme: see
/// https://developer.tuya.com/en/docs/iot/new-singnature -- the older client_id+t+secret-only
/// scheme documented in Tuya's "archived" docs no longer works against current endpoints.
actor TuyaCloudPlugService: TuyaCloudPlugServing {
    // Cached in memory only, keyed by data center -- re-authenticates on demand instead of
    // implementing the refresh_token flow, since this is a low-frequency, fire-and-forget
    // action (turning on one plug occasionally), not a continuously polling integration like
    // GreeClimateController's session.
    private var cachedToken: (value: String, dataCenter: TuyaDataCenter, expiresAt: Date)?

    func turnOn(deviceID: String, accessID: String, accessSecret: String, dataCenter: TuyaDataCenter) async throws {
        let trimmedID = accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = accessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDevice = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty, !trimmedDevice.isEmpty else {
            throw TuyaCloudError.missingCredentials
        }

        let token = try await accessToken(accessID: trimmedID, accessSecret: trimmedSecret, dataCenter: dataCenter)
        let body = try JSONEncoder().encode(CommandBody(commands: [Command(code: "switch_1", value: true)]))
        _ = try await send(
            method: "POST",
            path: "/v1.0/iot-03/devices/\(trimmedDevice)/commands",
            body: body,
            accessID: trimmedID, accessSecret: trimmedSecret, accessToken: token, dataCenter: dataCenter
        )
    }

    private func accessToken(accessID: String, accessSecret: String, dataCenter: TuyaDataCenter) async throws -> String {
        if let cachedToken, cachedToken.dataCenter == dataCenter, cachedToken.expiresAt > .now {
            return cachedToken.value
        }
        let data = try await send(
            method: "GET",
            path: "/v1.0/token?grant_type=1",
            body: nil,
            accessID: accessID, accessSecret: accessSecret, accessToken: nil, dataCenter: dataCenter
        )
        guard let result = try JSONDecoder().decode(TokenResponse.self, from: data).result else {
            throw TuyaCloudError.invalidResponse
        }
        // Back off 60s from the reported expiry so a near-expiry token is never handed out.
        cachedToken = (result.access_token, dataCenter, Date().addingTimeInterval(TimeInterval(max(0, result.expire_time - 60))))
        return result.access_token
    }

    /// Sends one signed request and validates Tuya's `{success, code, msg}` envelope --
    /// signature/auth failures come back as HTTP 200 with `success: false`, not a non-2xx
    /// status, so checking the HTTP code alone isn't enough to catch them.
    private func send(
        method: String,
        path: String,
        body: Data?,
        accessID: String,
        accessSecret: String,
        accessToken: String?,
        dataCenter: TuyaDataCenter
    ) async throws -> Data {
        guard let url = URL(string: dataCenter.host + path) else { throw TuyaCloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let bodyHash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        // "Optional_Signature_key" is the empty string here since no custom Signature-Headers
        // are sent -- the blank line between bodyHash and path is that empty field.
        let stringToSign = "\(method)\n\(bodyHash)\n\n\(path)"
        let signBase = accessID + (accessToken ?? "") + timestamp + stringToSign
        let key = SymmetricKey(data: Data(accessSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signBase.utf8), using: key)
        let sign = signature.map { String(format: "%02X", $0) }.joined()

        request.setValue(accessID, forHTTPHeaderField: "client_id")
        request.setValue(timestamp, forHTTPHeaderField: "t")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if let accessToken { request.setValue(accessToken, forHTTPHeaderField: "access_token") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TuyaCloudError.invalidResponse
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        if let envelope, !envelope.success {
            throw TuyaCloudError.apiError(code: envelope.code ?? http.statusCode, message: envelope.msg ?? "Request failed.")
        }
        return data
    }

    private struct Envelope: Decodable {
        let success: Bool
        let code: Int?
        let msg: String?
    }

    private struct CommandBody: Encodable {
        let commands: [Command]
    }

    private struct Command: Encodable {
        let code: String
        let value: Bool
    }

    private struct TokenResponse: Decodable {
        let result: TokenResult?
    }

    private struct TokenResult: Decodable {
        let access_token: String
        let expire_time: Int
    }
}
