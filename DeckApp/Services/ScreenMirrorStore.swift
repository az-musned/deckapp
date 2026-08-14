import Foundation
import Observation
@preconcurrency import WebRTC

@MainActor
@Observable
final class ScreenMirrorStore {
    private(set) var videoTrack: RTCVideoTrack?
    private(set) var hasReceivedFrame = false
    private(set) var connectionState: ScreenMirrorConnectionState = .disconnected

    /// WebRTC hands the app a track once, not a callback per decoded frame, so there's no
    /// per-frame timestamp left to poll for staleness the way the old wire protocol had.
    /// Connection health is exactly what RTCPeerConnectionDelegate's ICE state already
    /// reports (see PeerConnectionSession), so derive staleness from connectionState instead
    /// of a separate polling task.
    var isStale: Bool { hasReceivedFrame && connectionState != .connected }

    let mode: ScreenMirrorMode

    @ObservationIgnored private weak var controller: RemoteInputController?
    @ObservationIgnored private let client: any ScreenMirrorServing
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var appIsActive = true

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
        await client.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            mode: mode,
            track: { [weak self] track in
                Task { @MainActor in self?.apply(track) }
            },
            state: { [weak self] state in
                Task { @MainActor in self?.connectionState = state }
            }
        )
    }

    private func stopTransport() async {
        await client.stop()
        connectionState = .disconnected
        hasReceivedFrame = false
        videoTrack = nil
    }

    private func apply(_ track: RTCVideoTrack?) {
        videoTrack = track
        if track != nil { hasReceivedFrame = true }
    }
}

nonisolated struct ScreenMirrorConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}
