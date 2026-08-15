import SwiftUI
import UIKit

struct ControlDeckView: View {
    @Environment(AppState.self) private var appState
    @State private var showEditor = false
    @State private var presentedFolder: ControlDeckItem?
    @State private var itemAwaitingConfirmation: ControlDeckItem?
    @State private var availableWidth: CGFloat = 0
    let compact: Bool

    var body: some View {
        let columnCount = deckColumnCount
        let denseTiles = columnCount >= 4

        VStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
            HStack {
                Label("Control Deck", systemImage: "square.grid.2x2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    RemoteHaptics.heavy()
                    showEditor = true
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignToken.Color.accent)
                .accessibilityHint("Add, edit, delete, or reorder dashboard controls")
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: DesignToken.Spacing.small),
                    count: columnCount
                ),
                spacing: DesignToken.Spacing.small
            ) {
                ForEach(appState.controlDeckItems) { item in
                    control(for: item, dense: denseTiles)
                }

                Button {
                    RemoteHaptics.heavy()
                    showEditor = true
                } label: {
                    VStack(spacing: DesignToken.Spacing.xSmall) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                        Text("Add Control")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(DesignToken.Color.accent)
                    .frame(maxWidth: .infinity, minHeight: denseTiles ? 90 : 76)
                }
                .buttonStyle(.plain)
                .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: DesignToken.Color.accent.opacity(0.08), interactive: true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newValue in
            availableWidth = newValue
        }
        .sheet(isPresented: $showEditor) {
            ControlDeckEditorView()
        }
        .onChange(of: showEditor) { _, presented in
            Task {
                await appState.remoteInput.goXLR.setInteractionUIIsPresented(presented)
            }
        }
        .sheet(item: $presentedFolder) { folder in
            ControlDeckFolderView(folderID: folder.id)
        }
        .confirmationDialog(
            "Run this PC action?",
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            if let item = itemAwaitingConfirmation {
                Button(item.title, role: .destructive) {
                    RemoteHaptics.heavy()
                    Task { await appState.performControlDeckAction(item) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("This action is marked as requiring confirmation and may control another device or app.")
        }
    }

    @ViewBuilder
    private func control(for item: ControlDeckItem, dense: Bool) -> some View {
        switch item.kind {
        case .companionButton:
            ControlDeckActionTile(item: item, dense: dense) {
                run(item)
            }
        case .folder:
            ControlDeckActionTile(item: item, trailingSymbol: "chevron.right", dense: dense) {
                presentedFolder = item
            }
        case .pcStatusWidget:
            ControlDeckStatusWidget(item: item, dense: dense)
        case .microphoneWidget:
            ControlDeckMicrophoneWidget(item: item, dense: dense)
        case .volumeWidget:
            ControlDeckVolumeWidget(item: item, dense: dense)
        }
    }

    /// Derives column count from the actual width available to this view, rather than
    /// device orientation, so a narrower widget card (e.g. an iPad "medium" override)
    /// doesn't get squeezed into more columns than it can comfortably fit.
    private var deckColumnCount: Int {
        guard availableWidth > 0 else {
            return UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
        }
        let minTileWidth: CGFloat = 100
        let spacing = DesignToken.Spacing.small
        let columns = Int((availableWidth + spacing) / (minTileWidth + spacing))
        return max(2, min(columns, 8))
    }

    private func run(_ item: ControlDeckItem) {
        if item.requiresConfirmation {
            itemAwaitingConfirmation = item
        } else {
            Task { await appState.performControlDeckAction(item) }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { itemAwaitingConfirmation != nil },
            set: { if !$0 { itemAwaitingConfirmation = nil } }
        )
    }
}

private struct ControlDeckActionTile: View {
    let item: ControlDeckItem
    var trailingSymbol: String?
    var dense = false
    let action: () -> Void

    var body: some View {
        let tint = Color.controlDeckTint(named: item.tintName)

        Button {
            RemoteHaptics.heavy()
            action()
        } label: {
            Group {
                if dense {
                    VStack(spacing: DesignToken.Spacing.xSmall) {
                        GlassIcon(symbol: item.symbol, tint: tint, size: 38)
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    HStack(spacing: DesignToken.Spacing.small) {
                        GlassIcon(symbol: item.symbol, tint: tint, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let trailingSymbol {
                            Image(systemName: trailingSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(DesignToken.Spacing.small)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.16), interactive: true)
    }
}

private struct ControlDeckStatusWidget: View {
    @Environment(AppState.self) private var appState
    let item: ControlDeckItem
    let dense: Bool

    var body: some View {
        let online = appState.dashboard.pc.isOnline
        let tint = online ? DesignToken.Color.positive : Color.secondary

        Group {
            if dense {
                VStack(spacing: DesignToken.Spacing.xSmall) {
                    GlassIcon(symbol: item.symbol, tint: tint, size: 38)
                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Label(online ? "Online" : "Offline", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                HStack(spacing: DesignToken.Spacing.small) {
                    GlassIcon(symbol: item.symbol, tint: tint, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Label(online ? "Online" : "Offline", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(DesignToken.Spacing.small)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            }
        }
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.12))
    }
}

private struct ControlDeckMicrophoneWidget: View {
    @Environment(AppState.self) private var appState
    let item: ControlDeckItem
    let dense: Bool

    var body: some View {
        let muted = appState.dashboard.pc.microphoneMuted
        let tint = muted ? DesignToken.Color.destructive : DesignToken.Color.positive

        Group {
            if dense {
                VStack(spacing: DesignToken.Spacing.xSmall) {
                    GlassIcon(symbol: muted ? "mic.slash.fill" : item.symbol, tint: tint, size: 38)
                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(muted ? "Muted" : "Live").font(.caption2).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                HStack(spacing: DesignToken.Spacing.small) {
                    GlassIcon(symbol: muted ? "mic.slash.fill" : item.symbol, tint: tint, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(muted ? "Muted" : "Live")
                            .font(.caption2)
                            .foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(DesignToken.Spacing.small)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            }
        }
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.12))
    }
}

private struct ControlDeckVolumeWidget: View {
    @Environment(AppState.self) private var appState
    let item: ControlDeckItem
    let dense: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.xSmall) {
            HStack {
                Image(systemName: item.symbol)
                    .foregroundStyle(Color.controlDeckTint(named: item.tintName))
                Text(item.title).font(.caption.weight(.semibold))
                Spacer()
                Text(appState.dashboard.pc.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { appState.dashboard.pc.volume },
                set: { appState.dashboard.pc.volume = $0 }
            ), onEditingChanged: { editing in
                if editing { RemoteHaptics.heavy() }
            })
            .tint(Color.controlDeckTint(named: item.tintName))
        }
        .padding(DesignToken.Spacing.small)
        .frame(maxWidth: .infinity, minHeight: dense ? 90 : 76, alignment: .leading)
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control, tint: Color.controlDeckTint(named: item.tintName).opacity(0.1))
    }
}

private struct ControlDeckFolderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var itemAwaitingConfirmation: ControlDeckItem?
    let folderID: UUID

    private var folder: ControlDeckItem? {
        appState.controlDeckItems.first { $0.id == folderID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignToken.Spacing.small)], spacing: DesignToken.Spacing.small) {
                    if let folder {
                        ForEach(folder.children) { item in
                            ControlDeckActionTile(item: item) {
                                if item.requiresConfirmation {
                                    itemAwaitingConfirmation = item
                                } else {
                                    Task { await appState.performControlDeckAction(item) }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(AppBackground())
            .navigationTitle(folder?.title ?? "Folder")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if folder?.children.isEmpty != false {
                    ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Use Customize to add an action here."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Run this PC action?", isPresented: confirmationBinding, titleVisibility: .visible) {
                if let item = itemAwaitingConfirmation {
                    Button(item.title, role: .destructive) {
                        RemoteHaptics.heavy()
                        Task { await appState.performControlDeckAction(item) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { itemAwaitingConfirmation != nil }, set: { if !$0 { itemAwaitingConfirmation = nil } })
    }
}

private struct ControlDeckEditContext: Identifiable {
    let id = UUID()
    var item: ControlDeckItem
    var parentFolderID: UUID?
    let isNew: Bool
}

private struct ControlDeckEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editContext: ControlDeckEditContext?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Add Apple Shortcuts, Govee controls, Companion buttons, folders, and live PC widgets.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Dashboard Layout") {
                    ForEach(appState.controlDeckItems) { item in
                        deckRow(item, parentFolderID: nil)

                        if item.kind == .folder {
                            ForEach(item.children) { child in
                                deckRow(child, parentFolderID: item.id)
                                    .padding(.leading, DesignToken.Spacing.large)
                            }
                            .onMove { source, destination in
                                appState.moveControlDeckItems(in: item.id, from: source, to: destination)
                            }
                        }
                    }
                    .onMove(perform: appState.moveControlDeckItems)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Customize Control Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    EditButton()
                    addMenu
                }
            }
            .sheet(item: $editContext) { context in
                ControlDeckItemEditor(context: context)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                editContext = ControlDeckEditContext(item: .actionButton(), parentFolderID: nil, isNew: true)
            } label: {
                Label("Action Button", systemImage: "bolt.fill")
            }

            Button {
                editContext = ControlDeckEditContext(item: .folder(), parentFolderID: nil, isNew: true)
            } label: {
                Label("Folder", systemImage: "folder.badge.plus")
            }

            Menu("Widget") {
                widgetButton(.pcStatusWidget)
                widgetButton(.microphoneWidget)
                widgetButton(.volumeWidget)
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add control")
    }

    private func widgetButton(_ kind: ControlDeckItemKind) -> some View {
        Button {
            editContext = ControlDeckEditContext(item: .widget(kind), parentFolderID: nil, isNew: true)
        } label: {
            Label(kind.description, systemImage: ControlDeckItem.widget(kind).symbol)
        }
    }

    private func deckRow(_ item: ControlDeckItem, parentFolderID: UUID?) -> some View {
        HStack(spacing: DesignToken.Spacing.small) {
            Image(systemName: item.symbol)
                .foregroundStyle(Color.controlDeckTint(named: item.tintName))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.kind.description + (item.kind == .companionButton ? " · \(actionDescription(for: item))" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editContext = ControlDeckEditContext(item: item, parentFolderID: parentFolderID, isNew: false)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                appState.deleteControlDeckItem(id: item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func actionDescription(for item: ControlDeckItem) -> String {
        switch item.action {
        case .shortcut(let shortcut): shortcut.name.isEmpty ? "Shortcut not selected" : shortcut.name
        case .govee(let action): action.deviceName
        case .companion(let mapping): mapping.locationDescription
        case nil: item.mapping?.locationDescription ?? "Not configured"
        }
    }
}

private struct ControlDeckItemEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var item: ControlDeckItem
    @State private var parentFolderID: UUID?
    @State private var testStatus: CompanionButtonTestStatus = .idle
    @State private var showTestConfirmation = false
    let isNew: Bool

    private let symbols = [
        "gamecontroller.fill", "play.fill", "power", "powersleep", "display",
        "keyboard.fill", "headphones", "speaker.wave.2.fill", "mic.fill", "app.fill",
        "folder.fill", "star.fill", "bolt.fill", "sparkles", "rectangle.and.hand.point.up.left.fill"
    ]

    init(context: ControlDeckEditContext) {
        _item = State(initialValue: context.item)
        _parentFolderID = State(initialValue: context.parentFolderID)
        isNew = context.isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $item.title)
                    TextField("Subtitle", text: $item.subtitle)

                    ScrollView(.horizontal) {
                        HStack(spacing: DesignToken.Spacing.small) {
                            ForEach(symbols, id: \.self) { symbol in
                                Button {
                                    item.symbol = symbol
                                } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 38, height: 38)
                                        .background(item.symbol == symbol ? Color.controlDeckTint(named: item.tintName).opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(symbol)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Picker("Color", selection: $item.tintName) {
                        ForEach(ControlDeckTint.allCases) { tint in
                            Label(tint.title, systemImage: "circle.fill")
                                .foregroundStyle(Color.controlDeckTint(named: tint.rawValue))
                                .tag(tint.rawValue)
                        }
                    }
                }

                if item.kind == .companionButton {
                    Section("Placement") {
                        Picker("Location", selection: $parentFolderID) {
                            Text("Main Dashboard").tag(Optional<UUID>.none)
                            ForEach(appState.controlDeckItems.filter { $0.kind == .folder && $0.id != item.id }) { folder in
                                Text(folder.title).tag(Optional(folder.id))
                            }
                        }
                    }

                    Section("Action") {
                        Picker("Run", selection: actionTypeBinding) {
                            ForEach(ControlDeckActionType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        Toggle("Require confirmation", isOn: $item.requiresConfirmation)
                    }

                    if selectedActionType == .shortcut {
                        Section("Apple Shortcut") {
                            TextField("Shortcut name", text: shortcutNameBinding)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                            TextField("Optional text input", text: shortcutInputBinding)
                            Text("The shortcut must already exist on this iPhone or iPad. Running it may temporarily open the Shortcuts app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if selectedActionType == .govee {
                        Section("Govee Action") {
                            if actionableGoveeDevices.isEmpty {
                                Label("Add your API key and discover devices in Settings first.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(DesignToken.Color.warning)
                            } else {
                                Picker("Device", selection: goveeDeviceIDBinding) {
                                    ForEach(actionableGoveeDevices) { device in
                                        Text(device.deviceName).tag(device.id)
                                    }
                                }

                                if let device = selectedGoveeDevice {
                                    Picker("Control", selection: goveeCapabilityIDBinding) {
                                        ForEach(device.actionableCapabilities) { capability in
                                            Text(capability.title).tag(capability.id)
                                        }
                                    }
                                }

                                if let capability = selectedGoveeCapability,
                                   let options = capability.parameters?.options,
                                   !options.isEmpty {
                                    Picker("Value", selection: goveeValueBinding) {
                                        ForEach(options) { option in
                                            Text(option.name).tag(option.value)
                                        }
                                    }
                                } else if let range = selectedGoveeCapability?.parameters?.range {
                                    LabeledContent("Value", value: goveeRangeBinding.wrappedValue.formatted(.number.precision(.fractionLength(0))))
                                    Slider(value: goveeRangeBinding, in: range.min...range.max, step: max(range.precision ?? 1, 1))
                                }
                            }
                        }
                    } else {
                        Section {
                        if !isConnected {
                            Button {
                                Task { await appState.testCompanionConnection() }
                            } label: {
                                Label("Connect to Companion", systemImage: "network")
                            }
                            .disabled(
                                appState.companionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || appState.companionStatus == .testing
                            )

                            if appState.companionAddress.isEmpty {
                                Text("Add the Companion PC address in Settings first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Stepper(value: mappingBinding(\.page), in: 1...99) {
                            LabeledContent("Page", value: "\(item.mapping?.page ?? 1)")
                        }
                        Stepper(value: mappingBinding(\.row), in: 0...99) {
                            LabeledContent("Row", value: "\(item.mapping?.row ?? 0)")
                        }
                        Stepper(value: mappingBinding(\.column), in: 0...99) {
                            LabeledContent("Column", value: "\(item.mapping?.column ?? 0)")
                        }
                        Button {
                            showTestConfirmation = true
                        } label: {
                            Label("Test Companion Button", systemImage: "rectangle.and.hand.point.up.left")
                        }
                        .disabled(!isConnected || testStatus == .sending)

                        if let message = testStatus.message {
                            HStack(alignment: .top) {
                                if testStatus == .sending { ProgressView().controlSize(.small) }
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(testColor)
                            }
                        }
                    } header: {
                        Text("Companion Mapping")
                    } footer: {
                        Text("Testing confirms only that Companion accepted the press. Verify the action on the PC.")
                    }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(isNew ? "Add Control" : "Edit Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Test this Companion button?", isPresented: $showTestConfirmation, titleVisibility: .visible) {
                Button("Press \(item.mapping?.locationDescription ?? "mapped button")") {
                    testStatus = .sending
                    Task {
                        testStatus = await appState.testCompanionMapping(item.mapping ?? CompanionButtonMapping())
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Check the configured Companion action first because it may be destructive.")
            }
        }
    }

    private func mappingBinding(_ keyPath: WritableKeyPath<CompanionButtonMapping, Int>) -> Binding<Int> {
        Binding {
            (item.mapping ?? CompanionButtonMapping())[keyPath: keyPath]
        } set: { value in
            var mapping = item.mapping ?? CompanionButtonMapping()
            mapping[keyPath: keyPath] = value
            item.mapping = mapping
            item.action = .companion(mapping)
        }
    }

    private var selectedActionType: ControlDeckActionType {
        item.action?.type ?? (item.mapping == nil ? .shortcut : .companion)
    }

    private var actionTypeBinding: Binding<ControlDeckActionType> {
        Binding(get: { selectedActionType }) { type in
            switch type {
            case .shortcut:
                item.action = .shortcut(AppleShortcutAction())
            case .govee:
                item.action = firstGoveeAction()
            case .companion:
                let mapping = item.mapping ?? CompanionButtonMapping()
                item.mapping = mapping
                item.action = .companion(mapping)
            }
        }
    }

    private var shortcutNameBinding: Binding<String> {
        Binding {
            guard case .shortcut(let shortcut) = item.action else { return "" }
            return shortcut.name
        } set: { name in
            var shortcut = currentShortcut
            shortcut.name = name
            item.action = .shortcut(shortcut)
        }
    }

    private var shortcutInputBinding: Binding<String> {
        Binding {
            guard case .shortcut(let shortcut) = item.action else { return "" }
            return shortcut.input
        } set: { input in
            var shortcut = currentShortcut
            shortcut.input = input
            item.action = .shortcut(shortcut)
        }
    }

    private var currentShortcut: AppleShortcutAction {
        guard case .shortcut(let shortcut) = item.action else { return AppleShortcutAction() }
        return shortcut
    }

    private var selectedGoveeAction: GoveeDeviceAction? {
        guard case .govee(let action) = item.action else { return nil }
        return action
    }

    private var actionableGoveeDevices: [GoveeDevice] {
        appState.goveeDevices.filter { !$0.actionableCapabilities.isEmpty }
    }

    private var selectedGoveeDevice: GoveeDevice? {
        guard let action = selectedGoveeAction else { return actionableGoveeDevices.first }
        return actionableGoveeDevices.first { $0.sku == action.sku && $0.device == action.device }
    }

    private var selectedGoveeCapability: GoveeCapability? {
        guard let device = selectedGoveeDevice else { return nil }
        guard let action = selectedGoveeAction else { return device.actionableCapabilities.first }
        return device.actionableCapabilities.first {
            $0.type == action.capabilityType && $0.instance == action.capabilityInstance
        } ?? device.actionableCapabilities.first
    }

    private var goveeDeviceIDBinding: Binding<String> {
        Binding(get: { selectedGoveeDevice?.id ?? "" }) { id in
            guard let device = actionableGoveeDevices.first(where: { $0.id == id }) else { return }
            item.action = makeGoveeAction(device: device, capability: device.actionableCapabilities.first)
        }
    }

    private var goveeCapabilityIDBinding: Binding<String> {
        Binding(get: { selectedGoveeCapability?.id ?? "" }) { id in
            guard let device = selectedGoveeDevice,
                  let capability = device.actionableCapabilities.first(where: { $0.id == id }) else { return }
            item.action = makeGoveeAction(device: device, capability: capability)
        }
    }

    private var goveeValueBinding: Binding<GoveeValue> {
        Binding(get: { selectedGoveeAction?.value ?? .null }) { value in
            guard var action = selectedGoveeAction else { return }
            action.value = value
            item.action = .govee(action)
        }
    }

    private var goveeRangeBinding: Binding<Double> {
        Binding {
            guard case .number(let value) = selectedGoveeAction?.value else {
                return selectedGoveeCapability?.parameters?.range?.min ?? 0
            }
            return value
        } set: { value in
            guard var action = selectedGoveeAction else { return }
            action.value = .number(value)
            item.action = .govee(action)
        }
    }

    private func firstGoveeAction() -> ControlDeckAction {
        guard let device = actionableGoveeDevices.first else {
            return .govee(GoveeDeviceAction(
                sku: "", device: "", deviceName: "Govee Device",
                capabilityType: "", capabilityInstance: "", value: .null
            ))
        }
        return makeGoveeAction(device: device, capability: device.actionableCapabilities.first)
    }

    private func makeGoveeAction(device: GoveeDevice, capability: GoveeCapability?) -> ControlDeckAction {
        let capability = capability ?? device.actionableCapabilities.first
        return .govee(GoveeDeviceAction(
            sku: device.sku,
            device: device.device,
            deviceName: device.deviceName,
            capabilityType: capability?.type ?? "",
            capabilityInstance: capability?.instance ?? "",
            value: capability?.defaultValue ?? .null
        ))
    }

    private func save() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.kind == .folder {
            let count = item.children.count
            item.subtitle = "\(count) \(count == 1 ? "button" : "buttons")"
        } else if item.kind == .companionButton, item.subtitle.isEmpty || item.subtitle == "Choose an action" {
            switch item.action {
            case .shortcut(let shortcut): item.subtitle = shortcut.name.isEmpty ? "Shortcut not selected" : shortcut.name
            case .govee(let action): item.subtitle = action.summary
            case .companion(let mapping): item.subtitle = mapping.locationDescription
            case nil: item.subtitle = item.mapping?.locationDescription ?? "Action not configured"
            }
        }

        if isNew {
            appState.addControlDeckItem(item, to: parentFolderID)
        } else {
            appState.updateControlDeckItem(item, parentFolderID: parentFolderID)
        }
        dismiss()
    }

    private var isConnected: Bool {
        if case .connected = appState.companionStatus { true } else { false }
    }

    private var testColor: Color {
        switch testStatus {
        case .accepted: DesignToken.Color.warning
        case .failed: DesignToken.Color.destructive
        case .idle, .sending: .secondary
        }
    }
}
