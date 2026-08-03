import Foundation
import SwiftData

@main
@MainActor
struct DashboardLayoutPersistenceValidation {
    static func main() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: DashboardLayoutRecord.self,
            configurations: configuration
        )
        let context = container.mainContext
        let template = RoomControlTemplate.roomControl
        let data = try JSONEncoder().encode(template.widgets)
        let record = DashboardLayoutRecord(
            templateID: template.id,
            name: template.name,
            widgetsData: data
        )
        context.insert(record)
        try context.save()

        let templateID = template.id
        let descriptor = FetchDescriptor<DashboardLayoutRecord>(
            predicate: #Predicate { $0.templateID == templateID }
        )
        let restoredRecord = try context.fetch(descriptor).first
        precondition(restoredRecord?.name == "Room Control")
        let restoredWidgets = try JSONDecoder().decode(
            [RoomWidgetDefinition].self,
            from: restoredRecord!.widgetsData
        )
        precondition(restoredWidgets == template.widgets)

        print("SwiftData dashboard layout persistence validation passed")
    }
}
