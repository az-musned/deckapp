import Foundation
import Observation

@MainActor
@Observable
final class GoXLRStore {
    private(set) var channels: [GoXLRChannelState] = []
    private(set) var meterConnectionState: AudioMeterConnectionState = .disconnected
    private(set) var meterStreamIsStale = true
    private(set) var endpoints: [WindowsAudioEndpoint] = []
    private(set) var mappings: [GoXLRAudioChannelMapping] = []
    private(set) var mappingError: String?
    private(set) var isLoadingMappings = false

    @ObservationIgnored private weak var controller: RemoteInputController?
    @ObservationIgnored private let meterService: any GoXLRAudioMeterServing
    @ObservationIgnored private let apiService: any GoXLRAudioAPIServing
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var staleTask: Task<Void, Never>?
    @ObservationIgnored private var lastMessageDate: Date?

    init(
        meterService: any GoXLRAudioMeterServing = GoXLRAudioMeterClient(),
        apiService: any GoXLRAudioAPIServing = GoXLRAudioAPIClient()
    ) {
        self.meterService = meterService
        self.apiService = apiService
    }

    func attach(controller: RemoteInputController) { self.controller = controller }

    func syncControlChannels(_ controls: [WindowsGoXLRChannelState]) {
        let old = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        channels = controls.map { control in
            var merged = old[control.id] ?? GoXLRChannelState(control: control)
            merged.displayName = control.name
            merged.volume = control.level.clampedMeterValue
            merged.isMuted = control.isMuted
            if let mapping = mappings.first(where: { $0.id == control.id }) {
                merged.endpointID = mapping.endpointId
                merged.endpointName = mapping.endpointName
                merged.isAvailable = mapping.endpointAvailable
            }
            return merged
        }
    }

    func channel(for id: String) -> GoXLRChannelState? { channels.first { $0.id == id } }
    var controlsAreAvailable: Bool { controller?.pairingState.isPaired == true }

    func updateVolumeDraft(channelId: String, value: Double) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].volume = value.clampedMeterValue
    }

    func setVolume(channelId: String, value: Double) async {
        await controller?.setGoXLRLevel(id: channelId, level: value.clampedMeterValue)
    }

    func setMuted(channelId: String, isMuted: Bool) async {
        await controller?.setGoXLRMuted(id: channelId, muted: isMuted)
    }

    func toggleMute(channelId: String) async {
        guard let channel = channel(for: channelId) else { return }
        await setMuted(channelId: channelId, isMuted: !channel.isMuted)
    }

    func startMetering() async {
        consumers += 1
        guard consumers == 1, appIsActive else { return }
        await connectMetering()
    }

    func stopMetering() async {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        await stopTransport()
    }

    func reconnectMetering() async {
        guard consumers > 0, appIsActive else { return }
        await connectMetering()
    }

    func agentDidDisconnect() async {
        await stopTransport()
    }

    func agentConfigurationChanged() async {
        await stopTransport()
        if consumers > 0, appIsActive { await connectMetering() }
    }

    func setAppActive(_ active: Bool) async {
        appIsActive = active
        if active, consumers > 0 {
            await connectMetering()
        } else if !active {
            await stopTransport()
        }
    }

    func refreshChannels() async {
        await controller?.refreshAgentSecurityState()
        guard let controller else { return }
        syncControlChannels(controller.capabilitySnapshot?.goXLRChannels ?? [])
        await loadMappings()
    }

    func loadAvailableEndpoints() async { await loadMappings() }

    func updateChannelMapping(channelId: String, endpointId: String?) async {
        guard let configuration = controller?.goXLRAudioConfiguration else {
            mappingError = "Pair and configure the Windows Agent first."
            return
        }
        mappingError = nil
        do {
            try await apiService.updateMapping(
                channelID: channelId,
                endpointID: endpointId,
                addresses: configuration.addresses,
                credential: configuration.credential
            )
            await loadMappings()
        } catch {
            mappingError = error.localizedDescription
        }
    }

    private func loadMappings() async {
        guard let configuration = controller?.goXLRAudioConfiguration else {
            mappingError = "Pair and configure the Windows Agent first."
            return
        }
        isLoadingMappings = true
        defer { isLoadingMappings = false }
        do {
            async let loadedEndpoints = apiService.endpoints(addresses: configuration.addresses, credential: configuration.credential)
            async let loadedMappings = apiService.channels(addresses: configuration.addresses, credential: configuration.credential)
            endpoints = try await loadedEndpoints
            mappings = try await loadedMappings
            mappingError = nil
            syncControlChannels(controller?.capabilitySnapshot?.goXLRChannels ?? [])
        } catch {
            mappingError = error.localizedDescription
        }
    }

    private func connectMetering() async {
        guard let configuration = controller?.goXLRAudioConfiguration else {
            meterConnectionState = .failed("Pair and configure the Windows Agent first.")
            return
        }
        staleTask?.cancel()
        lastMessageDate = nil
        meterStreamIsStale = true
        await meterService.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            message: { [weak self] message in
                Task { @MainActor in self?.apply(message) }
            },
            state: { [weak self] state in
                Task { @MainActor in self?.meterConnectionState = state }
            }
        )
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.updateStaleness(now: .now)
            }
        }
    }

    private func stopTransport() async {
        staleTask?.cancel()
        staleTask = nil
        await meterService.stop()
        meterConnectionState = .disconnected
        meterStreamIsStale = true
        resetMeters()
    }

    func apply(_ message: AudioMetersMessage) {
        guard message.type == "audio.meters" else { return }
        let now = Date()
        lastMessageDate = now
        meterStreamIsStale = false
        GoXLRChannelStateReducer.apply(message, to: &channels, now: now)
    }

    func updateStaleness(now: Date) {
        guard let lastMessageDate else { return }
        let age = now.timeIntervalSince(lastMessageDate)
        guard age >= 1 else { return }
        meterStreamIsStale = true
        GoXLRChannelStateReducer.decay(&channels, elapsed: age)
    }

    private func resetMeters() {
        for index in channels.indices {
            channels[index].linearPeak = 0
            channels[index].decibels = -120
            channels[index].displayLevel = 0
            channels[index].peakHold = 0
            channels[index].isClipping = false
            channels[index].lastMeterUpdate = nil
        }
    }

