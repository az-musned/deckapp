import Foundation

enum CompanionNetworkRoute: String, Sendable {
    case localNetwork = "Home LAN"
    case privateVPN = "Private VPN"
}

enum CompanionConnectionStatus: Sendable, Equatable {
    case notConfigured
    case testing
    case connected(CompanionNetworkRoute)
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .testing: "Testing…"
        case .connected(let route): "Connected via \(route.rawValue)"
        case .failed: "Unavailable"
        }
    }
}

enum CompanionButtonTestStatus: Sendable, Equatable {
    case idle
    case sending
    case accepted(Int)
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            nil
        case .sending:
            "Sending button press…"
        case .accepted(let statusCode):
            "Companion accepted the request (HTTP \(statusCode)). Verify the action on the PC."
        case .failed(let message):
            message
        }
    }
}

struct CompanionButtonMapping: Sendable, Equatable, Hashable, Codable {
    var page: Int = 1
    var row: Int = 0
    var column: Int = 0

    var locationDescription: String {
        "P\(page) · R\(row) · C\(column)"
    }
}

enum CompanionDashboardAction: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case launchGame
    case sleepPC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launchGame: "Launch Game"
        case .sleepPC: "Sleep PC"
        }
    }

    var roomAction: RoomAction {
        switch self {
        case .launchGame: .launchGame
        case .sleepPC: .sleepPC
        }
    }

    var symbol: String {
        switch self {
        case .launchGame: "gamecontroller.fill"
        case .sleepPC: "powersleep"
        }
    }
}

struct CompanionEndpoint: Sendable, Equatable {
    let baseURL: URL
    let route: CompanionNetworkRoute

    init(address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompanionEndpointError.emptyAddress
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw CompanionEndpointError.invalidAddress
        }

        guard components.user == nil, components.password == nil else {
            throw CompanionEndpointError.embeddedCredentials
        }

        let classification = Self.classify(host: host)
        guard classification.isAllowed else {
            throw CompanionEndpointError.publicAddressNotAllowed
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        if components.port == nil, scheme == "http" {
            components.port = 8000
        }

        guard let url = components.url else {
            throw CompanionEndpointError.invalidAddress
        }

        baseURL = url
        route = classification.route
    }

    private static func classify(host: String) -> (isAllowed: Bool, route: CompanionNetworkRoute) {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return (true, .localNetwork)
        }

        if host.hasSuffix(".ts.net") {
            return (true, .privateVPN)
        }

        if host.contains(":") {
            let isLoopback = host == "::1"
            let isUniqueLocal = host.hasPrefix("fc") || host.hasPrefix("fd")
            let isLinkLocal = (0x8...0xb).contains(Int(String(host.dropFirst(2).first ?? "0"), radix: 16) ?? -1) && host.hasPrefix("fe")
            return (isLoopback || isUniqueLocal || isLinkLocal, .localNetwork)
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return (false, .localNetwork)
        }

        if octets[0] == 100, (64...127).contains(octets[1]) {
            return (true, .privateVPN)
        }

        let isPrivate = octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || octets[0] == 127

        return (isPrivate, .localNetwork)
    }
}

enum CompanionEndpointError: LocalizedError, Equatable {
    case emptyAddress
    case invalidAddress
    case embeddedCredentials
    case publicAddressNotAllowed

    var errorDescription: String? {
        switch self {
        case .emptyAddress:
            "Enter the Companion PC address."
        case .invalidAddress:
            "Enter a valid HTTP or HTTPS Companion address."
        case .embeddedCredentials:
            "Do not put credentials in the Companion URL."
        case .publicAddressNotAllowed:
            "Only home-LAN, .local, Tailscale, or private-VPN addresses are allowed."
        }
    }
}

struct CompanionButtonLocation: Sendable, Equatable {
    let page: Int
    let row: Int
    let column: Int

    init(page: Int, row: Int, column: Int) throws {
        guard page > 0, row >= 0, column >= 0 else {
            throw CompanionButtonLocationError.invalidLocation
        }
        self.page = page
        self.row = row
        self.column = column
    }
}

enum CompanionButtonLocationError: LocalizedError {
    case invalidLocation

    var errorDescription: String? {
        "Companion locations require page 1 or greater and non-negative rows and columns."
    }
}

struct CompanionRequestReceipt: Sendable {
    let accepted: Bool
    let statusCode: Int
}
