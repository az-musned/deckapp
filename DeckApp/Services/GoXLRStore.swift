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
    @ObservationIgnored private var interactionUIIsPresented = false
    @ObservationIgnored private var staleTask: Task<Void, Never>?
    @ObservationIgnored private var controlRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastMessageDate: Date?
    @ObservationIgnored private var activeVolumeInteractions: Set<String> = []
    @ObservationIgnored private var pendingVolumeTargets: [String: PendingVolumeTarget] = [:]
    @ObservationIgnored private var pendingMuteTargets: [String: PendingMuteTarget] = [:]
    @ObservationIgnored private var desiredMuteTargets: [String: DesiredMuteTarget] = [:]
    @ObservationIgnored private var muteCommandTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let meterUpdateCoalescer = GoXLRMeterUpdateCoalescer()

    private struct PendingVolumeTarget {
        let value: Double
        let expiresAt: Date
    }

    private struct PendingMuteTarget {
        let value: Bool
        let expiresAt: Date
    }

    private struct DesiredMuteTarget {
        let channelID: String
        let value: Bool
    }

    init(
        meterService: any GoXLRAudioMeterServing = GoXLRAudioMeterClient(),
        apiService: any GoXLRAudioAPIServing = GoXLRAudioAPIClient()
    ) {
        self.meterService = meterService
        self.apiService = apiService
    }

    func attach(controller: RemoteInputController) { self.controller = controller }

    func syncControlChannels(_ controls: [WindowsGoXLRChannelState]) {
        let now = Date()
        var old: [String: GoXLRChannelState] = [:]
        for channel in channels {
            let key = channel.id.lowercased()
            if old[key] == nil { old[key] = channel }
        }
        var pending = pendingVolumeTargets
        var pendingMutes = pendingMuteTargets
        var seenControlIDs: Set<String> = []
        channels = controls.compactMap { control in
            let key = control.id.lowercased()
            guard seenControlIDs.insert(key).inserted else { return nil }
            var merged = old[key] ?? GoXLRChannelState(control: control)
            merged.displayName = control.name
            if !activeVolumeInteractions.contains(key), let target = pending[key] {
                if abs(control.level.clampedMeterValue - target.value) <= 0.015 || target.expiresAt <= now {
                    merged.volume = control.level.clampedMeterValue
                    pending.removeValue(forKey: key)
                }
            } else if !activeVolumeInteractions.contains(key) {
                merged.volume = control.level.clampedMeterValue
            }
            if let target = pendingMutes[key] {
                if control.isMuted == target.value || target.expiresAt <= now {
                    merged.isMuted = control.isMuted
                    pendingMutes.removeValue(forKey: key)
                } else {
                    // Keep the immediate UI response while waiting for confirmed Agent state.
                    merged.isMuted = target.value
                }
            } else {
                merged.isMuted = control.isMuted
            }
            if let mapping = mappings.first(where: { $0.id.caseInsensitiveCompare(control.id) == .orderedSame }) {
                merged.endpointID = mapping.endpointId
                merged.endpointName = mapping.endpointName
                merged.isAvailable = mapping.endpointAvailable
            }
            return merged
        }
        pendingVolumeTargets = pending
        pendingMuteTargets = pendingMutes
    }

    func channel(for id: String) -> GoXLRChannelState? {
        channels.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
    var controlsAreAvailable: Bool { controller?.pairingState.isPaired == true }

    func updateVolumeDraft(channelId: String, value: Double) {
        guard let index = channels.firstIndex(where: { $0.id.caseInsensitiveCompare(channelId) == .orderedSame }) else { return }
        channels[index].volume = value.clampedMeterValue
    }

    func beginVolumeInteraction(channelId: String) {
        let key = channelId.lowercased()
        activeVolumeInteractions.insert(key)
        pendingVolumeTargets.removeValue(forKey: key)
    }

    func commitVolumeInteraction(channelId: String, value: Double) async {
        let normalized = value.clampedMeterValue
        updateVolumeDraft(channelId: channelId, value: normalized)
        let key = channelId.lowercased()
        activeVolumeInteractions.remove(key)
        pendingVolumeTargets[key] = PendingVolumeTarget(
            value: normalized,
            expiresAt: .now.addingTimeInterval(2)
        )
        await setVolume(channelId: channelId, value: normalized)
    }

    func setVolume(channelId: String, value: Double) async {
        await controller?.setGoXLRLevel(id: channelId, level: value.clampedMeterValue)
    }

    func setMuted(channelId: String, isMuted: Bool) async {
        let key = channelId.lowercased()
        guard let index = channels.firstIndex(where: { $0.id.caseInsensitiveCompare(channelId) == .orderedSame }) else { return }
        channels[index].isMuted = isMuted
        pendingMuteTargets[key] = PendingMuteTarget(
            value: isMuted,
            expiresAt: .now.addingTimeInterval(2)
        )
        desiredMuteTargets[key] = DesiredMuteTarget(channelID: channelId, value: isMuted)
        guard muteCommandTasks[key] == nil else { return }
        muteCommandTasks[key] = Task { [weak self] in
            await self?.runMuteCommandLoop(key: key)
        }
    }

    func toggleMute(channelId: String) async {
        guard let channel = channel(for: channelId) else { return }
        await setMuted(channelId: channelId, isMuted: !channel.isMuted)
    }

    func startMetering() async {
        consumers += 1
        guard consumers == 1, appIsActive, !interactionUIIsPresented else { return }
        await controller?.refreshGoXLRControlState()
        await connectMetering()
    }

    func stopMetering() async {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        await stopTransport()
    }

    func reconnectMetering() async {
        guard consumers > 0, appIsActive, !interactionUIIsPresented else { return }
        await connectMetering()
    }

    func agentDidDisconnect() async {
        await stopTransport()
    }

    func agentConfigurationChanged() async {
        await stopTransport()
        if consumers > 0, appIsActive, !interactionUIIsPresented { await connectMetering() }
    }

    func setAppActive(_ active: Bool) async {
        appIsActive = active
        if active, consumers > 0, !interactionUIIsPresented {
            await connectMetering()
        } else if !active {
            await stopTransport()
        }
    }

    /// Pauses high-frequency meter and capability polling while a text-heavy editor
    /// is covering the dashboard, then restores it without changing consumer counts.
    func setInteractionUIIsPresented(_ presented: Bool) async {
        guard interactionUIIsPresented != presented else { return }
        interactionUIIsPresented = presented
        if presented {
            await stopTransport()
        } else if consumers > 0, appIsActive {
            await controller?.refreshGoXLRControlState()
            await connectMetering()
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
        guard !interactionUIIsPresented else { return }
        guard let configuration = controller?.goXLRAudioConfiguration else {
            meterConnectionState = .failed("Pair and configure the Windows Agent first.")
            return
        }
        staleTask?.cancel()
        startControlRefresh()
        lastMessageDate = nil
        meterStreamIsStale = true
        let meterUpdateCoalescer = meterUpdateCoalescer
        let deliverMeterUpdate: @MainActor @Sendable (AudioMetersMessage) -> Void = { [weak self] latest in
            self?.apply(latest)
        }
        await meterService.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            message: { [meterUpdateCoalescer, deliverMeterUpdate] message in
                Task {
                    await meterUpdateCoalescer.submit(message, delivery: deliverMeterUpdate)
                }
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
        controlRefreshTask?.cancel()
        controlRefreshTask = nil
        activeVolumeInteractions.removeAll()
        pendingVolumeTargets.removeAll()
        pendingMuteTargets.removeAll()
        await meterService.stop()
        meterConnectionState = .disconnected
        meterStreamIsStale = true
        resetMeters()
    }

    private func startControlRefresh() {
        controlRefreshTask?.cancel()
        controlRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                await self.controller?.refreshGoXLRControlState()
            }
        }
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

    private func runMuteCommandLoop(key: String) async {
        while !Task.isCancelled, let target = desiredMuteTargets[key] {
            await controller?.setGoXLRMuted(id: target.channelID, muted: target.value)
            guard desiredMuteTargets[key]?.value == target.value else { continue }
            desiredMuteTargets.removeValue(forKey: key)
        }
        muteCommandTasks[key] = nil
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

private actor GoXLRMeterUpdateCoalescer {
    private var latest: AudioMetersMessage?
    private var deliveryScheduled = false

    /// Keeps only the newest meter frame and publishes at most about 30 times per second.
    func submit(
        _ message: AudioMetersMessage,
        delivery: @escaping @MainActor @Sendable (AudioMetersMessage) -> Void
    ) async {
        latest = message
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        try? await Task.sleep(for: .milliseconds(33))
        let result = latest
        latest = nil
        deliveryScheduled = false
        if let result { await delivery(result) }
    }
}

nonisolated struct GoXLRAudioConfiguration: Sendable, Equatable {
    let addresses: [String]
    let credential: String
}

nonisolated private extension Double {
    var clampedMeterValue: Double { min(max(isFinite ? self : 0, 0), 1) }
}
