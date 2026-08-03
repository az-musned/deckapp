import Foundation

nonisolated struct HomeAssistantSceneAction: Identifiable, Sendable, Equatable {
    let entityID: String
    let title: String
    let domain: String
    let isAvailable: Bool
    let isFavorite: Bool

    var id: String { entityID }
    var symbol: String { domain == "scene" ? "sparkles" : "play.square.stack.fill" }
    var kindTitle: String { domain == "scene" ? "Scene" : "Script" }
}

nonisolated struct OrchestrationStep: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    var status: CommandStatus
    var detail: String
}

nonisolated struct SceneOrchestrationExecution: Identifiable, Sendable, Equatable {
    let id: UUID
    let entityID: String
    let title: String
    var steps: [OrchestrationStep]

    init(id: UUID = UUID(), entityID: String, title: String, steps: [OrchestrationStep]) {
        self.id = id
        self.entityID = entityID
        self.title = title
        self.steps = steps
    }
}
