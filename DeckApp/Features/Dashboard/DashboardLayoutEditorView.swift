import SwiftUI

struct DashboardLayoutEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showGallery = false
    @State private var editingWidget: RoomWidgetDefinition?
    @State private var widgetAwaitingDeletion: RoomWidgetDefinition?
    @State private var showResetConfirmation = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Arrange the Room Control dashboard, add capability-driven widgets, and choose separate sizes for iPhone and iPad.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Widget Order") {
                    ForEach(appState.roomControlTemplate.widgets) { widget in
                        widgetRow(widget)
                    }
                    .onMove(perform: appState.moveRoomWidgets)
                }
            }
            .environment(\.editMode, $editMode)
            .scrollContentBackground(.hidden)
            .navigationTitle("Dashboard Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showGallery = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Open widget gallery")
                    Menu {
                        Button(editMode == .active ? "Finish Reordering" : "Reorder Widgets", systemImage: "arrow.up.arrow.down") {
                            withAnimation(DesignToken.Animation.responsive) {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                        Button("Reset Room Control", systemImage: "arrow.counterclockwise", role: .destructive) {
                            showResetConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showGallery) {
                WidgetGalleryView()
            }
            .sheet(item: $editingWidget) { widget in
                WidgetConfigurationView(widget: widget)
            }
            .confirmationDialog(
                "Delete this widget?",
                isPresented: deletionBinding,
                titleVisibility: .visible
            ) {
                if let widget = widgetAwaitingDeletion {
                    Button("Delete \(widget.title)", role: .destructive) {
                        appState.deleteRoomWidget(id: widget.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The widget is removed from this dashboard. Companion mappings and device configuration are not deleted.")
            }
            .confirmationDialog(
                "Reset the dashboard layout?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Room Control", role: .destructive) {
                    appState.resetRoomControlLayout()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the default widgets and order. Companion button mappings remain saved.")
            }
        }
    }

    private func widgetRow(_ widget: RoomWidgetDefinition) -> some View {
        HStack(spacing: DesignToken.Spacing.small) {
            GlassIcon(
                symbol: widget.symbol,
                tint: Color.controlDeckTint(named: widget.tintName),
                size: 38
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.title).font(.subheadline.weight(.semibold))
                Text("\(widget.kind.title) · iPhone \((widget.phoneSize ?? widget.size).title) · iPad \((widget.padSize ?? widget.size).title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                editingWidget = widget
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                widgetAwaitingDeletion = widget
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { widgetAwaitingDeletion != nil },
            set: { if !$0 { widgetAwaitingDeletion = nil } }
        )
    }
}

private struct WidgetGalleryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: DesignToken.Spacing.medium)], spacing: DesignToken.Spacing.medium) {
                    ForEach(RoomWidgetCatalog.all) { prototype in
                        galleryCard(prototype)
                    }
                }
                .padding()
            }
            .background(AppBackground())
            .navigationTitle("Widget Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func galleryCard(_ prototype: RoomWidgetDefinition) -> some View {
        let tint = Color.controlDeckTint(named: prototype.tintName)
        return Button {
            appState.addRoomWidget(prototype.duplicated())
            RemoteHaptics.click()
        } label: {
            VStack(alignment: .leading, spacing: DesignToken.Spacing.small) {
                GlassIcon(symbol: prototype.symbol, tint: tint, size: 42)
                Text(prototype.kind.title)
                    .font(.headline)
                Text(prototype.kind.galleryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Label("Add Widget", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.card, tint: tint.opacity(0.12), interactive: true)
    }
}

private struct WidgetConfigurationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var widget: RoomWidgetDefinition

    private let symbols = [
        "lightbulb.fill", "snowflake", "tv.fill", "powerplug.fill", "slider.vertical.3",
        "square.grid.2x2.fill", "rectangle.and.hand.point.up.left.fill", "house.fill", "sparkles", "star.fill"
    ]

    init(widget: RoomWidgetDefinition) {
        _widget = State(initialValue: widget)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Title", text: $widget.title)
                    TextField("Subtitle", text: $widget.subtitle)
                    ScrollView(.horizontal) {
                        HStack(spacing: DesignToken.Spacing.small) {
                            ForEach(symbols, id: \.self) { symbol in
                                Button { widget.symbol = symbol } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 38, height: 38)
                                        .background(widget.symbol == symbol ? Color.controlDeckTint(named: widget.tintName).opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Picker("Accent", selection: $widget.tintName) {
                        ForEach(ControlDeckTint.allCases) { tint in
                            Text(tint.title).tag(tint.rawValue)
                        }
                    }
                }

                Section("Layout") {
                    Picker("Default size", selection: $widget.size) {
                        ForEach(RoomWidgetSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    optionalSizePicker("iPhone override", selection: $widget.phoneSize)
                    optionalSizePicker("iPad override", selection: $widget.padSize)
                }

                if widget.kind == .light {
                    Section {
                        Picker("Source", selection: lightSourceBinding) {
                            Text("Mock Light").tag("mock")
                            if let homeAssistantID {
                                Text("Home Assistant · \(homeAssistantID)").tag("ha:\(homeAssistantID)")
                            }
                            ForEach(appState.goveeDevices) { device in
                                Text("Govee · \(device.deviceName)").tag("govee:\(device.id)")
                            }
                            if widget.backend.backend == .govee,
                               appState.goveeDevice(for: widget.backend.identifier) == nil {
                                Text("Govee · Unavailable device").tag("govee:\(widget.backend.identifier)")
                            }
                        }
                    } header: {
                        Text("Device Mapping")
                    } footer: {
                        Text("Govee widgets automatically use only the controls reported by the selected device. Choose a larger widget size to show more controls.")
                    }
                } else if widget.kind == .audioMixer {
                    Section {
                        Picker("Source", selection: audioMixerSourceBinding) {
                            Text("Windows Agent · GoXLR").tag(WidgetBackendKind.windowsAgent)
                            Text("Mock Mixer").tag(WidgetBackendKind.mock)
                        }
                    } header: {
                        Text("Device Mapping")
                    } footer: {
                        Text("The live source uses the paired HTTPS Windows Agent. GoXLR Utility must already be running on the PC; DeckApp never starts it or switches device managers.")
                    }

                    Section {
                        ForEach(audioMixerChannelOptions) { channel in
                            Toggle(channel.name, isOn: audioMixerChannelBinding(channel.id))
                        }
                        Button("Use Default Four", systemImage: "arrow.counterclockwise") {
                            widget.audioMixerChannelIDs = RoomWidgetDefinition.defaultGoXLRChannelIDs
                        }
                    } header: {
                        Text("Visible Faders")
                    } footer: {
                        Text("Mic, Chat, Music, and System are shown by default. Select more channels to add faders; extra faders scroll horizontally inside the widget.")
                    }
                } else {
                    Section {
                        LabeledContent("Backend", value: widget.backend.backend.title)
                        TextField("Backend identifier", text: $widget.backend.identifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Mapping")
                    } footer: {
                        Text("Companion mappings remain configured inside the Control Deck.")
                    }
                }

                Section("Supported Capabilities") {
                    ForEach(widget.capabilities) { capability in
                        LabeledContent(capability.name) {
                            Text(capability.availability.rawValue.capitalized)
                                .foregroundStyle(capability.availability == .available ? DesignToken.Color.positive : .secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Configure Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        widget.title = widget.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.updateRoomWidget(widget)
                        dismiss()
                    }
                    .disabled(widget.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                if widget.kind == .audioMixer, widget.backend.backend == .windowsAgent {
                    await appState.remoteInput.goXLR.refreshChannels()
                }
            }
        }
    }

    private func optionalSizePicker(_ title: String, selection: Binding<RoomWidgetSize?>) -> some View {
        Picker(title, selection: selection) {
            Text("Use Default").tag(Optional<RoomWidgetSize>.none)
            ForEach(RoomWidgetSize.allCases, id: \.self) { size in
                Text(size.title).tag(Optional(size))
            }
        }
    }

    private var homeAssistantID: String? {
        let identifier = widget.backend.backend == .homeAssistant
            ? widget.backend.identifier
            : appState.homeAssistantLightEntityID
        return identifier.isEmpty ? nil : identifier
    }

    private var lightSourceBinding: Binding<String> {
        Binding {
            switch widget.backend.backend {
            case .govee: "govee:\(widget.backend.identifier)"
            case .homeAssistant: "ha:\(widget.backend.identifier)"
            default: "mock"
            }
        } set: { selection in
            if selection == "mock" {
                widget.backend = WidgetBackendReference(backend: .mock, identifier: "mock.light.room")
                widget.subtitle = "Mock light"
                widget.capabilities = MockCapabilities.light
            } else if selection.hasPrefix("ha:") {
                let identifier = String(selection.dropFirst(3))
                widget.backend = WidgetBackendReference(backend: .homeAssistant, identifier: identifier)
                widget.subtitle = "Home Assistant · \(identifier)"
            } else if selection.hasPrefix("govee:") {
                let identifier = String(selection.dropFirst(6))
                guard let device = appState.goveeDevice(for: identifier) else { return }
                widget.backend = WidgetBackendReference(backend: .govee, identifier: device.id)
                widget.subtitle = "Govee · \(device.deviceName)"
                widget.capabilities = device.actionableCapabilities.map(\.descriptor)
                if widget.title == "Room Lights" { widget.title = device.deviceName }
            }
        }
    }

    private var audioMixerSourceBinding: Binding<WidgetBackendKind> {
        Binding {
            widget.backend.backend == .windowsAgent ? .windowsAgent : .mock
        } set: { source in
            switch source {
            case .windowsAgent:
                widget.backend = WidgetBackendReference(backend: .windowsAgent, identifier: "windows-agent.goxlr")
                widget.subtitle = "Authenticated Windows Agent mixer"
            default:
                widget.backend = WidgetBackendReference(backend: .mock, identifier: "mock.audio.goxlr")
                widget.subtitle = "Mock GoXLR mixer"
            }
        }
    }

    private var selectedAudioMixerChannelIDs: [String] {
        widget.audioMixerChannelIDs ?? RoomWidgetDefinition.defaultGoXLRChannelIDs
    }

    private var audioMixerChannelOptions: [AudioMixerChannelOption] {
        let discovered: [AudioMixerChannelOption]
        if widget.backend.backend == .windowsAgent, !appState.remoteInput.goXLR.channels.isEmpty {
            discovered = appState.remoteInput.goXLR.channels.map {
                AudioMixerChannelOption(id: $0.id, name: $0.displayName)
            }
        } else {
            discovered = appState.mockRoomControl.goXLR.channels.map {
                AudioMixerChannelOption(id: $0.id, name: $0.name)
            }
        }

        let missingSelections = selectedAudioMixerChannelIDs
            .filter { selectedID in
                !discovered.contains { $0.id.caseInsensitiveCompare(selectedID) == .orderedSame }
            }
            .map { AudioMixerChannelOption(id: $0, name: $0.replacingOccurrences(of: "_", with: " ").capitalized) }
        return discovered + missingSelections
    }

    private func audioMixerChannelBinding(_ channelID: String) -> Binding<Bool> {
        Binding {
            selectedAudioMixerChannelIDs.contains { $0.caseInsensitiveCompare(channelID) == .orderedSame }
        } set: { isSelected in
            var selected = selectedAudioMixerChannelIDs
            if isSelected {
                if !selected.contains(where: { $0.caseInsensitiveCompare(channelID) == .orderedSame }) {
                    selected.append(channelID)
                }
            } else if selected.count > 1 {
                selected.removeAll { $0.caseInsensitiveCompare(channelID) == .orderedSame }
            }
            widget.audioMixerChannelIDs = selected
        }
    }
}

private struct AudioMixerChannelOption: Identifiable {
    let id: String
    let name: String
}

private extension RoomWidgetKind {
    var title: String {
        switch self {
        case .light: "Light"
        case .climate: "Climate"
        case .television: "Television"
        case .pcPower: "PC Power"
        case .audioMixer: "Audio Mixer"
        case .companionActions: "Companion Actions"
        case .remoteInputLauncher: "PC Remote"
        }
    }

    var galleryDescription: String {
        switch self {
        case .light: "Power, brightness, and supported color controls."
        case .climate: "Temperature, HVAC, fan, and swing controls."
        case .television: "Volume, source, media, and directional remote."
        case .pcPower: "Guarded plug-on and PC boot workflow."
        case .audioMixer: "Capability-driven audio channel levels and mute."
        case .companionActions: "Existing Companion actions, macros, and folders."
        case .remoteInputLauncher: "Open the authenticated PC keyboard and touchpad."
        }
    }
}

private extension WidgetBackendKind {
    var title: String {
        switch self {
        case .mock: "Mock"
        case .homeAssistant: "Home Assistant"
        case .govee: "Govee"
        case .windowsAgent: "Windows Agent"
        case .companion: "Companion"
        }
    }
}
