import SwiftUI

struct AudioLevelMeterView: View, Equatable {
    let level: Double
    let peakHold: Double
    let isClipping: Bool
    let isAvailable: Bool
    let isStale: Bool
    var decibels: Double = -120
    var channelName = "Channel"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.level == rhs.level && lhs.peakHold == rhs.peakHold
            && lhs.isClipping == rhs.isClipping && lhs.isAvailable == rhs.isAvailable
            && lhs.isStale == rhs.isStale && lhs.decibels == rhs.decibels
            && lhs.channelName == rhs.channelName
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if isAvailable {
                    Canvas { context, size in
                        let segmentCount = 16
                        let gap = max(1, size.height * 0.012)
                        let segmentHeight = max(1, (size.height - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
                        for segment in 0..<segmentCount {
                            let threshold = Double(segment + 1) / Double(segmentCount)
                            let y = size.height - CGFloat(segment + 1) * segmentHeight - CGFloat(segment) * gap
                            let rect = CGRect(x: 0, y: y, width: size.width, height: segmentHeight)
                            let path = Path(roundedRect: rect, cornerRadius: min(2, segmentHeight / 2))
                            let color = threshold <= clampedLevel
                                ? segmentColor(at: threshold)
                                : Color.secondary.opacity(isStale ? 0.08 : 0.14)
                            context.fill(path, with: .color(color))
                        }

                        if clampedPeak > 0 {
                            let peakY = max(0, size.height * (1 - clampedPeak) - 1)
                            let peakRect = CGRect(x: 0, y: peakY, width: size.width, height: 2)
                            context.fill(
                                Path(roundedRect: peakRect, cornerRadius: 1),
                                with: .color(isClipping ? DesignToken.Color.destructive : .white.opacity(0.82))
                            )
                        }
                    }
                } else {
                    Image(systemName: "exclamationmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .opacity(isStale ? 0.48 : 1)
            .animation(reduceMotion ? nil : .linear(duration: 0.075), value: clampedLevel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAvailable ? "\(channelName) audio level" : "\(channelName) channel unavailable")
        .accessibilityValue(isAvailable ? accessibleLevel : "Unavailable")
    }

    private var clampedLevel: Double { min(max(level.isFinite ? level : 0, 0), 1) }
    private var clampedPeak: Double { min(max(peakHold.isFinite ? peakHold : 0, clampedLevel), 1) }
    private func segmentColor(at level: Double) -> Color {
        if level >= 0.94 { return DesignToken.Color.destructive }
        if level >= 0.82 { return .orange }
        if level >= 0.68 { return .yellow }
        return DesignToken.Color.positive
    }
    private var accessibleLevel: String {
        if isStale { return "Stale" }
        if decibels.isFinite, decibels > -120 { return "\(decibels.formatted(.number.precision(.fractionLength(1)))) decibels" }
        return "Silent"
    }
}

struct GoXLRMixerView: View {
    let store: GoXLRStore
    @State private var showingMappings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Label(
                        store.controlsAreAvailable ? "GoXLR control connected" : "GoXLR control unavailable",
                        systemImage: "slider.vertical.3"
                    )
                    .foregroundStyle(store.controlsAreAvailable ? DesignToken.Color.positive : .secondary)
                    Spacer()
                    meterStatus
                    Button("Mappings", systemImage: "point.3.connected.trianglepath.dotted") {
                        showingMappings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, DesignToken.Spacing.small)
                Divider()

                Group {
                    if store.channels.isEmpty {
                        ContentUnavailableView(
                            "No GoXLR Channels",
                            systemImage: "slider.vertical.3",
                            description: Text("Connect the Windows Agent and confirm GoXLR control is enabled.")
                        )
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: DesignToken.Spacing.medium) {
                                ForEach(store.channels) { channel in
                                    detailedStrip(channel)
                                        .frame(width: 138)
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("GoXLR Mixer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mappings", systemImage: "point.3.connected.trianglepath.dotted") { showingMappings = true }
                }
            }
            .sheet(isPresented: $showingMappings) { GoXLREndpointMappingView(store: store) }
            .task {
                await store.startMetering()
                await store.refreshChannels()
                do { try await Task.sleep(for: .seconds(86_400)) } catch { }
                await store.stopMetering()
            }
        }
    }

    private var meterStatus: some View {
        Label(
            store.meterStreamIsStale ? "Meters stale" : store.meterConnectionState.title,
            systemImage: store.meterConnectionState == .connected && !store.meterStreamIsStale
                ? "waveform.path.ecg" : "waveform.slash"
        )
        .font(.caption)
        .foregroundStyle(store.meterConnectionState == .connected && !store.meterStreamIsStale ? DesignToken.Color.positive : .secondary)
        .accessibilityLabel("Audio meter connection \(store.meterConnectionState.title)")
    }

    private func detailedStrip(_ channel: GoXLRChannelState) -> some View {
        VStack(spacing: DesignToken.Spacing.small) {
            Text(channel.displayName)
                .font(.headline)
                .lineLimit(1)
            Text(channel.isAvailable ? (channel.endpointName ?? "Endpoint mapped") : "Endpoint unavailable")
                .font(.caption2)
                .foregroundStyle(channel.isAvailable ? .secondary : DesignToken.Color.destructive)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)
            AudioLevelMeterView(
                level: channel.displayLevel,
                peakHold: channel.peakHold,
                isClipping: channel.isClipping,
                isAvailable: channel.isAvailable,
                isStale: store.meterStreamIsStale,
                decibels: channel.decibels,
                channelName: channel.displayName
            )
            .frame(width: 34, height: 180)
            Text(channel.decibels > -120 ? "\(channel.decibels.formatted(.number.precision(.fractionLength(1)))) dB" : "−∞ dB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: volumeBinding(channel), in: 0...1) { editing in
                if editing {
                    store.beginVolumeInteraction(channelId: channel.id)
                } else {
                    let level = store.channel(for: channel.id)?.volume ?? channel.volume
                    Task { await store.commitVolumeInteraction(channelId: channel.id, value: level) }
                }
            }
            .tint(DesignToken.Color.accent)
            Text(channel.volume, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
            Button {
                Task { await store.toggleMute(channelId: channel.id) }
            } label: {
                Label(channel.isMuted ? "Muted" : "Mute", systemImage: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(channel.isMuted ? DesignToken.Color.destructive : DesignToken.Color.accent)
            .disabled(!store.controlsAreAvailable)
            .accessibilityLabel("\(channel.displayName) \(channel.isMuted ? "muted" : "not muted")")
        }
        .padding()
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.card)
    }

    private func volumeBinding(_ channel: GoXLRChannelState) -> Binding<Double> {
        Binding(
            get: { store.channel(for: channel.id)?.volume ?? channel.volume },
            set: { store.updateVolumeDraft(channelId: channel.id, value: $0) }
        )
    }
}

struct GoXLREndpointMappingView: View {
    @Environment(\.dismiss) private var dismiss
    let store: GoXLRStore

    var body: some View {
        NavigationStack {
            Form {
                if store.isLoadingMappings { ProgressView("Loading Windows audio endpoints…") }
                ForEach(store.mappings) { mapping in
                    Section(mapping.name) {
                        Picker("Windows endpoint", selection: mappingBinding(mapping)) {
                            Text("Not mapped").tag(Optional<String>.none)
                            ForEach(store.endpoints.filter(\.available)) { endpoint in
                                Text("\(endpoint.name) · \(endpoint.kindTitle)").tag(Optional(endpoint.id))
                            }
                        }
                        if !mapping.endpointAvailable, mapping.endpointId != nil {
                            Label("The mapped endpoint is no longer available.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(DesignToken.Color.destructive)
                        }
                        if let suggestion = suggestedEndpoint(for: mapping) {
                            Button("Use suggested: \(suggestion.name)") {
                                Task { await store.updateChannelMapping(channelId: mapping.id, endpointId: suggestion.id) }
                            }
                        }
                    }
                }
                if let error = store.mappingError {
                    Section("Mapping Error") { Text(error).foregroundStyle(DesignToken.Color.destructive) }
                }
            }
            .navigationTitle("Endpoint Mapping")
            .toolbar { Button("Done") { dismiss() } }
            .task { await store.loadAvailableEndpoints() }
        }
    }

    private func mappingBinding(_ mapping: GoXLRAudioChannelMapping) -> Binding<String?> {
        Binding(
            get: { store.mappings.first(where: { $0.id == mapping.id })?.endpointId },
            set: { endpointID in Task { await store.updateChannelMapping(channelId: mapping.id, endpointId: endpointID) } }
        )
    }

    private func suggestedEndpoint(for mapping: GoXLRAudioChannelMapping) -> WindowsAudioEndpoint? {
        if let id = mapping.suggestedEndpointId { return store.endpoints.first { $0.id == id } }
        return store.endpoints.first { $0.suggestedChannelIds?.contains(mapping.id) == true }
    }
}

#Preview("GoXLR levels") {
    let store = GoXLRStore()
    store.loadPreviewChannels()
    return GoXLRMixerView(store: store)
}
