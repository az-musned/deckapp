import Foundation

nonisolated enum RoomAction: Sendable, Equatable {
    case activateScene(String)
    case setLight(id: UUID, brightness: Double)
    case setTargetTemperature(Double)
    case toggleTVPower
    case setTVVolume(Double)
    case setPCVolume(Double)
    case toggleMicrophone
    case launchGame
    case sleepPC
    case companionButton(String)
    case mockControl(String)
}

nonisolated enum CommandStatus: String, Sendable {
    case pending
    case queued
    case running
    case confirmed
    case failed
    case unavailable
}

nonisolated struct CommandExecution: Identifiable, Sendable {
    let id: UUID
    let action: RoomAction
    var status: CommandStatus
    var backendMessage: String?

    init(id: UUID = UUID(), action: RoomAction, status: CommandStatus, backendMessage: String? = nil) {
        self.id = id
        self.action = action
        self.status = status
        self.backendMessage = backendMessage
    }
}
