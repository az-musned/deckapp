import Foundation

@main
struct ControlDeckValidation {
    static func main() throws {
        let launchMapping = CompanionButtonMapping(page: 2, row: 1, column: 3)
        var items = ControlDeckItem.initialItems(
            launchMapping: launchMapping,
            sleepMapping: nil,
            shutdownMapping: nil
        )

        precondition(items.count == 5)
        precondition(items[2].mapping == launchMapping)
        precondition(items[3].mapping == nil)
        precondition(items[2].action == .companion(launchMapping))
        precondition(items[3].action == nil)
        precondition(items[3].requiresConfirmation)
        precondition(items[4].mapping == nil)
        precondition(items[4].action == nil)
        precondition(items[4].requiresConfirmation)

        var folder = ControlDeckItem.folder(title: "Games")
        folder.children.append(.companionButton(title: "Launch Game", mapping: launchMapping))
        folder.subtitle = "1 button"
        items.append(folder)

        let data = try JSONEncoder().encode(items)
        let restored = try JSONDecoder().decode([ControlDeckItem].self, from: data)
        precondition(restored == items)
        precondition(restored.last?.children.first?.mapping == launchMapping)

        var shortcut = ControlDeckItem.actionButton()
        shortcut.action = .shortcut(AppleShortcutAction(name: "Movie Mode", input: "Bedroom"))
        var govee = ControlDeckItem.actionButton()
        govee.action = .govee(GoveeDeviceAction(
            sku: "H605C",
            device: "device-id",
            deviceName: "Desk Light",
            capabilityType: "devices.capabilities.on_off",
            capabilityInstance: "powerSwitch",
            value: .number(1)
        ))
        let actions = [shortcut, govee]
        let actionData = try JSONEncoder().encode(actions)
        let restoredActions = try JSONDecoder().decode([ControlDeckItem].self, from: actionData)
        precondition(restoredActions == actions)

        // Old persisted buttons have no action field and must continue to decode.
        let legacy = Data(#"[{"id":"11111111-2222-3333-4444-555555555555","kind":"companionButton","title":"Legacy","subtitle":"P1 · R0 · C0","symbol":"bolt.fill","tintName":"blue","mapping":{"page":1,"row":0,"column":0},"requiresConfirmation":false,"children":[]}]"#.utf8)
        let legacyItem = try JSONDecoder().decode([ControlDeckItem].self, from: legacy).first
        precondition(legacyItem?.action == nil)
        precondition(legacyItem?.mapping == CompanionButtonMapping())

        print("Control Deck persistence validation passed")
    }
}
