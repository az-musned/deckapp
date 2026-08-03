import Foundation

protocol DashboardService: Sendable {
    func dashboard() async -> RoomDashboard
}

protocol CommandService: Sendable {
    func execute(_ command: CommandExecution) async -> CommandExecution
}
