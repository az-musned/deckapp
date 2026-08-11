import Foundation

/// Triggers an IFTTT Webhooks applet (e.g. "Smart Life: turn device on") so DeckApp
/// can flip the PC's smart plug without Home Assistant or a direct Tuya Cloud
/// integration. The plug cutting/restoring AC power is what actually boots the PC,
/// via its "Restore on AC Power Loss" BIOS setting.
protocol IFTTTWebhookServing: Sendable {
    func trigger(event: String, key: String) async throws
}

enum IFTTTWebhookError: LocalizedError {
    case invalidConfiguration
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid IFTTT event name and webhook key."
        case .requestFailed(let status): "IFTTT rejected the webhook request (status \(status))."
        }
    }
}

struct IFTTTWebhookService: IFTTTWebhookServing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func trigger(event: String, key: String) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maker.ifttt.com"
        components.path = "/trigger/\(event)/with/key/\(key)"
        guard !event.isEmpty, !key.isEmpty, let url = components.url else {
            throw IFTTTWebhookError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IFTTTWebhookError.requestFailed(status)
        }
    }
}
