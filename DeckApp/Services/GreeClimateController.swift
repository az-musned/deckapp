import Foundation
import Observation

@MainActor
@Observable
final class GreeClimateController {
    var connectionStatus: GreeConnectionStatus = .notConfigured
    var devices: [GreeDevice] = []
    var selectedDevice: GreeDevice?
    var state: GreeClimateState = .unknown
    var commandExecution: GreeClimateCommandExecution?
    var email = ""
    var password = ""

    var hasStoredCredentials: Bool {
        (try? keychain.load(account: emailAccount)).flatMap { $0 } != nil
    }

    private var service: any GreeClimateServing = GreeCloudClimateClient()
    private let keychain = KeychainSecretStore(service: "com.example.DeckApp.gree")
    private let emailAccount = "email"
    private let passwordAccount = "password"
    private var listenTask: Task<Void, Never>?
    private var isActive = false

    init(service: (any GreeClimateServing)? = nil) {
        if let service { self.service = service }
        email = (try? keychain.load(account: emailAccount)).flatMap { $0 } ?? ""
    }

    /// Called on view appear / scenePhase becoming active. Starts the cloud
    /// MQTT session; state read while backgrounded is deliberately not kept
    /// alive, per the accepted foreground-only-freshness tradeoff.
    func activate() async {
        isActive = true
        guard devices.isEmpty, selectedDevice == nil else {
            if let selectedDevice { await startSession(device: selectedDevice) }
            return
        }
        await signInAndDiscover()
    }

    /// Called on view disappear / scenePhase leaving active.
    func deactivate() async {
        isActive = false
        listenTask?.cancel()
        listenTask = nil
        await service.disconnectSession()
        state.confidence = .stale
        state.availability = .unknown
    }

    func saveCredentialsAndSignIn() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            connectionStatus = .failed(GreeClimateError.missingCredentials.localizedDescription)
            return
        }
        try? keychain.save(trimmedEmail, account: emailAccount)
        try? keychain.save(trimmedPassword, account: passwordAccount)
        email = trimmedEmail
        password = ""
        await signInAndDiscover()
    }

    func forgetCredentials() async {
        await deactivate()
        try? keychain.delete(account: emailAccount)
        try? keychain.delete(account: passwordAccount)
        email = ""
        password = ""
        devices = []
        selectedDevice = nil
        state = .unknown
        connectionStatus = .notConfigured
    }

    func selectDevice(_ device: GreeDevice) async {
        selectedDevice = device
        state = .unknown
        guard isActive else { return }
        await startSession(device: device)
    }

    func setPower(_ isOn: Bool) async {
        await perform(.setPower(isOn))
    }

    func setTargetTemperature(_ temperature: Double) async {
        await perform(.setTargetTemperature(temperature))
    }

    func setMode(_ mode: GreeHVACMode) async {
        await perform(.setMode(mode))
    }

    func setFanMode(_ fan: GreeFanSpeed) async {
        await perform(.setFanMode(fan))
    }

    func setSwing(vertical: GreeSwingPosition? = nil, horizontal: GreeSwingPosition? = nil) async {
        await perform(.setSwing(vertical: vertical, horizontal: horizontal))
    }

    private func signInAndDiscover() async {
        guard let storedEmail = (try? keychain.load(account: emailAccount)) ?? nil,
              let storedPassword = (try? keychain.load(account: passwordAccount)) ?? nil,
              !storedEmail.isEmpty, !storedPassword.isEmpty else {
            connectionStatus = .notConfigured
            return
        }

        connectionStatus = .authenticating
        do {
            try await service.login(email: storedEmail, password: storedPassword)
            let found = try await service.discoverDevices()
            devices = found
            connectionStatus = .connected(deviceCount: found.count)
            let device = selectedDevice.flatMap { current in found.first { $0.mac == current.mac } } ?? found.first
            selectedDevice = device
            if isActive, let device {
                await startSession(device: device)
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    private func startSession(device: GreeDevice) async {
        listenTask?.cancel()
        listenTask = nil
        do {
            let stream = try await service.connectSession(device: device)
            listenTask = Task { [weak self] in
                guard let self else { return }
                for await update in stream where update.mac == device.mac {
                    self.state = update.state
                }
                guard !Task.isCancelled else { return }
                self.state.confidence = .stale
                self.state.availability = .unreachable
            }
            try await service.requestStatus(for: device)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            state.confidence = .stale
            state.availability = .unreachable
        }
    }

    private func perform(_ command: GreeClimateCommand) async {
        guard let device = selectedDevice else {
            commandExecution = GreeClimateCommandExecution(
                command: command,
                status: .unavailable,
                message: "Sign in and choose a Gree device first."
            )
            return
        }

        var execution = GreeClimateCommandExecution(
            command: command,
            status: .pending,
            message: "Sending to the Gree cloud service…"
        )
        commandExecution = execution
        await Task.yield()

        execution.status = .running
        execution.message = "Waiting for the Gree cloud service to confirm…"
        commandExecution = execution

        do {
            try await service.send(command, to: device)
            let confirmed = await waitForConfirmation(of: command, timeout: .seconds(8))
            execution.status = confirmed ? .confirmed : .failed
            execution.message = confirmed
                ? "Confirmed by Gree."
                : "Sent, but Gree did not report the change back in time."
        } catch {
            execution.status = .failed
            execution.message = error.localizedDescription
        }
        commandExecution = execution
    }

    private func waitForConfirmation(of command: GreeClimateCommand, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Self.matches(state, command) { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return Self.matches(state, command)
    }

    private nonisolated static func matches(_ state: GreeClimateState, _ command: GreeClimateCommand) -> Bool {
        switch command {
        case .setPower(let isOn):
            state.power == isOn
        case .setTargetTemperature(let temperature):
            abs(state.targetTemperature - (temperature * 2).rounded() / 2) < 0.1
        case .setMode(let mode):
            state.hvacMode == mode
        case .setFanMode(let fan):
            state.fanMode == fan
        case .setSwing(let vertical, let horizontal):
            (vertical == nil || state.verticalSwing == vertical!)
                && (horizontal == nil || state.horizontalSwing == horizontal!)
        }
    }
}
