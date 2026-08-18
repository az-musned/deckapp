import Foundation

@MainActor
@Observable
final class SleepTimerController {
    static let minutesRange = 1...240

    private(set) var isRunning = false
    private(set) var remainingSeconds = 0
    var selectedMinutes = 30
    var selectedTargets: Set<SleepTimerTarget> = [.pc, .tv]
    private(set) var lastCompletionMessage: String?
    // Set once start() successfully hands the PC target off to the Windows Agent's own
    // scheduled-sleep endpoint. When true, fire() skips the local (HA/Companion) PC action --
    // the Agent's timer runs independently of this in-app countdown and fires reliably even if
    // the phone is locked, backgrounded, or this Task gets suspended before it completes.
    private(set) var pcScheduledOnAgent = false

    private weak var appState: AppState?
    private var countdownTask: Task<Void, Never>?

    func attach(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard !selectedTargets.isEmpty, !isRunning else { return }
        countdownTask?.cancel()
        lastCompletionMessage = nil
        let totalSeconds = selectedMinutes * 60
        remainingSeconds = totalSeconds
        isRunning = true
        pcScheduledOnAgent = false
        countdownTask = Task { [weak self] in
            if let self, self.selectedTargets.contains(.pc), let appState = self.appState,
               !appState.remoteInput.usesMockAgent, appState.remoteInput.pairingState.isPaired {
                let accepted = await appState.remoteInput.scheduleSleep(afterSeconds: totalSeconds)
                self.pcScheduledOnAgent = accepted
            }
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
        guard pcScheduledOnAgent else { return }
        pcScheduledOnAgent = false
        guard let appState else { return }
        Task { await appState.remoteInput.cancelScheduledSleep() }
    }

    private func fire() async {
        defer {
            isRunning = false
            remainingSeconds = 0
            pcScheduledOnAgent = false
        }
        guard let appState else { return }
        let targets = selectedTargets
        if targets.contains(.pc), !pcScheduledOnAgent {
            // Only take the old best-effort path (requires this app process to still be
            // running right now) if the Agent-side schedule was never set up -- unpaired,
            // mock agent, or the schedule request itself failed.
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
