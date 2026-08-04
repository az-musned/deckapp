import Foundation

nonisolated enum GoveeConnectionStatus: Sendable, Equatable {
    case notConfigured
    case discovering
    case connected(deviceCount: Int)
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .discovering: "Discovering…"
        case .connected(let count): "Connected · \(count) device\(count == 1 ? "" : "s")"
        case .failed: "Unavailable"
        }
    }
}

nonisolated enum GoveeValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([GoveeValue])
    case object([String: GoveeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([GoveeValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: GoveeValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayValue: String {
        switch self {
        case .string(let value): value
        case .number(let value):
            value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(1)))
        case .bool(let value): value ? "On" : "Off"
        case .array, .object: "Custom"
        case .null: "None"
        }
    }
}

nonisolated struct GoveeCapabilityOption: Codable, Sendable, Equatable, Hashable, Identifiable {
    let name: String
    let value: GoveeValue

    var id: String { "\(name)|\(value.displayValue)" }
}

nonisolated struct GoveeCapabilityRange: Codable, Sendable, Equatable, Hashable {
    let min: Double
    let max: Double
    let precision: Double?
}

nonisolated struct GoveeCapabilityParameters: Codable, Sendable, Equatable, Hashable {
    let dataType: String?
    let options: [GoveeCapabilityOption]?
    let range: GoveeCapabilityRange?
    let unit: String?
}

nonisolated struct GoveeCapability: Codable, Sendable, Equatable, Hashable, Identifiable {
    let type: String
    let instance: String
    let parameters: GoveeCapabilityParameters?

    var id: String { "\(type)|\(instance)" }

    var title: String {
        switch instance {
        case "powerSwitch": "Power"
        case "brightness": "Brightness"
        case "colorRgb": "RGB Color"
        case "colorTemperatureK": "Color Temperature"
        case "lightScene": "Scene"
        case "diyScene": "DIY Scene"
        default:
            instance
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    var isActionable: Bool {
        if let options = parameters?.options, !options.isEmpty {
            return options.allSatisfy { option in
                switch option.value {
                case .string, .number, .bool: true
                default: false
                }
            }
        }
        return parameters?.range != nil
    }

    var defaultValue: GoveeValue? {
        if let first = parameters?.options?.first { return first.value }
        if let range = parameters?.range { return .number(range.min) }
        return nil
    }
}

nonisolated struct GoveeDevice: Codable, Sendable, Equatable, Hashable, Identifiable {
    let sku: String
    let device: String
    let deviceName: String
    let type: String?
    let capabilities: [GoveeCapability]

    var id: String { "\(sku)|\(device)" }
    var actionableCapabilities: [GoveeCapability] { capabilities.filter(\.isActionable) }

    private enum CodingKeys: String, CodingKey {
        case sku, device, deviceName, type, capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sku = try container.decode(String.self, forKey: .sku)
        device = try container.decode(String.self, forKey: .device)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? sku
        type = try container.decodeIfPresent(String.self, forKey: .type)
        capabilities = try container.decodeIfPresent([GoveeCapability].self, forKey: .capabilities) ?? []
    }
}

nonisolated struct GoveeDeviceAction: Codable, Sendable, Equatable, Hashable {
    var sku: String
    var device: String
    var deviceName: String
    var capabilityType: String
    var capabilityInstance: String
    var value: GoveeValue

    var summary: String { "\(deviceName) · \(capabilityInstance)" }
}

nonisolated struct GoveeControlRequest: Codable, Sendable, Equatable {
    struct Payload: Codable, Sendable, Equatable {
        struct Capability: Codable, Sendable, Equatable {
            let type: String
            let instance: String
            let value: GoveeValue
        }

        let sku: String
        let device: String
        let capability: Capability
    }

    let requestId: String
    let payload: Payload

    init(action: GoveeDeviceAction, requestID: UUID = UUID()) {
        requestId = requestID.uuidString
        payload = Payload(
            sku: action.sku,
            device: action.device,
            capability: Payload.Capability(
                type: action.capabilityType,
                instance: action.capabilityInstance,
                value: action.value
            )
        )
    }
}

nonisolated enum GoveeClientError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case httpStatus(Int)
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Enter your Govee API key."
        case .unauthorized: "Govee rejected the API key. Check whether a newer key invalidated it."
        case .rateLimited: "Govee is receiving commands too quickly. Wait briefly and try again."
        case .httpStatus(let code): "Govee returned HTTP \(code)."
        case .invalidResponse: "Govee returned an invalid response."
        case .rejected(let message): message
        }
    }
}