#if DEBUG
    func loadPreviewChannels() {
        let controls = [
            WindowsGoXLRChannelState(id: "mic", name: "Mic", level: 0.76, isMuted: false),
            WindowsGoXLRChannelState(id: "chat", name: "Chat", level: 0.68, isMuted: false),
            WindowsGoXLRChannelState(id: "music", name: "Music", level: 1, isMuted: false),
            WindowsGoXLRChannelState(id: "game", name: "Game", level: 0.52, isMuted: true),
            WindowsGoXLRChannelState(id: "line", name: "Line In", level: 0.4, isMuted: false)
        ]
        syncControlChannels(controls)
        apply(AudioMetersMessage(type: "audio.meters", sequence: 1, timestamp: 0, channels: [
            AudioMeterChannelPayload(id: "mic", endpointId: "capture-1", available: true, linearPeak: 0, decibels: -120, displayLevel: 0, peakHold: 0, clipping: false),
            AudioMeterChannelPayload(id: "chat", endpointId: "render-1", available: true, linearPeak: 0.18, decibels: -14.9, displayLevel: 0.72, peakHold: 0.84, clipping: false),
            AudioMeterChannelPayload(id: "music", endpointId: "render-2", available: true, linearPeak: 0.82, decibels: -1.7, displayLevel: 0.97, peakHold: 0.99, clipping: false),
            AudioMeterChannelPayload(id: "game", endpointId: "render-3", available: true, linearPeak: 1, decibels: 0, displayLevel: 1, peakHold: 1, clipping: true),
            AudioMeterChannelPayload(id: "line", endpointId: nil, available: false, linearPeak: 0, decibels: -120, displayLevel: 0, peakHold: 0, clipping: false)
        ]))
        meterConnectionState = .disconnected
    }
#endif
}

nonisolated struct GoXLRAudioConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}

nonisolated private extension Double {
    var clampedMeterValue: Double { min(max(isFinite ? self : 0, 0), 1) }
}
