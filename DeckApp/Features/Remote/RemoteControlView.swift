import SwiftUI
import UIKit

struct RemoteControlView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showClipboardActions = false
    @State private var showFullScreenTouchpad = false

    private var remote: RemoteInputController { appState.remoteInput }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 720

            VStack(spacing: DesignToken.Spacing.medium) {
                header
                modeSelector
                shortcutStrip

                Group {
                    switch remote.selectedMode {
                    case .touchpad:
                        touchpadMode(compact: compact)
                    case .keyboard:
                        RemoteKeyboardPanel(remote: remote)
                    case .media:
                        RemoteMediaPanel(remote: remote)
                    case .shortcuts:
                        RemoteShortcutsPanel(remote: remote)
                    }
                }
                .opacity(remote.selectedMode == .media || remote.connectionState.acceptsInput ? 1 : 0.52)
            }
            .padding(compact ? DesignToken.Spacing.medium : DesignToken.Spacing.large)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .sheet(isPresented: $showSettings) {
            RemoteInputSettingsView(remote: remote)
        }
        .fullScreenCover(isPresented: $showFullScreenTouchpad) {
            FullScreenRemoteTouchpad(remote: remote)
        }
        .confirmationDialog("Send clipboard text to the PC?", isPresented: $showClipboardActions, titleVisibility: .visible) {
            Button("Send Clipboard Text") { sendClipboard(pasteAfterCopy: false) }
            Button("Send and Paste") { sendClipboard(pasteAfterCopy: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clipboard is read only after you choose an action. Its contents are not stored or logged.")
        }
        .task { await remote.refreshAgentSecurityState() }
    }

    private var header: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PC Remote")
                    .font(.title2.bold())
                HStack(spacing: DesignToken.Spacing.xSmall) {
                    Circle().fill(connectionColor).frame(width: 8, height: 8)
                    Text(remote.connectionState.title)
                    if let latency = remote.connectionState.latencyMilliseconds {
                        Text("· \(latency) ms")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(connectionColor)
            }
            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .glassSurface(.interactive, cornerRadius: 999, interactive: true)

            if remote.connectionState.acceptsInput || remote.connectionState == .connecting {
                Button("Disconnect", role: .destructive) {
                    Task { await remote.disconnect() }
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    if remote.pairingState.isPaired {
                        Task { await remote.connect() }
                    } else {
                        showSettings = true
                    }
                } label: {
                    Label(remote.pairingState.isPaired ? "Connect" : "Pair", systemImage: remote.pairingState.isPaired ? "link" : "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var modeSelector: some View {
        Picker("Remote mode", selection: Bindable(remote).selectedMode) {
            ForEach(RemoteControlMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(DesignToken.Spacing.xSmall)
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control)
    }

    private var shortcutStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignToken.Spacing.small) {
                ForEach(remote.preferences.shortcutRow, id: \.self) { key in
                    RemoteKeyButton(title: key.displayTitle, symbol: key.displaySymbol, enabled: remote.connectionState.acceptsInput) {
                        remote.sendKey(key)
                    }
                }
                RemoteKeyButton(title: "Keyboard", symbol: "keyboard", enabled: true) {
                    remote.selectedMode = .keyboard
                }
                RemoteKeyButton(title: "Media", symbol: "playpause", enabled: true) {
                    remote.selectedMode = .media
                }
                RemoteKeyButton(title: "Desktop", symbol: "macwindow", enabled: remote.connectionState.acceptsInput) {
                    remote.sendKey(.desktop)
                }
                RemoteKeyButton(title: "Clipboard", symbol: "doc.on.clipboard", enabled: remote.connectionState.acceptsInput) {
                    showClipboardActions = true
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func touchpadMode(compact: Bool) -> some View {
        VStack(spacing: DesignToken.Spacing.small) {
            HStack {
                Label(remote.lastInteraction, systemImage: remote.isDragging ? "hand.draw.fill" : "cursorarrow.motionlines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if remote.preferences.precisionMode {
                    Text("PRECISION")
                        .font(.caption2.bold())
                        .foregroundStyle(DesignToken.Color.cyan)
                }
                Button {
                    showFullScreenTouchpad = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignToken.Color.accent)
            }

            RemoteTouchpadPanel(remote: remote)
                .frame(maxHeight: .infinity)
        }
    }

    private var connectionColor: Color {
        switch remote.connectionState {
        case .connected: DesignToken.Color.positive
        case .highLatency: DesignToken.Color.warning
        case .connecting: DesignToken.Color.cyan
        case .permissionDisabled, .emergencyDisabled, .authenticationRejected, .unavailable: DesignToken.Color.destructive
        case .disconnected: .secondary
        }
    }

    private func sendClipboard(pasteAfterCopy: Bool) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        remote.sendClipboardText(text, pasteAfterCopy: pasteAfterCopy, userInitiated: true)
        RemoteHaptics.click()
    }
}

private struct RemoteTouchpadPanel: View {
    let remote: RemoteInputController

    var body: some View {
        VStack(spacing: DesignToken.Spacing.small) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                    .fill(DesignToken.Color.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                            .strokeBorder(remote.isDragging ? DesignToken.Color.accent.opacity(0.7) : DesignToken.Color.cardBorder, lineWidth: remote.isDragging ? 1.5 : 0.75)
                    }

                VStack(spacing: DesignToken.Spacing.small) {
                    Image(systemName: remote.isDragging ? "hand.draw.fill" : "hand.point.up.left")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary.opacity(0.45))
                    Text(remote.isDragging ? "Dragging" : "Touchpad")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tap to click · Two fingers to scroll · Hold to drag")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .allowsHitTesting(false)

                RemoteTouchpadSurface(
                    pointerMoved: remote.enqueuePointer,
                    scrolled: remote.enqueueScroll,
                    tapped: {
                        remote.click(.left)
                        RemoteHaptics.click()
                    },
                    twoFingerTapped: {
                        guard remote.preferences.twoFingerRightClick else { return }
                        remote.click(.right)
                        RemoteHaptics.click()
                    },
                    dragChanged: { active in
                        remote.setDrag(active: active)
                        RemoteHaptics.click()
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous))
            }
            .frame(minHeight: 260)

            HStack(spacing: DesignToken.Spacing.small) {
                RemoteKeyButton(title: "Left Click", symbol: "cursorarrow.click", enabled: remote.connectionState.acceptsInput) {
                    remote.click(.left)
                    RemoteHaptics.click()
                }
                RemoteKeyButton(title: "Right Click", symbol: "contextualmenu.and.cursorarrow", enabled: remote.connectionState.acceptsInput) {
                    remote.click(.right)
                    RemoteHaptics.click()
                }
            }
        }
    }
}

private struct RemoteKeyboardPanel: View {
    let remote: RemoteInputController

    var body: some View {
        ScrollView {
            VStack(spacing: DesignToken.Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                        .fill(DesignToken.Color.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                                .strokeBorder(DesignToken.Color.cardBorder)
                        }
                    VStack(spacing: 4) {
                        Image(systemName: "keyboard.fill").font(.title2)
                        Text("Tap to open the native keyboard")
                            .font(.subheadline.weight(.semibold))
                        Text("Arabic and English text is sent without being stored")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                    NativeKeyboardCaptureView(sendText: remote.sendText, sendKey: remote.sendKey)
                }
                .frame(height: 92)

                modifierRow
                specialKeys
                functionKeys
            }
        }
        .scrollIndicators(.hidden)
    }

    private var modifierRow: some View {
        HStack(spacing: DesignToken.Spacing.small) {
            ForEach(RemoteModifiers.allCases, id: \.title) { item in
                Button {
                    remote.toggleModifier(item.modifier)
                    RemoteHaptics.key()
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignToken.Spacing.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(remote.heldState.modifiers.contains(item.modifier) ? DesignToken.Color.accent : .primary)
                .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: remote.heldState.modifiers.contains(item.modifier) ? DesignToken.Color.accent.opacity(0.22) : nil, interactive: true)
            }
        }
    }

    private var specialKeys: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DesignToken.Spacing.small)]) {
            key("Esc", "escape", .escape)
            key("Tab", "arrow.right.to.line", .tab)
            key("Enter", "return", .enter)
            key("Backspace", "delete.backward", .backspace)
            key("Delete", "delete.forward", .delete)
            key("←", "arrow.left", .arrowLeft)
            key("↑", "arrow.up", .arrowUp)
            key("↓", "arrow.down", .arrowDown)
            key("→", "arrow.right", .arrowRight)
        }
    }

    private var functionKeys: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignToken.Spacing.small) {
                ForEach(Array(functionKeyPairs.enumerated()), id: \.offset) { index, keyValue in
                    key("F\(index + 1)", "f.cursive", keyValue)
                        .frame(width: 70)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func key(_ title: String, _ symbol: String, _ value: RemoteVirtualKey) -> some View {
        RemoteKeyButton(title: title, symbol: symbol, enabled: remote.connectionState.acceptsInput) {
            remote.sendKey(value)
            RemoteHaptics.key()
        }
    }

    private var functionKeyPairs: [RemoteVirtualKey] {
        [.function1, .function2, .function3, .function4, .function5, .function6,
         .function7, .function8, .function9, .function10, .function11, .function12]
    }
}

private struct RemoteMediaPanel: View {
    let remote: RemoteInputController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
                if let execution = remote.agentCommandExecution {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(execution.command.title).font(.subheadline.bold())
                            Text(execution.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CommandStatusPill(status: execution.status)
                    }
                    .padding(DesignToken.Spacing.medium)
                    .background(DesignToken.Color.card, in: RoundedRectangle(cornerRadius: DesignToken.Radius.control, style: .continuous))
                }

                mediaKeyControls

                if let snapshot = remote.capabilitySnapshot {
                    agentSection("Applications & Games", symbol: "square.grid.2x2.fill") {
                        ForEach(snapshot.applications) { application in
                            HStack {
                                Label(application.name, systemImage: application.kind == .game ? "gamecontroller.fill" : "app.fill")
                                Spacer()
                                if application.isRunning {
                                    Label("Running", systemImage: "checkmark.circle.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DesignToken.Color.positive)
                                } else {
                                    Button("Launch") {
                                        Task { await remote.launchApplication(id: application.id) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(!remote.pairingState.isPaired)
                                }
                            }
                        }
                    }

                    agentSection("Windows Audio Sessions", symbol: "speaker.wave.2.fill") {
                        ForEach(snapshot.audioSessions) { session in
                            AgentAudioSessionRow(remote: remote, session: session)
                        }
                    }

                    agentSection("GoXLR", symbol: "slider.horizontal.3") {
                        if snapshot.goXLRConnected {
                            ForEach(snapshot.goXLRChannels) { channel in
                                AgentGoXLRChannelRow(remote: remote, channel: channel)
                            }
                        } else {
                            Label("GoXLR unavailable", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Agent Capabilities Unavailable", systemImage: "pc", description: Text("Pair the Windows Agent and refresh Remote Settings."))
                }

                Text(remote.usesMockAgent
                     ? "Mock Agent controls. A command is confirmed only after the Agent reports the expected state; request acceptance alone is never shown as success."
                     : "Media keys use the authenticated input session. Applications, Windows audio sessions, and GoXLR controls use paired HTTPS capability endpoints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, DesignToken.Spacing.medium)
        }
        .scrollIndicators(.hidden)
    }

    private var mediaKeyControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignToken.Spacing.medium) {
                playbackKeys
                Spacer(minLength: 0)
                volumeKeys
            }
            VStack(spacing: DesignToken.Spacing.small) {
                playbackKeys
                volumeKeys
            }
        }
        .padding(.horizontal, 2)
    }

    private var playbackKeys: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            mediaButton("backward.fill", .mediaPrevious)
            mediaButton("playpause.fill", .mediaPlayPause, large: true)
            mediaButton("forward.fill", .mediaNext)
        }
    }

    private var volumeKeys: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            mediaButton("speaker.slash.fill", .volumeMute)
            mediaButton("speaker.minus.fill", .volumeDown)
            mediaButton("speaker.plus.fill", .volumeUp)
        }
    }

    private func agentSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.small) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(DesignToken.Color.accent)
            content()
        }
        .padding(DesignToken.Spacing.medium)
        .background(DesignToken.Color.card, in: RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                .strokeBorder(DesignToken.Color.cardBorder, lineWidth: 0.75)
        }
    }

    private func mediaButton(_ symbol: String, _ key: RemoteVirtualKey, large: Bool = false) -> some View {
        Button {
            remote.sendKey(key)
            RemoteHaptics.key()
        } label: {
            Image(systemName: symbol)
                .font(large ? .largeTitle : .title2)
                .frame(width: large ? 84 : 64, height: large ? 84 : 64)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: 999, tint: DesignToken.Color.accent.opacity(0.16), interactive: true)
        .disabled(!remote.connectionState.acceptsInput)
    }
}

