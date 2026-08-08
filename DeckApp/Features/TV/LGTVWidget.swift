import SwiftUI

struct LGTVWidget: View {
    @Environment(AppState.self) private var appState
    let definition: RoomWidgetDefinition
    let compact: Bool
    @State private var showRemote = false

    private var device: LGTVDevice? { appState.lgTV.device(id: definition.backend.identifier) ?? appState.lgTV.selectedDevice }
    private var isActiveDevice: Bool { device?.id == appState.lgTV.selectedDeviceID }

    var body: some View {
        DashboardCard {
            HStack(spacing: DesignToken.Spacing.small) {
                GlassIcon(symbol: "tv.fill", tint: .purple, size: definition.size == .small ? 36 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.title).font(.headline).lineLimit(1)
                    Text(device?.name ?? "TV not configured").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Circle().fill(isActiveDevice && appState.lgTV.connectionState.isConnected ? DesignToken.Color.positive : .secondary).frame(width: 8, height: 8)
                Button { showRemote = true } label: {
                    Image(systemName: "arrow.up.forward.app").frame(width: 34, height: 34)
                }.buttonStyle(.plain)
            }

            if definition.size == .small {
                HStack {
                    Text(isActiveDevice ? (appState.lgTV.tvState.foregroundApplicationName ?? "webOS") : "Tap to connect")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isActiveDevice ? (appState.lgTV.tvState.foregroundApplicationName ?? "webOS") : "Ready to connect").font(.title3.bold()).lineLimit(1)
                        Text(isActiveDevice ? "Volume \(appState.lgTV.tvState.volume)%" : (device?.host ?? "Choose a TV in settings"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await activate(); await appState.lgTV.toggleMute() } } label: {
                        Image(systemName: appState.lgTV.tvState.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill").frame(width: 42, height: 42)
                    }.buttonStyle(.plain).glassSurface(.interactive, cornerRadius: 999, interactive: true)
                    Button { Task { await activate(); await appState.lgTV.powerToggle() } } label: {
                        Image(systemName: "power").frame(width: 42, height: 42)
                    }.buttonStyle(.plain).glassSurface(.interactive, cornerRadius: 999, tint: .red.opacity(0.15), interactive: true)
                }

                HStack(spacing: DesignToken.Spacing.small) {
                    Button { Task { await activate(); await appState.lgTV.volumeDown() } } label: {
                        Image(systemName: "speaker.minus").frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    Button { Task { await activate(); await appState.lgTV.playback(.play) } } label: {
                        Image(systemName: "playpause.fill").frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    Button { Task { await activate(); await appState.lgTV.volumeUp() } } label: {
                        Image(systemName: "speaker.plus").frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                }
                .buttonStyle(.plain)

                if definition.size == .large || definition.size == .wide {
                    LGDirectionalPad { button in Task { await activate(); await appState.lgTV.send(button) } }
                        .scaleEffect(compact ? 0.9 : 1)
                } else {
                    Button("Open Remote") { showRemote = true }.buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showRemote) { LGTVRemoteView() }
    }

    private func activate() async {
        guard let device else { return }
        if appState.lgTV.selectedDeviceID != device.id { appState.lgTV.select(device.id, connect: false) }
        if !appState.lgTV.connectionState.isConnected { await appState.lgTV.connect() }
    }
}
