import Foundation

enum RoomWidgetKind: String, Codable, CaseIterable, Sendable {
    case light
    case climate
    case television
    case pcPower
    case audioMixer
    case companionActions
    case remoteInputLauncher
    case screenMirror
    case spotify
    case discord
}

enum RoomWidgetSize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case wide
    case large
    case banner

    var title: String { rawValue.capitalized }

    var presentationDensity: RoomWidgetPresentationDensity {
        switch self {
        case .small: .compact
        case .medium, .banner: .standard
        case .wide, .large: .expanded
        }
    }

    func columnSpan(in columnCount: Int) -> Int {
        switch self {
        case .small:
            1
        case .medium:
            min(2, columnCount)
        case .wide, .banner:
            columnCount
        case .large:
            min(2, columnCount)
        }
    }

    var minimumHeight: Double {
        switch self {
        case .banner: 108
        case .small: 150
        case .medium: 180
        case .wide: 210
        case .large: 260
        }
    }
}

enum RoomWidgetPresentationDensity: String, Codable, Sendable {
    case compact
    case standard
    case expanded
}

enum RoomWidgetLayoutClass: String, Codable, Sendable {
    case phone
    case pad
}

enum WidgetBackendKind: String, Codable, Sendable {
    case mock
    case homeAssistant
    case govee
    case windowsAgent
    case companion
    case lgWebOS
    case spotify
}

struct WidgetBackendReference: Codable, Sendable, Equatable {
    var backend: WidgetBackendKind
    var identifier: String
}

struct RoomWidgetDefinition: Identifiable, Codable, Sendable, Equatable {
    static let defaultGoXLRChannelIDs = ["mic", "chat", "music", "system"]

    let id: UUID
    var title: String
    var subtitle: String
    var symbol: String
    var tintName: String
    var kind: RoomWidgetKind
    var size: RoomWidgetSize
    var backend: WidgetBackendReference
    var capabilities: [DeviceCapabilityDescriptor]
    var phoneSize: RoomWidgetSize?
    var padSize: RoomWidgetSize?
    /// Nil keeps older saved layouts on the four physical GoXLR-style defaults.
    var audioMixerChannelIDs: [String]?
    /// Only meaningful when `kind == .screenMirror`. Defaults to `.mirror` for widgets
    /// saved before extend mode existed.
    var screenMirrorMode: ScreenMirrorMode?

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        symbol: String,
        tintName: String,
        kind: RoomWidgetKind,
        size: RoomWidgetSize,
        backend: WidgetBackendReference,
        capabilities: [DeviceCapabilityDescriptor],
        phoneSize: RoomWidgetSize? = nil,
        padSize: RoomWidgetSize? = nil,
        audioMixerChannelIDs: [String]? = nil,
        screenMirrorMode: ScreenMirrorMode? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tintName = tintName
        self.kind = kind
        self.size = size
        self.backend = backend
        self.capabilities = capabilities
        self.phoneSize = phoneSize
        self.padSize = padSize
        self.audioMixerChannelIDs = audioMixerChannelIDs
        self.screenMirrorMode = screenMirrorMode
    }

    var resolvedScreenMirrorMode: ScreenMirrorMode { screenMirrorMode ?? .mirror }

    func resolvedSize(for layoutClass: RoomWidgetLayoutClass) -> RoomWidgetSize {
        switch layoutClass {
        case .phone: phoneSize ?? size
        case .pad: padSize ?? size
        }
    }

    func duplicated() -> RoomWidgetDefinition {
        RoomWidgetDefinition(
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            tintName: tintName,
            kind: kind,
            size: size,
            backend: backend,
            capabilities: capabilities,
            phoneSize: phoneSize,
            padSize: padSize,
            audioMixerChannelIDs: audioMixerChannelIDs,
            screenMirrorMode: screenMirrorMode
        )
    }
}

enum RoomWidgetCatalog {
    static var all: [RoomWidgetDefinition] {
        RoomControlTemplate.roomControl.widgets.map { $0.duplicated() }
    }
}