private struct AgentAudioSessionRow: View {
    let remote: RemoteInputController
    let session: WindowsAudioSessionState
    @State private var draftVolume: Double

    init(remote: RemoteInputController, session: WindowsAudioSessionState) {
        self.remote = remote
        self.session = session
        _draftVolume = State(initialValue: session.volume)
    }

    var body: some View {
        VStack(spacing: DesignToken.Spacing.xSmall) {
            HStack {
                Text(session.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(draftVolume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    Task { await remote.setAudioMuted(id: session.id, muted: !session.isMuted) }
                } label: {
                    Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(session.isMuted ? DesignToken.Color.destructive : DesignToken.Color.accent)
                }
                .buttonStyle(.plain)
                .disabled(!remote.pairingState.isPaired)
            }
            Slider(value: $draftVolume, in: 0...1) { editing in
                guard !editing else { return }
                Task { await remote.setAudioVolume(id: session.id, volume: draftVolume) }
            }
            .disabled(!remote.pairingState.isPaired)
        }
        .onChange(of: session.volume) { _, value in draftVolume = value }
    }
}

private struct AgentGoXLRChannelRow: View {
    let remote: RemoteInputController
    let channel: WindowsGoXLRChannelState
    @State private var draftLevel: Double

    init(remote: RemoteInputController, channel: WindowsGoXLRChannelState) {
        self.remote = remote
        self.channel = channel
        _draftLevel = State(initialValue: channel.level)
    }

