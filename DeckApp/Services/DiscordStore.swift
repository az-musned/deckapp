import Foundation
import Observation

@MainActor
@Observable
final class DiscordStore {
    private(set) var bridgeState: DiscordBridgeState = .disconnected
    private(set) var transportState: AudioMeterConnectionState = .disconnected
    private(set) var voice: DiscordVoiceChannelState = .notConnected
    private(set) var lastError: String?
    private(set) var guilds: [DiscordGuildSummary] = []
    private(set) var channelsByGuildID: [String: [DiscordChannelSummary]] = [:]
    private(set) var isLoadingChannels = false

    @ObservationIgnored private weak var controller: RemoteInputController?
    @ObservationIgnored private let bridgeService: any DiscordBridgeServing
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var appIsActive = true

    init(bridgeService: any DiscordBridgeServing = DiscordClient()) {
        self.bridgeService = bridgeService
    }

    func attach(controller: RemoteInputController) { self.controller = controller }

    var controlsAreAvailable: Bool { controller?.pairingState.isPaired == true && bridgeState == .ready }

    func startWatching() async {
        consumers += 1
        guard consumers == 1, appIsActive else { return }
        await connect()
    }

    func stopWatching() async {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        await bridgeService.stop()
        transportState = .disconnected
    }

    func setAppActive(_ active: Bool) async {
        appIsActive = active
        if active, consumers > 0 {
            await connect()
        } else if !active {
            await bridgeService.stop()
        }
    }

    func toggleMute() async {
        await bridgeService.send(.mute(!voice.selfMute))
    }

    func toggleDeafen() async {
        await bridgeService.send(.deafen(!voice.selfDeaf))
    }

    func join(channelID: String) async {
        await bridgeService.send(.join(channelId: channelID))
    }

    func leave() async {
        await bridgeService.send(.leave)
    }

    func loadGuilds() async {
        await bridgeService.send(.listGuilds)
    }

    func loadChannels(guildID: String) async {
        isLoadingChannels = true
        await bridgeService.send(.listChannels(guildId: guildID))
    }

    private func connect() async {
        guard let configuration = controller?.discordBridgeConfiguration else {
            transportState = .failed("Pair and configure the Windows Agent first.")
            return
        }
        await bridgeService.start(
            addresses: configuration.addresses,
            credential: configuration.credential,
            transport: { [weak self] state in
                Task { @MainActor in self?.transportState = state }
            },
            status: { [weak self] message in
                Task { @MainActor in self?.apply(message) }
            },
            guilds: { [weak self] guilds in
                Task { @MainActor in
                    self?.guilds = guilds
                    guard let self else { return }
                    for guild in guilds { await self.loadChannels(guildID: guild.id) }
                }
            },
            channels: { [weak self] guildID, channels in
                Task { @MainActor in
                    self?.channelsByGuildID[guildID] = channels
                    self?.isLoadingChannels = false
                }
            }
        )
    }

    private func apply(_ message: DiscordStatusMessage) {
        let wasReady = bridgeState == .ready
        bridgeState = message.bridgeState
        voice = message.voice
        lastError = message.error
        if bridgeState == .ready, !wasReady {
            Task { await loadGuilds() }
        }
    }
}
