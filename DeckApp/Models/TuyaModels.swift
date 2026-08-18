import Foundation

/// Tuya's cloud API is split across regional data centers; a device only responds through
/// whichever one its account was created in. See
/// https://github.com/tuya/tuya-home-assistant/wiki/Countries-Regions-and-Tuya-Data-Center --
/// anywhere not listed there maps to Western America.
nonisolated enum TuyaDataCenter: String, Codable, CaseIterable, Identifiable, Sendable {
    case westAmerica
    case eastAmerica
    case centralEurope
    case westEurope
    case china
    case india

    var id: String { rawValue }

    var host: String {
        switch self {
        case .westAmerica: "https://openapi.tuyaus.com"
        case .eastAmerica: "https://openapi-ueaz.tuyaus.com"
        case .centralEurope: "https://openapi.tuyaeu.com"
        case .westEurope: "https://openapi-weaz.tuyaeu.com"
        case .china: "https://openapi.tuyacn.com"
        case .india: "https://openapi.tuyain.com"
        }
    }

    var title: String {
        switch self {
        case .westAmerica: "Western America"
        case .eastAmerica: "Eastern America"
        case .centralEurope: "Central Europe"
        case .westEurope: "Western Europe"
        case .china: "China"
        case .india: "India"
        }
    }
}

/// Non-secret half of the Tuya smart-plug configuration -- round-trips to UserDefaults as
/// JSON. The Access Secret is deliberately not a field here; it's stored in Keychain
/// separately, mirroring how GreeClimateController keeps the account password out of its
/// otherwise-plain-UserDefaults settings.
nonisolated struct TuyaPlugConfiguration: Codable, Sendable, Equatable {
    var accessID = ""
    var deviceID = ""
    var dataCenter: TuyaDataCenter = .westAmerica

    var isConfigured: Bool {
        !accessID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
