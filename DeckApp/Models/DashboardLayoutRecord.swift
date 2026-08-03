import Foundation
import SwiftData

@Model
final class DashboardLayoutRecord {
    @Attribute(.unique) var templateID: UUID
    var name: String
    var widgetsData: Data
    var updatedAt: Date

    init(templateID: UUID, name: String, widgetsData: Data, updatedAt: Date = .now) {
        self.templateID = templateID
        self.name = name
        self.widgetsData = widgetsData
        self.updatedAt = updatedAt
    }
}
