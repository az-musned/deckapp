import Foundation

struct MockDashboardService: DashboardService {
    func dashboard() async -> RoomDashboard {
        RoomDashboard.preview
    }
}

struct MockCommandService: CommandService {
    func execute(_ command: CommandExecution) async -> CommandExecution {
        try? await Task.sleep(for: .milliseconds(450))
        var completed = command
        completed.status = .confirmed
        completed.backendMessage = "Confirmed by mock Home Assistant state"
        return completed
    }
}
