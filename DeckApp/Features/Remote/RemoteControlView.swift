import SwiftUI
import UIKit

enum RemoteTarget: String {
    case pc
    case tv
}

/// The PC extra panel now lives in `RemoteControlMode` (Models/RemoteInputModels.swift).
/// The TV side gets its own small set here since it has no PC equivalent to share with.
private enum TVExtraPanel: String, CaseIterable, Identifiable {
    case apps
    case inputs
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .inputs: "Inputs"
        case .display: "Display"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2.fill"
        case .inputs: "cable.connector"
        case .display: "sun.max.fill"
        }
    }
}

/// One remote screen for both the PC and the TV. `target` decides which device the
/// touchpad, media row, and shortcut strip currently drive; it's kept in sync with
/// whatever the TV actually reports (`RemoteModeResolver`) but can be overridden by hand.
struct RemoteControlView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("remote.target.v1") private var target = RemoteTarget.pc
    @State private var lastAutoDecisionKey: String?
    @State private var showSettings = false
    @State private var showTVSetup = false
    @State private var showClipboardActions = false
    @State private var showFullScreenTouchpad = false
    @State private var tvExtraPanel = TVExtraPanel.apps
    @State private var isTouchpadDragging = false
    @State private var isTouchpadActive = false

    private var remote: RemoteInputController { appState.remoteInput }
    private var tv: LGTVStore { appState.lgTV }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignToken.Spacing.medium) {
                header

                if target == .tv, tv.selectedDevice == nil {
                    ContentUnavailableView {
                        Label("Add an LG TV", systemImage: "tv.badge.wifi")
                    } description: {
                        Text("Discover a webOS TV on this network or enter its local address.")
                    } actions: {
                        Button("Set Up TV") { showTVSetup = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, DesignToken.Spacing.large)
                } else {
                    touchpad
                    mediaRow
                    shortcutStrip
                    extraPanelPicker
                    extraPanelContent
                }
            }
            .padding(DesignToken.Spacing.medium)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(isTouchpadActive)
        .sheet(isPresented: $showSettings) {
            RemoteInputSettingsView(remote: remote)
        }
        .sheet(isPresented: $showTVSetup) {
            LGTVDeviceSetupView()
        }
        .fullScreenCover(isPresented: $showFullScreenTouchpad) {
            FullScreenRemoteTouchpad(target: target, remote: remote, tv: tv)
        }
        .confirmationDialog("Send clipboard text to the PC?", isPresented: $showClipboardActions, titleVisibility: .visible) {
            Button("Send Clipboard Text") { sendClipboard(pasteAfterCopy: false) }
            Button("Send and Paste") { sendClipboard(pasteAfterCopy: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clipboard is read only after you choose an action. Its contents are not stored or logged.")
        }
        .task {
            await remote.autoConnectIfNeeded()
            if tv.canAutomaticallyConnectSelectedDevice, !tv.connectionState.isConnected {
                await tv.connect()
            }
        }
        .onChange(of: stateChangeKey, initial: true) { _, newKey in
            applyAutoTargetIfNeeded(newKey)
        }
    }

    /// Changes whenever the TV state that determines "what's on screen" changes for
    /// real — a fresh value here re-runs the auto-switch logic. Connection state is
    /// coarsened to connected/not-connected so reconnect-attempt ticks don't count.
    private var stateChangeKey: String {
        "\(appState.lgTV.connectionState.isConnected)|\(appState.lgTV.tvState.currentInputID ?? "-")|\(appState.lgTV.tvState.foregroundApplicationID ?? "-")"
    }

    private func applyAutoTargetIfNeeded(_ newKey: String) {
        guard newKey != lastAutoDecisionKey else { return }
        lastAutoDecisionKey = newKey
        if let auto = RemoteModeResolver.autoTarget(
            tvState: appState.lgTV.tvState,
            connectionState: appState.lgTV.connectionState,
            pcTVInputID: appState.pcTVInputID
        ) {
            target = auto
        }
    }

    private var header: some View {
        RemoteHeaderBar(
            title: target == .pc ? "PC Remote" : "TV Remote",
            statusColor: target == .pc ? pcStatusColor : tvStatusColor,
            statusText: target == .pc ? remote.connectionState.title : tv.connectionState.title,
            statusDetail: target == .pc ? remote.connectionState.latencyMilliseconds.map { "\($0) ms" } : nil
        ) {
            HStack(spacing: DesignToken.Spacing.small) {
                // Manual override: switches `target` directly without touching
                // `lastAutoDecisionKey`, so it sticks until the next real TV state change.
                RemoteIconButton(
                    symbol: target == .pc ? "tv" : "desktopcomputer",
                    accessibilityLabel: target == .pc ? "Switch to TV" : "Switch to PC"
                ) {
                    RemoteHaptics.heavy()
                    target = target == .pc ? .tv : .pc
                }

                // A quick way to jump the TV home without leaving the PC remote —
                // otherwise reaching it means switching targets first.
                if target == .pc, tv.selectedDevice != nil {
                    RemoteIconButton(symbol: "house.fill", accessibilityLabel: "TV Home") {
                        RemoteHaptics.heavy()
                        Task { await tv.send(.home) }
                    }
                }

                RemoteIconButton(
                    symbol: target == .pc ? "slider.horizontal.3" : "gearshape",
                    accessibilityLabel: target == .pc ? "Remote settings" : "TV settings"
                ) {
                    if target == .pc { showSettings = true } else { showTVSetup = true }
                }

                connectionButton
            }
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch target {
        case .pc:
            if remote.connectionState.acceptsInput || remote.connectionState == .connecting {
                RemoteIconButton(symbol: "xmark.circle.fill", accessibilityLabel: "Disconnect", tint: DesignToken.Color.destructive) {
                    Task { await remote.disconnect() }
                }
            } else {
                RemoteIconButton(
                    symbol: remote.pairingState.isPaired ? "link" : "checkmark.shield",
                    accessibilityLabel: remote.pairingState.isPaired ? "Connect" : "Pair",
                    tint: DesignToken.Color.accent
                ) {
                    if remote.pairingState.isPaired {
                        Task { await remote.connect() }
                    } else {
                        showSettings = true
                    }
                }
            }
        case .tv:
            RemoteIconButton(
                symbol: "power",
                accessibilityLabel: tv.connectionState.isConnected ? "Turn Off TV" : "Wake TV",
                tint: tv.connectionState.isConnected ? DesignToken.Color.destructive : DesignToken.Color.accent
            ) {
                RemoteHaptics.heavy()
                Task { await tv.powerToggle() }
            }
        }
    }

    private var touchpad: some View {
        UnifiedTouchpadSurface(
            target: target,
            remote: remote,
            tv: tv,
            isDragging: $isTouchpadDragging,
            onTouchActiveChanged: { isTouchpadActive = $0 }
        ) {
            showFullScreenTouchpad = true
        }
        .opacity(interactionEnabled ? 1 : 0.52)
    }

    private var mediaRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignToken.Spacing.medium) {
                playbackButtons
                Spacer(minLength: 0)
                volumeButtons
            }
            VStack(spacing: DesignToken.Spacing.small) {
                playbackButtons
                volumeButtons
            }
        }
        .padding(.horizontal, 2)
        .opacity(interactionEnabled ? 1 : 0.52)
    }

    private var playbackButtons: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            mediaButton("backward.fill") {
                switch target {
                case .pc: remote.sendKey(.mediaPrevious)
                case .tv: Task { await tv.playback(.rewind) }
                }
            }
            mediaButton("playpause.fill", large: true) {
                switch target {
                case .pc: remote.sendKey(.mediaPlayPause)
                case .tv: Task { await tv.playback(.play) }
                }
            }
            mediaButton("forward.fill") {
                switch target {
                case .pc: remote.sendKey(.mediaNext)
                case .tv: Task { await tv.playback(.fastForward) }
                }
            }
        }
    }

    private var volumeButtons: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            mediaButton("speaker.minus.fill") {
                switch target {
                case .pc: remote.sendKey(.volumeDown)
                case .tv: Task { await tv.volumeDown() }
                }
            }
            mediaButton(muteSymbol) {
                switch target {
                case .pc: remote.sendKey(.volumeMute)
                case .tv: Task { await tv.toggleMute() }
                }
            }
            mediaButton("speaker.plus.fill") {
                switch target {
                case .pc: remote.sendKey(.volumeUp)
                case .tv: Task { await tv.volumeUp() }
                }
            }
        }
    }

    private var muteSymbol: String {
        target == .tv && tv.tvState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private func mediaButton(_ symbol: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            RemoteHaptics.key()
        } label: {
            Image(systemName: symbol)
                .font(large ? .largeTitle : .title2)
                .frame(width: large ? 84 : 64, height: large ? 84 : 64)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: 999, tint: DesignToken.Color.accent.opacity(0.16), interactive: true)
    }

    /// Centered when the buttons fit the screen; falls back to a leading-aligned
    /// horizontal scroll only when they don't (e.g. a long custom PC shortcut row).
    private var shortcutStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignToken.Spacing.small) { shortcutButtons }
                .padding(.vertical, 2)
            ScrollView(.horizontal) {
                HStack(spacing: DesignToken.Spacing.small) { shortcutButtons }
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        switch target {
        case .pc:
            ForEach(remote.preferences.shortcutRow, id: \.self) { key in
                RemoteKeyButton(title: key.displayTitle, symbol: key.displaySymbol, enabled: remote.connectionState.acceptsInput) {
                    remote.sendKey(key)
                }
            }
            RemoteKeyButton(title: "Clipboard", symbol: "doc.on.clipboard", enabled: remote.connectionState.acceptsInput) {
                showClipboardActions = true
            }
        case .tv:
            RemoteKeyButton(title: "Back", symbol: "arrow.uturn.backward", enabled: true) {
                RemoteHaptics.heavy()
                Task { await tv.send(.back) }
            }
            RemoteKeyButton(title: "Home", symbol: "house.fill", enabled: true) {
                RemoteHaptics.heavy()
                Task { await tv.send(.home) }
            }
            RemoteKeyButton(title: "Menu", symbol: "line.3.horizontal", enabled: true) {
                RemoteHaptics.heavy()
                Task { await tv.send(.menu) }
            }
        }
    }

    @ViewBuilder
    private var extraPanelPicker: some View {
        switch target {
        case .pc:
            Picker("PC panel", selection: Bindable(remote).selectedMode) {
                ForEach(RemoteControlMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(DesignToken.Spacing.xSmall)
            .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control)
        case .tv:
            Picker("TV panel", selection: $tvExtraPanel) {
                ForEach(TVExtraPanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.symbol).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding(DesignToken.Spacing.xSmall)
            .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control)
        }
    }

    @ViewBuilder
    private var extraPanelContent: some View {
        switch target {
        case .pc:
            switch remote.selectedMode {
            case .keyboard: RemoteKeyboardPanel(remote: remote)
            case .agent: RemoteAgentPanel(remote: remote)
            case .shortcuts: RemoteShortcutsPanel(remote: remote)
            }
        case .tv:
            switch tvExtraPanel {
            case .apps:
                if !tv.tvState.applications.isEmpty {
                    LGTVApplicationsCard()
                } else {
                    ContentUnavailableView("No Apps", systemImage: "square.grid.2x2", description: Text("Connect to the TV to load its Home launcher."))
                }
            case .inputs:
                if !tv.tvState.inputs.isEmpty {
                    LGTVInputsCard()
                } else {
                    ContentUnavailableView("No Inputs", systemImage: "cable.connector", description: Text("Connect to the TV to load its inputs."))
                }
            case .display:
                DashboardCard {
                    LGTVDisplayControls()
                }
            }
        }
    }

    private var interactionEnabled: Bool {
        switch target {
        case .pc: remote.connectionState.acceptsInput
        case .tv: tv.connectionState.isConnected
        }
    }

    private var pcStatusColor: Color {
        switch remote.connectionState {
        case .connected: DesignToken.Color.positive
        case .highLatency: DesignToken.Color.warning
        case .connecting: DesignToken.Color.cyan
        case .permissionDisabled, .emergencyDisabled, .authenticationRejected, .unavailable: DesignToken.Color.destructive
        case .disconnected: .secondary
        }
    }

    private var tvStatusColor: Color {
        switch tv.connectionState {
        case .connected: DesignToken.Color.positive
        case .connecting, .discovering, .reconnecting, .awaitingPairing: .orange
        default: DesignToken.Color.destructive
        }
    }

    private func sendClipboard(pasteAfterCopy: Bool) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        remote.sendClipboardText(text, pasteAfterCopy: pasteAfterCopy, userInitiated: true)
        RemoteHaptics.click()
    }
}

