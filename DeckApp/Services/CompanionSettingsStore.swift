import Foundation

struct CompanionSettingsStore: Sendable {
    private let defaults: UserDefaults
    private let addressKey = "companion.address"
    private let pageKey = "companion.button.page"
    private let rowKey = "companion.button.row"
    private let columnKey = "companion.button.column"
    private let controlDeckKey = "companion.controlDeck.items.v1"

    private func dashboardMappingKey(for action: CompanionDashboardAction) -> String {
        "companion.dashboard.\(action.rawValue)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAddress() -> String {
        defaults.string(forKey: addressKey) ?? ""
    }

    func saveAddress(_ address: String) {
        defaults.set(address, forKey: addressKey)
    }

    func loadButtonMapping() -> CompanionButtonMapping {
        let page = defaults.object(forKey: pageKey) == nil ? 1 : defaults.integer(forKey: pageKey)
        return CompanionButtonMapping(
            page: max(page, 1),
            row: max(defaults.integer(forKey: rowKey), 0),
            column: max(defaults.integer(forKey: columnKey), 0)
        )
    }

    func saveButtonMapping(_ mapping: CompanionButtonMapping) {
        defaults.set(mapping.page, forKey: pageKey)
        defaults.set(mapping.row, forKey: rowKey)
        defaults.set(mapping.column, forKey: columnKey)
    }

    func loadDashboardMappings() -> [CompanionDashboardAction: CompanionButtonMapping] {
        var mappings: [CompanionDashboardAction: CompanionButtonMapping] = [:]
        let decoder = JSONDecoder()

        for action in CompanionDashboardAction.allCases {
            guard let data = defaults.data(forKey: dashboardMappingKey(for: action)),
                  let mapping = try? decoder.decode(CompanionButtonMapping.self, from: data) else {
                continue
            }
            mappings[action] = mapping
        }

        return mappings
    }

    func saveDashboardMapping(_ mapping: CompanionButtonMapping, for action: CompanionDashboardAction) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: dashboardMappingKey(for: action))
    }

    func loadControlDeckItems() -> [ControlDeckItem]? {
        guard let data = defaults.data(forKey: controlDeckKey) else { return nil }
        return try? JSONDecoder().decode([ControlDeckItem].self, from: data)
    }

    func saveControlDeckItems(_ items: [ControlDeckItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: controlDeckKey)
    }
}
