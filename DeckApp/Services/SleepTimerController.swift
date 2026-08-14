import Foundation

@MainActor
@Observable
final class SleepTimerController {
    private(set) var isRunning = false
    private(set) var remainingSeconds = 0
    var selectedDuration = SleepTimerDuration.thirty
    var selectedTargets: Set<SleepTimerTarget> = [.pc, .tv]
    private(set) var lastCompletionMessage: String?

    private weak var appState: AppState?
    private var countdownTask: Task<Void, Never>?

    func attach(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard !selectedTargets.isEmpty, !isRunning else { return }
        countdownTask?.cancel()
        lastCompletionMessage = nil
        remainingSeconds = selectedDuration.seconds
        isRunning = true
        countdownTask = Task { [weak self] in
            while let self, self.remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
            }
            guard let self, !Task.isCancelled else { return }
            await self.fire()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        isRunning = false
        remainingSeconds = 0
    }

    private func fire() async {
        defer {
            isRunning = false
            remainingSeconds = 0
        }
        guard let appState else { return }
        let targets = selectedTargets
        if targets.contains(.pc) {
            await appState.performCompanionDashboardAction(.sleepPC)
        }
        if targets.contains(.tv) {
            await appState.lgTV.powerOff()
        }
        if targets.contains(.lights) {
            await appState.turnOffRoomLight()
        }
        lastCompletionMessage = "Sleep timer ran: " + targets.map(\.title).sorted().joined(separator: ", ")
    }
}