/// The shared touchpad card for both targets. On PC it's a real trackpad — drag
/// deltas move the remote pointer. On TV it goes back to swipe-direction D-pad
/// emulation (arrows via `LGTVRemoteButton`) rather than driving a live on-screen
/// pointer; only the surrounding card, header, and full-screen affordance are shared.
struct UnifiedTouchpadSurface: View {
    let target: RemoteTarget
    let remote: RemoteInputController
    let tv: LGTVStore
    @Binding var isDragging: Bool
    var onTouchActiveChanged: (Bool) -> Void = { _ in }
    var onExpand: (() -> Void)?

    @State private var tvTranslation: CGSize = .zero
    @State private var tvRepeatingDirection: LGTVRemoteButton?
    @State private var tvRepeatTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: DesignToken.Spacing.small) {
            surface
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    HStack {
                        Label(statusText, systemImage: statusSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if target == .pc, remote.preferences.precisionMode {
                            Text("PRECISION")
                                .font(.caption2.bold())
                                .foregroundStyle(DesignToken.Color.cyan)
                        }
                        if let onExpand {
                            Button(action: onExpand) {
                                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignToken.Color.accent)
                        }
                    }
                    .padding(DesignToken.Spacing.small)
                }

            HStack(spacing: DesignToken.Spacing.small) {
                switch target {
                case .pc:
                    RemoteKeyButton(title: "Left Click", symbol: "cursorarrow.click", enabled: remote.connectionState.acceptsInput) {
                        remote.click(.left)
                        RemoteHaptics.click()
                    }
                    RemoteKeyButton(title: "Right Click", symbol: "contextualmenu.and.cursorarrow", enabled: remote.connectionState.acceptsInput) {
                        remote.click(.right)
                        RemoteHaptics.click()
                    }
                case .tv:
                    RemoteKeyButton(title: "Select", symbol: "checkmark.circle", enabled: true) {
                        RemoteHaptics.heavy()
                        Task { await tv.send(.enter) }
                    }
                    RemoteKeyButton(title: "Back", symbol: "arrow.uturn.backward", enabled: true) {
                        RemoteHaptics.heavy()
                        Task { await tv.send(.back) }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch target {
        case .pc: isDragging ? "Dragging" : remote.lastInteraction
        case .tv: "Swipe to Navigate"
        }
    }

    private var statusSymbol: String {
        switch target {
        case .pc: isDragging ? "hand.draw.fill" : "cursorarrow.motionlines"
        case .tv: "hand.draw"
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch target {
        case .pc: pcSurface
        case .tv: tvSurface
        }
    }

    private var pcSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                .fill(DesignToken.Color.card)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                        .strokeBorder(isDragging ? DesignToken.Color.accent.opacity(0.7) : DesignToken.Color.cardBorder, lineWidth: isDragging ? 1.5 : 0.75)
                }

            VStack(spacing: DesignToken.Spacing.small) {
                Image(systemName: isDragging ? "hand.draw.fill" : "hand.point.up.left")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.45))
                Text(isDragging ? "Dragging" : "Touchpad")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tap to click · Two fingers to scroll · Hold to drag")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .allowsHitTesting(false)

            RemoteTouchpadSurface(
                pointerMoved: { dx, dy in remote.enqueuePointer(deltaX: dx, deltaY: dy) },
                scrolled: { dx, dy in remote.enqueueScroll(deltaX: dx, deltaY: dy) },
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
                    isDragging = active
                    remote.setDrag(active: active)
                },
                touchActiveChanged: onTouchActiveChanged
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous))
        }
        .frame(minHeight: 560)
    }

    private var tvSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                .fill(DesignToken.Color.card)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous)
                        .strokeBorder(DesignToken.Color.cardBorder, lineWidth: 0.75)
                }

            VStack(spacing: DesignToken.Spacing.small) {
                Image(systemName: "hand.draw")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.45))
                Text("Swipe to Navigate")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Swipe to navigate · Tap to select")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)

            Circle()
                .fill(.white.opacity(tvTranslation == .zero ? 0 : 0.2))
                .frame(width: 54, height: 54)
                .offset(
                    x: min(max(tvTranslation.width * 0.28, -42), 42),
                    y: min(max(tvTranslation.height * 0.28, -42), 42)
                )
                .animation(.snappy(duration: 0.18), value: tvTranslation)
        }
        .frame(minHeight: 560)
        .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.panel, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onChanged { value in
                    tvTranslation = value.translation
                    let direction = tvDirection(for: value.translation)
                    if direction != tvRepeatingDirection { beginTVRepeating(direction) }
                }
                .onEnded { _ in
                    tvTranslation = .zero
                    stopTVRepeating()
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                RemoteHaptics.heavy()
                Task { await tv.send(.enter) }
            }
        )
        // Tracks touch-down/up independently of the 18pt drag threshold above, both to
        // suppress the enclosing screen's scroll from the first touch (not only once a
        // real drag starts) and to match the PC surface's touchActiveChanged contract.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { _ in onTouchActiveChanged(true) }
                .onEnded { _ in onTouchActiveChanged(false) }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TV navigation touchpad")
        .accessibilityHint("Swipe to navigate or double tap to select")
        .accessibilityAction(named: "Select") { Task { await tv.send(.enter) } }
        .onDisappear { stopTVRepeating() }
    }

    private func tvDirection(for translation: CGSize) -> LGTVRemoteButton {
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
    }

    private func beginTVRepeating(_ direction: LGTVRemoteButton) {
        stopTVRepeating()
        tvRepeatingDirection = direction
        RemoteHaptics.heavy()
        Task { await tv.send(direction) }
        tvRepeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                RemoteHaptics.heavy()
                await tv.send(direction)
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private func stopTVRepeating() {
        tvRepeatTask?.cancel()
        tvRepeatTask = nil
        tvRepeatingDirection = nil
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

/// The PC "Agent" panel — everything the Windows Agent exposes beyond raw input:
/// applications/games, Windows audio sessions, and GoXLR. Media keys themselves live
/// in the unified remote's always-visible media row, not here.
private struct RemoteAgentPanel: View {
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
                     : "Applications, Windows audio sessions, and GoXLR controls use paired HTTPS capability endpoints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, DesignToken.Spacing.medium)
        }
        .scrollIndicators(.hidden)
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

private struct RemoteShortcut: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let key: RemoteVirtualKey
}

private struct RemoteShortcutsPanel: View {
    let remote: RemoteInputController

    private let shortcuts: [RemoteShortcut] = [
        RemoteShortcut(title: "Copy", symbol: "doc.on.doc", key: .copy),
        RemoteShortcut(title: "Paste", symbol: "doc.on.clipboard", key: .paste),
        RemoteShortcut(title: "Undo", symbol: "arrow.uturn.backward", key: .undo),
        RemoteShortcut(title: "Redo", symbol: "arrow.uturn.forward", key: .redo),
        RemoteShortcut(title: "Alt+Tab", symbol: "rectangle.on.rectangle", key: .altTab),
        RemoteShortcut(title: "Desktop", symbol: "macwindow", key: .desktop)
    ]

    var body: some View {
        AdaptiveRemoteGrid(items: shortcuts) { shortcut in
            RemoteKeyButton(title: shortcut.title, symbol: shortcut.symbol, enabled: remote.connectionState.acceptsInput) {
                remote.sendKey(shortcut.key)
                RemoteHaptics.key()
            }
        }
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
                        Picker("Route", selection: $remote.windowsAgentConnectionMode) {
                            ForEach(WindowsAgentConnectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if remote.windowsAgentConnectionMode != .vpn {
                            TextField("Local · https://192.168.x.x:8732", text: $remote.windowsAgentLocalAddress)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if remote.windowsAgentConnectionMode != .local {
                            TextField("VPN · https://100.x.y.z:8732", text: $remote.windowsAgentVPNAddress)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Text("Automatic prefers the direct mesh/LAN route and falls back to Tailscale when away from home. Both routes remain authenticated and require trusted HTTPS certificates.")
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
    let target: RemoteTarget
    let remote: RemoteInputController
    let tv: LGTVStore
    @State private var isDragging = false

    var body: some View {
        ZStack {
            AppBackground()
            UnifiedTouchpadSurface(target: target, remote: remote, tv: tv, isDragging: $isDragging)
                .padding(DesignToken.Spacing.medium)
                .padding(.top, 48)
                .zIndex(0)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DesignToken.Spacing.medium)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .glassSurface(
                .interactive,
                cornerRadius: 999,
                tint: DesignToken.Color.accent.opacity(0.12),
                interactive: true
            )
            .padding(DesignToken.Spacing.medium)
            .zIndex(100)
            .accessibilityHint("Returns to the Remote screen")
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
    static func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 1)
    }

    static func click() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
    }

    static func key() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
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