struct RoomControlTemplate: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var widgets: [RoomWidgetDefinition]

    static let roomControl = RoomControlTemplate(
        id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A001")!,
        name: "Room Control",
        widgets: [
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A101")!,
                title: "Room Lights",
                subtitle: "Mock Govee light",
                symbol: "lightbulb.fill",
                tintName: "blue",
                kind: .light,
                size: .medium,
                backend: WidgetBackendReference(backend: .mock, identifier: "mock.light.room"),
                capabilities: MockCapabilities.light
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A102")!,
                title: "Bedroom Climate",
                subtitle: "Mock Gree climate",
                symbol: "snowflake",
                tintName: "cyan",
                kind: .climate,
                size: .large,
                backend: WidgetBackendReference(backend: .mock, identifier: "mock.climate.bedroom"),
                capabilities: MockCapabilities.climate
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A103")!,
                title: "LG TV",
                subtitle: "Mock webOS television",
                symbol: "tv.fill",
                tintName: "purple",
                kind: .television,
                size: .large,
                backend: WidgetBackendReference(backend: .mock, identifier: "mock.media_player.lg_tv"),
                capabilities: MockCapabilities.television
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A104")!,
                title: "PC Power",
                subtitle: "Mock Smart Life plug workflow",
                symbol: "powerplug.fill",
                tintName: "orange",
                kind: .pcPower,
                size: .medium,
                backend: WidgetBackendReference(backend: .mock, identifier: "mock.switch.pc_plug"),
                capabilities: MockCapabilities.pcPower
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A105")!,
                title: "PC Keyboard & Touchpad",
                subtitle: "Authenticated Windows Agent remote",
                symbol: "rectangle.and.hand.point.up.left.fill",
                tintName: "cyan",
                kind: .remoteInputLauncher,
                size: .banner,
                backend: WidgetBackendReference(backend: .windowsAgent, identifier: "mock.windows-agent.remote-input"),
                capabilities: MockCapabilities.remoteInput
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A107")!,
                title: "GoXLR Mini",
                subtitle: "Authenticated Windows Agent mixer",
                symbol: "slider.vertical.3",
                tintName: "green",
                kind: .audioMixer,
                size: .wide,
                backend: WidgetBackendReference(backend: .windowsAgent, identifier: "windows-agent.goxlr"),
                capabilities: MockCapabilities.audioMixer,
                audioMixerChannelIDs: RoomWidgetDefinition.defaultGoXLRChannelIDs
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A108")!,
                title: "Screen Mirror",
                subtitle: "Authenticated Windows Agent screen share",
                symbol: "tv.and.mediabox.fill",
                tintName: "cyan",
                kind: .screenMirror,
                size: .medium,
                backend: WidgetBackendReference(backend: .windowsAgent, identifier: "windows-agent.screen-mirror"),
                capabilities: MockCapabilities.screenMirror,
                screenMirrorMode: .mirror
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A109")!,
                title: "Extend Display",
                subtitle: "Authenticated Windows Agent virtual monitor",
                symbol: "rectangle.on.rectangle",
                tintName: "purple",
                kind: .screenMirror,
                size: .medium,
                backend: WidgetBackendReference(backend: .windowsAgent, identifier: "windows-agent.extend-display"),
                capabilities: MockCapabilities.screenMirror,
                screenMirrorMode: .extend
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A110")!,
                title: "Spotify",
                subtitle: "Mock media session",
                symbol: "music.note",
                tintName: "green",
                kind: .spotify,
                size: .medium,
                backend: WidgetBackendReference(backend: .spotify, identifier: "spotify.account"),
                capabilities: MockCapabilities.spotify
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A111")!,
                title: "Discord",
                subtitle: "Authenticated Windows Agent voice bridge",
                symbol: "person.wave.2.fill",
                tintName: "purple",
                kind: .discord,
                size: .wide,
                backend: WidgetBackendReference(backend: .windowsAgent, identifier: "windows-agent.discord"),
                capabilities: MockCapabilities.discord
            ),
            RoomWidgetDefinition(
                id: UUID(uuidString: "6A5A8A22-7B73-4F60-A6E1-B80D90C9A106")!,
                title: "Companion Actions",
                subtitle: "Existing actions and macros",
                symbol: "square.grid.2x2.fill",
                tintName: "blue",
                kind: .companionActions,
                size: .wide,
                backend: WidgetBackendReference(backend: .companion, identifier: "companion.control-deck"),
                capabilities: MockCapabilities.companion
            )
        ]
    )
}

