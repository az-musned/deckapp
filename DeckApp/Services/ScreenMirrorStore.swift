import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ScreenMirrorStore {
    private(set) var latestFrame: CGImage?
    private(set) var connectionState: ScreenMirrorConnectionState = .disconnected
    private(set) var isStale = true

    let mode: ScreenMirrorMode

    @ObservationIgnored private weak var controller: RemoteInputController?
    @ObservationIgnored private let client: any ScreenMirrorServing
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var staleTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrameDate: Date?

    init(mode: ScreenMirrorMode, client: any ScreenMirrorServing = ScreenMirrorClient()) {
        self.mode = mode
        self.client = client
    }

    func attach(controller: RemoteInputController) { self.controller = controller }

    var isAvailable: Bool { controller?.securityState.screenShareAllowed == true }

    func startMirroring() async {
        consumers += 1
        guard consumers == 1, appIsActive else { return }
        await connect()
    }

    func stopMirroring() async {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        await stopTransport()
    }

    func agentDidDisconnect() async {
        await stopTransport()
    }

    func agentConfigurationChanged() async {
        await stopTransport()
        if consumers > 0, appIsActive { await connect() }
    }

    func setAppActive(_ active: Bool) async {
        appIsActive = active
        if active, consumers > 0 {
            await connect()
        } else if !active {
            await stopTransport()
        }
    }

    private func connect() async {
        guard let configuration = controller?.screenMirrorConfiguration else {
            connectionState = .failed("Pair and configure the Windows Agent first.")
            return
        }
        staleTask?.cancel()
        lastFrameDate = nil
        isStale = true
        await client.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            mode: mode,
            frame: { [weak self] frame in
                Task { @MainActor in self?.apply(frame) }
            },
            state: { [weak self] state in
                Task { @MainActor in self?.connectionState = state }
            }
        )
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.updateStaleness(now: .now)
            }
        }
    }

    private func stopTransport() async {
        staleTask?.cancel()
        staleTask = nil
        await client.stop()
        connectionState = .disconnected
        isStale = true
    }

    private func apply(_ frame: ScreenStreamFrame) {
        lastFrameDate = Date()
        isStale = false
        latestFrame = frame.image
    }

    private func updateStaleness(now: Date) {
        guard let lastFrameDate else { return }
        isStale = now.timeIntervalSince(lastFrameDate) >= 2
    }
}

nonisolated struct ScreenMirrorConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}