    var body: some View {
        VStack(spacing: DesignToken.Spacing.xSmall) {
            HStack {
                Text(channel.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(draftLevel, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    Task { await remote.setGoXLRMuted(id: channel.id, muted: !channel.isMuted) }
                } label: {
                    Image(systemName: channel.isMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(channel.isMuted ? DesignToken.Color.destructive : DesignToken.Color.accent)
                }
                .buttonStyle(.plain)
                .disabled(!remote.pairingState.isPaired)
            }
            Slider(value: $draftLevel, in: 0...1) { editing in
                guard !editing else { return }
                Task { await remote.setGoXLRLevel(id: channel.id, level: draftLevel) }
            }
            .disabled(!remote.pairingState.isPaired)
        }
        .onChange(of: channel.level) { _, value in draftLevel = value }
    }
}

private struct RemoteShortcutsPanel: View {
    let remote: RemoteInputController

    private let shortcuts: [(String, String, RemoteVirtualKey)] = [
        ("Copy", "doc.on.doc", .copy),
        ("Paste", "doc.on.clipboard", .paste),
        ("Undo", "arrow.uturn.backward", .undo),
        ("Redo", "arrow.uturn.forward", .redo),
        ("Alt+Tab", "rectangle.on.rectangle", .altTab),
        ("Desktop", "macwindow", .desktop)
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DesignToken.Spacing.medium)]) {
            ForEach(shortcuts, id: \.0) { shortcut in
                RemoteKeyButton(title: shortcut.0, symbol: shortcut.1, enabled: remote.connectionState.acceptsInput) {
                    remote.sendKey(shortcut.2)
                    RemoteHaptics.key()
                }
                .frame(minHeight: 68)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct RemoteInputSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var remote: RemoteInputController
    @State private var showRevokeConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Connection") {
                    Picker("Transport", selection: $remote.usesMockAgent) {
                        Text("Development Mock").tag(true)
                        Text("Windows PC").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if !remote.usesMockAgent {
                        TextField("https://192.168.1.50:8732", text: $remote.windowsAgentAddress)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("HTTPS is required. The certificate must be trusted by this iPhone or iPad and must match the address. TLS validation is never disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label(remote.windowsAgentAddressStatus, systemImage: remote.windowsAgentAddressIsValid ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(remote.windowsAgentAddressIsValid ? DesignToken.Color.positive : DesignToken.Color.destructive)

                    Button("Apply and Refresh") {
                        Task { await remote.applyAgentConfiguration() }
                    }
                    .disabled(!remote.windowsAgentAddressIsValid)
                }
                Section("Pointer") {
                    LabeledContent("Sensitivity", value: remote.preferences.pointerSensitivity.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $remote.preferences.pointerSensitivity, in: 0.3...2.5, step: 0.1)
                    Toggle("Pointer acceleration", isOn: $remote.preferences.pointerAcceleration)
                    Toggle("Precision mode", isOn: $remote.preferences.precisionMode)
                }
                Section("Scrolling") {
                    LabeledContent("Sensitivity", value: remote.preferences.scrollSensitivity.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $remote.preferences.scrollSensitivity, in: 0.3...2.5, step: 0.1)
                    Toggle("Natural scrolling", isOn: $remote.preferences.naturalScrolling)
                    Toggle("Two-finger right-click", isOn: $remote.preferences.twoFingerRightClick)
                }
                Section("Shortcut Strip") {
                    ForEach(shortcutCandidates, id: \.self) { key in
                        Toggle(key.displayTitle, isOn: shortcutBinding(for: key))
                    }
                    Text("Enabled shortcuts appear in the floating strip on every Remote mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Security") {
                    LabeledContent("Pairing") {
                        Text(remote.pairingState.title)
                            .foregroundStyle(remote.pairingState.isPaired ? DesignToken.Color.positive : .secondary)
                    }
                    LabeledContent("Allow Remote Input") {
                        Text(remote.securityState.remoteInputAllowed ? "Allowed on PC" : "Disabled on PC")
                            .foregroundStyle(remote.securityState.remoteInputAllowed ? DesignToken.Color.positive : DesignToken.Color.destructive)
                    }
                    LabeledContent("Input injection") {
                        Text(remote.securityState.inputInjectionAvailable ? "Available" : "Unavailable")
                            .foregroundStyle(remote.securityState.inputInjectionAvailable ? DesignToken.Color.positive : DesignToken.Color.destructive)
                    }
                    LabeledContent("Emergency disable") {
                        Text(remote.securityState.emergencyInputDisabled ? "Active on PC" : "Inactive")
                            .foregroundStyle(remote.securityState.emergencyInputDisabled ? DesignToken.Color.destructive : DesignToken.Color.positive)
                    }

                    if case .pairing = remote.pairingState {
                        TextField("Six-digit pairing code", text: $remote.pairingCode)
                            .keyboardType(.numberPad)
                        Button("Confirm Pairing") { Task { await remote.confirmPairing() } }
                            .disabled(remote.pairingCode.count != 6)
                    } else if remote.pairingState.isPaired {
                        Button("Revoke This iPad", role: .destructive) { showRevokeConfirmation = true }
                    } else {
                        Button("Begin Pairing") { Task { await remote.beginPairing() } }
                    }

                    if !remote.pairingMessage.isEmpty {
                        Text(remote.pairingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Allow Remote Input and Emergency Disable are controlled only on the Windows PC; this app cannot override them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Remote input never uses Companion or Home Assistant and must remain on a LAN, private VPN, or authenticated secure relay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(remote.usesMockAgent ? "Mock Agent Capability Preview" : "Windows Agent Capabilities") {
                    if let snapshot = remote.capabilitySnapshot {
                        LabeledContent("Applications and games", value: "\(snapshot.applications.count)")
                        ForEach(snapshot.applications) { application in
                            Label {
                                HStack {
                                    Text(application.name)
                                    Spacer()
                                    Text(application.isRunning ? "Running" : "Available")
                                        .foregroundStyle(application.isRunning ? DesignToken.Color.positive : .secondary)
                                }
                            } icon: {
                                Image(systemName: application.kind == .game ? "gamecontroller.fill" : "app.fill")
                                    .foregroundStyle(DesignToken.Color.accent)
                            }
                        }

                        LabeledContent("Windows audio sessions", value: "\(snapshot.audioSessions.count)")
                        LabeledContent("GoXLR") {
                            Text(snapshot.goXLRConnected ? "Connected · \(snapshot.goXLRChannels.count) channels" : "Disconnected")
                                .foregroundStyle(snapshot.goXLRConnected ? DesignToken.Color.positive : .secondary)
                        }
                    } else {
                        LabeledContent("Agent capabilities", value: "Unavailable")
                    }

                    Text(remote.usesMockAgent
                         ? "Development-only sample data. These capabilities define the authenticated Windows Agent contract; they do not control the PC yet."
                         : "The real Agent provides keyboard and pointer input plus paired application, Windows audio-session, and GoXLR capability endpoints.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remote Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { remote.savePreferences() }
            .task { await remote.refreshAgentSecurityState() }
            .confirmationDialog("Revoke this iPad?", isPresented: $showRevokeConfirmation, titleVisibility: .visible) {
                Button("Revoke Pairing", role: .destructive) { Task { await remote.revokePairing() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remote input will disconnect immediately and the Keychain pairing credential will be deleted.")
            }
        }
    }

    private var shortcutCandidates: [RemoteVirtualKey] {
        [.escape, .altTab, .desktop, .copy, .paste, .undo, .redo]
    }

    private func shortcutBinding(for key: RemoteVirtualKey) -> Binding<Bool> {
        Binding {
            remote.preferences.shortcutRow.contains(key)
        } set: { enabled in
            if enabled, !remote.preferences.shortcutRow.contains(key) {
                remote.preferences.shortcutRow.append(key)
            } else if !enabled {
                remote.preferences.shortcutRow.removeAll { $0 == key }
            }
        }
    }
}

private struct FullScreenRemoteTouchpad: View {
    @Environment(\.dismiss) private var dismiss
    let remote: RemoteInputController

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackground()
            RemoteTouchpadPanel(remote: remote)
                .padding()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .glassSurface(.elevated, cornerRadius: 999)
            .padding()
        }
    }
}

struct RemoteKeyButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DesignToken.Spacing.small)
                .padding(.vertical, DesignToken.Spacing.small)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.accent.opacity(0.1), interactive: true)
        .disabled(!enabled)
    }
}

enum RemoteHaptics {
    static func click() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func key() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

#Preview("Remote · iPhone") {
    ZStack {
        AppBackground()
        RemoteControlView()
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
    .frame(width: 390, height: 844)
}

#Preview("Remote · iPad Landscape") {
    ZStack {
        AppBackground()
        RemoteControlView()
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
    .frame(width: 1120, height: 760)
}
