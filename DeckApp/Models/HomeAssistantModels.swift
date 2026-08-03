import Foundation

nonisolated struct HomeAssistantConfiguration: Codable, Sendable, Equatable {
    var localURL = "http://homeassistant.local:8123"
    var remoteURL = ""
}

nonisolated struct HAEntityState: Codable, Identifiable, Sendable, Equatable {
    var id: String { entityID }
    let entityID: String
    let state: String
    let attributes: [String: HAJSONValue]
    let lastChanged: String?
    let lastUpdated: String?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id", state, attributes
        case lastChanged = "last_changed"
        case lastUpdated = "last_updated"
    }

    var domain: String { entityID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "" }
    var isAvailable: Bool { state != "unavailable" && state != "unknown" }

    func stringAttribute(_ key: String) -> String? {
        guard case .string(let value) = attributes[key] else { return nil }
        return value
    }

    func numberAttribute(_ key: String) -> Double? {
        guard case .number(let value) = attributes[key] else { return nil }
        return value
    }

    func boolAttribute(_ key: String) -> Bool? {
        guard case .bool(let value) = attributes[key] else { return nil }
        return value
    }

    func stringArrayAttribute(_ key: String) -> [String] {
        guard case .array(let values) = attributes[key] else { return [] }
        return values.compactMap { value in
            guard case .string(let string) = value else { return nil }
            return string
        }
    }
}

nonisolated enum HAJSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([HAJSONValue]), object([String: HAJSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([HAJSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: HAJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

nonisolated struct HAServiceCall: Sendable {
    let domain: String
    let service: String
    let data: [String: HAJSONValue]
}

nonisolated enum HomeAssistantConnectionState: Sendable, Equatable {
    case notConfigured, testing, connected(ConnectionRoute, latencyMilliseconds: Int), reconnecting, offline(String?)
}

nonisolated enum HAWebSocketState: String, Sendable {
    case disconnected, authenticating, subscribed, reconnecting
}

nonisolated struct WakeOnLANConfiguration: Codable, Sendable, Equatable {
    var macAddress = ""
    var broadcastAddress = ""

    var normalizedMACAddress: String? {
        let parts = macAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6,
              parts.allSatisfy({ part in
                  part.count == 2 && part.allSatisfy { $0.isHexDigit }
              }) else { return nil }
        return parts.map { $0.uppercased() }.joined(separator: ":")
    }
}
