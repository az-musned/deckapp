import Foundation
import Observation
@preconcurrency import WebRTC

@MainActor
@Observable
final class ScreenMirrorStore {
    private(set) var videoTrack: RTCVideoTrack?
    private(set) var hasReceivedFrame = false
    private(set) var connectionState: ScreenMirrorConnectionState = .disconnected
    // TEMPORARY: diagnosing the "connects but renders ~1fps" report -- see
    // ScreenMirrorPeerConnection.swift's startStatsPolling. Remove alongside that once resolved.
    private(set) var statsText: String?

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
        Self.resetStatsLog()
        await client.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            mode: mode,
            track: { [weak self] track in
                Task { @MainActor in self?.apply(track) }
            },
            state: { [weak self] state in
                Task { @MainActor in self?.connectionState = state }
            },
            stats: { [weak self] text in
                Task { @MainActor in
                    self?.statsText = text
                    Self.appendStatsLog(text)
                }
            }
        )
    }

    private func stopTransport() async {
        await client.stop()
        connectionState = .disconnected
        hasReceivedFrame = false
        videoTrack = nil
        statsText = nil
    }

    private func apply(_ track: RTCVideoTrack?) {
        videoTrack = track
        if track != nil { hasReceivedFrame = true }
    }

    // TEMPORARY: diagnosing the "connects but renders ~1fps" report -- writes each stats
    // line to Documents/screen-mirror-stats.log (pulled off-device via
    // `xcrun devicectl device copy from --domain-type appDataContainer`) so the numbers can
    // be read without someone reading the on-screen overlay aloud. Remove alongside the rest
    // of this diagnostic instrumentation once resolved.
    nonisolated private static func resetStatsLog() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("screen-mirror-stats.log"))
    }

    nonisolated private static func appendStatsLog(_ text: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("screen-mirror-stats.log")
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

nonisolated struct ScreenMirrorConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}
