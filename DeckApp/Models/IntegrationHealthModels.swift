import Foundation

nonisolated enum IntegrationHealthLevel: String, Sendable {
    case healthy, attention, unavailable, informational
}

nonisolated struct IntegrationHealthItem: Identifiable, Sendable {
    let id: String
    let title: String
    let status: String
    let detail: String
    let level: IntegrationHealthLevel
    let symbol: String
}
