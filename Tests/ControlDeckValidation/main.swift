import Foundation

@main
struct ControlDeckValidation {
    static func main() throws {
        let launchMapping = CompanionButtonMapping(page: 2, row: 1, column: 3)
        var items = ControlDeckItem.initialItems(
            launchMapping: launchMapping,
            sleepMapping: nil
        )

        precondition(items.count == 4)
        precondition(items[2].mapping == launchMapping)
        precondition(items[3].mapping == nil)
        precondition(items[3].requiresConfirmation)

        var folder = ControlDeckItem.folder(title: "Games")
        folder.children.append(.companionButton(title: "Launch Game", mapping: launchMapping))
        folder.subtitle = "1 button"
        items.append(folder)

        let data = try JSONEncoder().encode(items)
        let restored = try JSONDecoder().decode([ControlDeckItem].self, from: data)
        precondition(restored == items)
        precondition(restored.last?.children.first?.mapping == launchMapping)

        print("Control Deck persistence validation passed")
    }
}
