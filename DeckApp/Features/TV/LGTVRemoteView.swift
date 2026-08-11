import SwiftUI

struct LGTVRemoteView: View {
    @Environment(AppState.self) private var appState
    var embedded = false
    @State private var showSetup = false
    @AppStorage("lgTV.navigationMode.v2") private var navigationMode = LGTVNavigationMode.touchpad
    @State private var selectedTab = LGTVExpandedTab.remote
    @State private var isTouchpadActive = false

    var body: some View {
        GeometryReader { proxy in
            if let device = appState.lgTV.selectedDevice {
                VStack(spacing: DesignToken.Spacing.small) {
                    remoteHeader

                    if selectedTab == .remote {
                        remoteContent(
                            device: device,
                            wide: proxy.size.width >= 720
                        )
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        appsContent
                    }
                }
                .padding()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            } else {
                ContentUnavailableView {
                    Label("Add an LG TV", systemImage: "tv.badge.wifi")
                } description: {
                    Text("Discover a webOS TV on this network or enter its local address.")
                } actions: {
                    Button("Set Up TV") { showSetup = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .background { if !embedded { AppBackground() } }
        .interactiveDismissDisabled(isTouchpadActive)
        .sheet(isPresented: $showSetup) { LGTVDeviceSetupView() }
        .task {
            if appState.lgTV.canAutomaticallyConnectSelectedDevice,
               !appState.lgTV.connectionState.isConnected {
                await appState.lgTV.connect()
            }
        }
    }

    private var remoteHeader: some View {
        HStack(spacing: DesignToken.Spacing.small) {
            statusPill

            Picker("TV remote section", selection: $selectedTab) {
                Label("Remote", systemImage: "remote.fill").tag(LGTVExpandedTab.remote)
                Label("Apps", systemImage: "square.grid.2x2.fill").tag(LGTVExpandedTab.apps)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .layoutPriority(1)
            .onChange(of: selectedTab) { _, _ in RemoteHaptics.heavy() }

            if appState.lgTV.devices.count > 1 {
                Menu {
                    ForEach(appState.lgTV.devices) { device in
                        Button(device.name) { appState.lgTV.select(device.id) }
                    }
                } label: {
                    Image(systemName: "tv.and.hifispeaker.fill")
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Select TV")
            }

            Button { showSetup = true } label: {
                Image(systemName: "gearshape")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("TV settings")
        }
    }

    @ViewBuilder
    private func remoteContent(device: LGTVDevice, wide: Bool) -> some View {
        VStack(spacing: DesignToken.Spacing.medium) {
            DashboardCard {
                HStack(spacing: DesignToken.Spacing.medium) {
                    GlassIcon(symbol: "tv.fill", tint: .purple, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.title3.bold())
                        Text(device.modelName ?? device.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        RemoteHaptics.heavy()
                        Task { await appState.lgTV.powerToggle() }
                    } label: {
                        Label(appState.lgTV.connectionState.isConnected ? "Off" : "Wake", systemImage: "power")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(
                        .interactive,
                        cornerRadius: 999,
                        tint: appState.lgTV.connectionState.isConnected ? .red.opacity(0.18) : .green.opacity(0.18),
                        interactive: true
                    )
                }
            }

            if wide {
                HStack(alignment: .top, spacing: DesignToken.Spacing.medium) {
                    navigationCard(minimumTouchSurfaceHeight: 270)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlsCard.frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                navigationCard(minimumTouchSurfaceHeight: 205)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                controlsCard.fixedSize(horizontal: false, vertical: true)
            }

            if let error = appState.lgTV.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignToken.Color.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func navigationCard(minimumTouchSurfaceHeight: CGFloat) -> some View {
        DashboardCard {
            HStack {
                Text("Remote").font(.headline)
                Spacer()
                Picker("Navigation style", selection: $navigationMode) {
                    Label("Touch", systemImage: "hand.draw.fill").tag(LGTVNavigationMode.touchpad)
                    Label("Buttons", systemImage: "circle.grid.cross.fill").tag(LGTVNavigationMode.buttons)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                .onChange(of: navigationMode) { _, _ in RemoteHaptics.heavy() }
            }

            Group {
                if navigationMode == .touchpad {
                    LGTVTouchNavigationSurface(
                        send: { button in
                            Task { await appState.lgTV.send(button) }
                        },
                        onActiveChanged: { isTouchpadActive = $0 }
                    )
                } else {
                    LGDirectionalPad { button in
                        Task { await appState.lgTV.send(button) }
                    }
                }
            }
            .frame(minHeight: minimumTouchSurfaceHeight, maxHeight: .infinity)

            HStack(spacing: DesignToken.Spacing.small) {
                remoteButton("Back", symbol: "arrow.uturn.backward", button: .back)
                remoteButton("Home", symbol: "house.fill", button: .home)
                remoteButton("Menu", symbol: "line.3.horizontal", button: .menu)
            }
        }
    }

    private var controlsCard: some View {
        DashboardCard {
            HStack {
                Text("Sound & Playback").font(.headline)
                Spacer()
                Text("\(appState.lgTV.tvState.volume)%").font(.headline.monospacedDigit())
            }
            HStack(spacing: DesignToken.Spacing.small) {
                actionButton("Vol −", symbol: "speaker.minus") { await appState.lgTV.volumeDown() }
                actionButton(appState.lgTV.tvState.isMuted ? "Unmute" : "Mute", symbol: appState.lgTV.tvState.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill") { await appState.lgTV.toggleMute() }
                actionButton("Vol +", symbol: "speaker.plus") { await appState.lgTV.volumeUp() }
            }
            Slider(
                value: Binding(
                    get: { Double(appState.lgTV.tvState.volume) },
                    set: { appState.lgTV.tvState.volume = Int($0.rounded()) }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { Task { await appState.lgTV.setVolume(appState.lgTV.tvState.volume) } }
                }
            )

            if let brightness = appState.lgTV.tvState.brightness {
                HStack {
                    Label("Brightness", systemImage: "sun.max.fill").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(brightness)%").font(.headline.monospacedDigit())
                }
                Slider(
                    value: Binding(
                        get: { Double(brightness) },
                        set: { appState.lgTV.tvState.brightness = Int($0.rounded()) }
                    ),
                    in: 0...100,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { Task { await appState.lgTV.setBrightness(appState.lgTV.tvState.brightness ?? brightness) } }
                    }
                )
                .tint(.orange)
            }

            HStack(spacing: DesignToken.Spacing.small) {
                playbackButton("backward.fill", .rewind)
                playbackButton("play.fill", .play)
                playbackButton("pause.fill", .pause)
                playbackButton("forward.fill", .fastForward)
            }
        }
    }

    private var appsContent: some View {
        ScrollView {
            VStack(spacing: DesignToken.Spacing.medium) {
                if !appState.lgTV.tvState.inputs.isEmpty { inputCard }
                if !appState.lgTV.tvState.applications.isEmpty { applicationCard }
                if appState.lgTV.tvState.inputs.isEmpty, appState.lgTV.tvState.applications.isEmpty {
                    ContentUnavailableView(
                        "No TV Apps Available",
                        systemImage: "square.grid.2x2",
                        description: Text("Connect to the TV to load its Home launcher and inputs.")
                    )
                }
                if let error = appState.lgTV.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignToken.Color.destructive)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var inputCard: some View {
        DashboardCard {
            Text("Inputs").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: DesignToken.Spacing.small) {
                    ForEach(appState.lgTV.tvState.inputs) { input in
                        Button {
                            RemoteHaptics.heavy()
                            Task { await appState.lgTV.switchInput(input.id) }
                        } label: {
                            Label(input.name, systemImage: input.id.localizedCaseInsensitiveContains("hdmi") ? "cable.connector" : "rectangle.connected.to.line.below")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: appState.lgTV.tvState.currentInputID == input.id ? Color.purple.opacity(0.28) : nil, interactive: true)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var applicationCard: some View {
        DashboardCard {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Text("TV Home launcher").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: DesignToken.Spacing.small) {
                ForEach(appState.lgTV.tvState.applications) { application in
                    Button {
                        RemoteHaptics.heavy()
                        Task { await appState.lgTV.launchApplication(application.id) }
                    } label: {
                        VStack(spacing: 8) {
                            AsyncImage(url: application.iconURL) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "app.fill").font(.title2) }
                                .frame(width: 42, height: 42)
                            Text(application.name).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .frame(width: 92).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, interactive: true)
                }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(appState.lgTV.connectionState.title).font(.caption.weight(.semibold))
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TV connection: \(appState.lgTV.connectionState.title)")
    }

    private var statusColor: Color {
        switch appState.lgTV.connectionState {
        case .connected: DesignToken.Color.positive
        case .connecting, .discovering, .reconnecting, .awaitingPairing: .orange
        default: DesignToken.Color.destructive
        }
    }

    private func remoteButton(_ title: String, symbol: String, button: LGTVRemoteButton) -> some View {
        RemoteKeyButton(title: title, symbol: symbol, enabled: true) {
            RemoteHaptics.heavy()
            Task { await appState.lgTV.send(button) }
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () async -> Void) -> some View {
        RemoteKeyButton(title: title, symbol: symbol, enabled: true) {
            RemoteHaptics.heavy()
            Task { await action() }
        }
    }

    private func playbackButton(_ symbol: String, _ command: LGTVPlaybackCommand) -> some View {
        Button {
            RemoteHaptics.heavy()
            Task { await appState.lgTV.playback(command) }
        } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity).padding(.vertical, 11)
        }.buttonStyle(.plain).glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, interactive: true)
    }
}

private enum LGTVNavigationMode: String {
    case touchpad
    case buttons
}

private enum LGTVExpandedTab: String {
    case remote
    case apps
}

struct LGTVTouchNavigationSurface: View {
    let send: (LGTVRemoteButton) -> Void
    var onActiveChanged: (Bool) -> Void = { _ in }
    @State private var translation: CGSize = .zero
    @State private var repeatingDirection: LGTVRemoteButton?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(DesignToken.Color.card.opacity(0.72))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)

                VStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.title2)
                    Text("Swipe to navigate")
                        .font(.subheadline.weight(.semibold))
                    Text("Tap to select")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)

                Circle()
                    .fill(.white.opacity(translation == .zero ? 0 : 0.2))
                    .frame(width: 54, height: 54)
                    .offset(
                        x: min(max(translation.width * 0.28, -42), 42),
                        y: min(max(translation.height * 0.28, -42), 42)
                    )
                    .animation(.snappy(duration: 0.18), value: translation)
            }
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .local)
                    .onChanged { value in
                        translation = value.translation
                        let direction = direction(for: value.translation)
                        if direction != repeatingDirection { beginRepeating(direction) }
                    }
                    .onEnded { _ in
                        translation = .zero
                        stopRepeating()
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    send(.enter)
                    RemoteHaptics.heavy()
                }
            )
            // Tracks touch-down/up independently of the 18pt drag threshold above so the
            // enclosing sheet's interactive-dismiss swipe is suppressed from the first touch,
            // not only once a real drag starts.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in onActiveChanged(true) }
                    .onEnded { _ in onActiveChanged(false) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("TV navigation touchpad")
            .accessibilityHint("Swipe to navigate or double tap to select")
            .accessibilityAction(named: "Select") { send(.enter) }
            .onDisappear { stopRepeating() }
        }
    }

    private func direction(for translation: CGSize) -> LGTVRemoteButton {
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
    }

    private func beginRepeating(_ direction: LGTVRemoteButton) {
        stopRepeating()
        repeatingDirection = direction
        send(direction)
        RemoteHaptics.heavy()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                send(direction)
                RemoteHaptics.heavy()
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatingDirection = nil
    }
}

struct LGDirectionalPad: View {
    let send: (LGTVRemoteButton) -> Void

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow { spacer; key("chevron.up", .up); spacer }
            GridRow { key("chevron.left", .left); key("circle.inset.filled", .enter); key("chevron.right", .right) }
            GridRow { spacer; key("chevron.down", .down); spacer }
        }
        .frame(maxWidth: .infinity)
    }

    private var spacer: some View { Color.clear.frame(width: 54, height: 48) }
    private func key(_ symbol: String, _ button: LGTVRemoteButton) -> some View {
        Button { send(button); RemoteHaptics.heavy() } label: {
            Image(systemName: symbol).font(.title3.bold()).frame(width: 54, height: 48)
        }.buttonStyle(.plain).glassSurface(.interactive, cornerRadius: 16, tint: button == .enter ? Color.purple.opacity(0.2) : nil, interactive: true)
    }
}

struct LGTVDeviceSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "LG webOS TV"
    @State private var host = ""
    @State private var macAddress = ""
    @State private var secure = false
    @State private var editingDevice: LGTVDevice?
    @State private var showForgetPairingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { Task { await appState.lgTV.discover() } } label: {
                        Label("Discover TVs", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if appState.lgTV.connectionState == .discovering { ProgressView("Searching the local network…") }
                    if let message = appState.lgTV.discoveryMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(appState.lgTV.discoveredDevices) { device in
                        Button { appState.lgTV.addDiscovered(device) } label: {
                            LabeledContent(device.name, value: device.host)
                        }.buttonStyle(.plain)
                    }
                } header: { Text("Nearby TVs") }
                  footer: { Text("The iPhone or iPad and TV must be on the same local network. Discovery can fail on guest Wi‑Fi or networks with client isolation, so manual IP always remains available.") }

                Section("Manual TV") {
                    TextField("Name", text: $name)
                    TextField("Local IP or hostname", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("MAC address (optional, for power on)", text: $macAddress).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Toggle("Use secure webOS port 3001", isOn: $secure)
                    Button("Add and Pair") {
                        if let device = appState.lgTV.addManual(name: name, host: host, macAddress: macAddress, secure: secure) {
                            appState.lgTV.select(device.id)
                        }
                    }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !appState.lgTV.devices.isEmpty {
                    Section("Saved TVs") {
                        ForEach(appState.lgTV.devices) { device in
                            HStack {
                                Button { appState.lgTV.select(device.id) } label: {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text(device.host).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                                Spacer()
                                if appState.lgTV.selectedDeviceID == device.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple) }
                                Button { editingDevice = device } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                                Button(role: .destructive) { appState.lgTV.remove(device.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Pairing") {
                    LabeledContent("Status", value: appState.lgTV.connectionState.title)
                    LabeledContent("Saved approval", value: appState.lgTV.canAutomaticallyConnectSelectedDevice ? "Yes" : "No")
                    if appState.lgTV.connectionState == .awaitingPairing {
                        Label("Accept the DeckApp prompt displayed on your TV.", systemImage: "tv.badge.checkmark")
                            .foregroundStyle(.orange)
                    }
                    if let cooldown = appState.lgTV.pairingCooldownUntil, cooldown > .now {
                        Label {
                            Text("Pairing temporarily limited. Try again in ") + Text(cooldown, style: .timer)
                        } icon: {
                            Image(systemName: "hourglass")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    if let error = appState.lgTV.lastError { Text(error).font(.caption).foregroundStyle(DesignToken.Color.destructive) }
                    Button("Connect Selected TV") { Task { await appState.lgTV.connect() } }
                        .disabled(
                            appState.lgTV.selectedDevice == nil
                                || appState.lgTV.isConnectionAttemptInProgress
                                || appState.lgTV.isPairingCoolingDown
                        )
                    Button("Forget Pairing", role: .destructive) { showForgetPairingConfirmation = true }
                        .disabled(!appState.lgTV.canAutomaticallyConnectSelectedDevice)
                }
            }
            .navigationTitle("LG TV Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editingDevice) { device in
                LGTVDeviceEditorView(device: device)
            }
            .confirmationDialog(
                "Forget this TV pairing?",
                isPresented: $showForgetPairingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Forget Pairing", role: .destructive) { appState.lgTV.forgetPairing() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("DeckApp will need approval from the TV again the next time it connects.")
            }
        }
    }
}

private struct LGTVDeviceEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var device: LGTVDevice

    init(device: LGTVDevice) { _device = State(initialValue: device) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $device.name)
                TextField("Local IP or hostname", text: $device.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("MAC address", text: Binding(
                    get: { device.macAddress ?? "" },
                    set: { device.macAddress = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Toggle("Use secure webOS port 3001", isOn: $device.useSecureConnection)
            }
            .navigationTitle("Edit TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        device.host = device.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.lgTV.update(device)
                        dismiss()
                    }
                    .disabled(device.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#if DEBUG
private struct LGTVPreviewPersistence: LGTVDevicePersisting {
    let device: LGTVDevice
    func loadDevices() -> [LGTVDevice] { [device] }
    func saveDevices(_ devices: [LGTVDevice]) {}
    func loadSelectedDeviceID() -> UUID? { device.id }
    func saveSelectedDeviceID(_ id: UUID?) {}
}

@MainActor
private func lgTVPreviewState(_ connection: LGTVConnectionState) -> AppState {
    let device = LGTVDevice(name: "Living Room TV", host: "192.168.1.24", modelName: "LG OLED C4", macAddress: "AA:BB:CC:DD:EE:FF")
    let store = LGTVStore(persistence: LGTVPreviewPersistence(device: device))
    store.connectionState = connection
    store.tvState = LGTVState(
        isOn: connection.isConnected,
        volume: 34,
        isMuted: false,
        currentInputID: "HDMI_1",
        foregroundApplicationID: "netflix",
        foregroundApplicationName: "Netflix",
        inputs: [LGTVInput(id: "HDMI_1", name: "HDMI 1"), LGTVInput(id: "HDMI_2", name: "Game Console")],
        applications: [LGTVApplication(id: "netflix", name: "Netflix"), LGTVApplication(id: "youtube.leanback.v4", name: "YouTube")],
        lastUpdated: .now
    )
    if case .unavailable(let message) = connection { store.lastError = message }
    return AppState(lgTV: store)
}

#Preview("LG TV · Live") {
    LGTVRemoteView().environment(lgTVPreviewState(.connected))
}

#Preview("LG TV · Pairing") {
    LGTVRemoteView().environment(lgTVPreviewState(.awaitingPairing))
}

#Preview("LG TV · Disconnected") {
    LGTVRemoteView().environment(lgTVPreviewState(.disconnected))
}

#Preview("LG TV · Error") {
    LGTVRemoteView().environment(lgTVPreviewState(.unavailable("The television could not be reached.")))
}
#endif