enum MockCapabilities {
    static let light: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power"),
        DeviceCapabilityDescriptor(
            id: "brightness",
            kind: .brightness,
            name: "Brightness",
            numericRange: NumericRangeCapability(id: "brightness", name: "Brightness", minimum: 0, maximum: 100, step: 1, unit: "%", currentValue: 72, isWritable: true)
        ),
        DeviceCapabilityDescriptor(
            id: "color_temperature",
            kind: .colorTemperature,
            name: "Color Temperature",
            numericRange: NumericRangeCapability(id: "color_temperature", name: "Color Temperature", minimum: 2200, maximum: 6500, step: 50, unit: "K", currentValue: 3800, isWritable: true)
        )
    ]

    static let climate: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power"),
        DeviceCapabilityDescriptor(id: "current_temperature", kind: .sensorValue, name: "Current Temperature", isWritable: false),
        DeviceCapabilityDescriptor(
            id: "target_temperature",
            kind: .temperature,
            name: "Target Temperature",
            numericRange: NumericRangeCapability(id: "target_temperature", name: "Target Temperature", minimum: 16, maximum: 30, step: 0.5, unit: "°C", currentValue: 22, isWritable: true)
        ),
        DeviceCapabilityDescriptor(id: "hvac_mode", kind: .hvacMode, name: "HVAC Mode", selection: SelectionCapability(id: "hvac_mode", name: "HVAC Mode", options: ["Cool", "Dry", "Fan", "Off"], selectedOption: "Cool", isWritable: true)),
        DeviceCapabilityDescriptor(id: "fan_mode", kind: .fanMode, name: "Fan Mode", selection: SelectionCapability(id: "fan_mode", name: "Fan Mode", options: ["Auto", "Low", "Medium", "High"], selectedOption: "Auto", isWritable: true)),
        DeviceCapabilityDescriptor(id: "swing_mode", kind: .swingMode, name: "Swing Mode", selection: SelectionCapability(id: "swing_mode", name: "Swing Mode", options: ["Off", "Vertical"], selectedOption: "Off", isWritable: true))
    ]

    static let television: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power"),
        DeviceCapabilityDescriptor(id: "volume", kind: .volume, name: "Volume", numericRange: NumericRangeCapability(id: "volume", name: "Volume", minimum: 0, maximum: 100, step: 1, unit: "%", currentValue: 34, isWritable: true)),
        DeviceCapabilityDescriptor(id: "mute", kind: .mute, name: "Mute"),
        DeviceCapabilityDescriptor(id: "media_playback", kind: .mediaPlayback, name: "Playback"),
        DeviceCapabilityDescriptor(id: "source", kind: .sourceSelection, name: "Source", selection: SelectionCapability(id: "source", name: "Source", options: ["HDMI 1", "HDMI 2", "Netflix"], selectedOption: "HDMI 1", isWritable: true)),
        DeviceCapabilityDescriptor(id: "remote", kind: .directionalRemote, name: "Directional Remote")
    ]

    static let pcPower: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "plug_power", kind: .power, name: "Supply Power"),
        DeviceCapabilityDescriptor(id: "pc_state", kind: .sensorValue, name: "PC State", isWritable: false),
        DeviceCapabilityDescriptor(id: "start_pc", kind: .action, name: "Start PC")
    ]

    static let audioMixer: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "mic", kind: .numericRange, name: "Mic", numericRange: NumericRangeCapability(id: "mic", name: "Mic", minimum: 0, maximum: 1, step: 0.01, unit: nil, currentValue: 0.76, isWritable: true)),
        DeviceCapabilityDescriptor(id: "music", kind: .numericRange, name: "Music", numericRange: NumericRangeCapability(id: "music", name: "Music", minimum: 0, maximum: 1, step: 0.01, unit: nil, currentValue: 0.62, isWritable: true)),
        DeviceCapabilityDescriptor(id: "system", kind: .numericRange, name: "System", numericRange: NumericRangeCapability(id: "system", name: "System", minimum: 0, maximum: 1, step: 0.01, unit: nil, currentValue: 0.55, isWritable: true))
    ]

    static let spotify: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "media_playback", kind: .mediaPlayback, name: "Playback"),
        DeviceCapabilityDescriptor(id: "like", kind: .action, name: "Like Track"),
        DeviceCapabilityDescriptor(id: "add_to_playlist", kind: .action, name: "Add to Playlist")
    ]

    static let discord: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "voice_connection", kind: .mediaPlayback, name: "Voice Connection"),
        DeviceCapabilityDescriptor(id: "mute", kind: .mute, name: "Mute"),
        DeviceCapabilityDescriptor(id: "screen_share", kind: .action, name: "Screen Share")
    ]

    static let companion: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "configured_action", kind: .action, name: "Configured Companion Action")
    ]

    static let remoteInput: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "relative_pointer", kind: .directionalRemote, name: "Relative Pointer"),
        DeviceCapabilityDescriptor(id: "keyboard", kind: .action, name: "Keyboard Input"),
        DeviceCapabilityDescriptor(id: "media_keys", kind: .mediaPlayback, name: "Media Keys")
    ]

    static let screenMirror: [DeviceCapabilityDescriptor] = [
        DeviceCapabilityDescriptor(id: "screen_watch", kind: .action, name: "Watch PC Screen")
    ]
}
