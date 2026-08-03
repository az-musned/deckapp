import Foundation

enum ControlDeckItemKind: String, Codable, Sendable {
    case companionButton
    case folder
    case pcStatusWidget
    case microphoneWidget
    case volumeWidget

    var description: String {
        switch self {
        case .companionButton: "Companion Button"
        case .folder: "Folder"
        case .pcStatusWidget: "PC Status Widget"
        case .microphoneWidget: "Microphone Widget"
        case .volumeWidget: "Volume Widget"
        }
    }
}

struct ControlDeckItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var kind: ControlDeckItemKind
    var title: String
    var subtitle: String
    var symbol: String
    var tintName: String
    var mapping: CompanionButtonMapping?
    var systemAction: CompanionDashboardAction?
    var requiresConfirmation: Bool
    var children: [ControlDeckItem]

    init(
        id: UUID = UUID(),
        kind: ControlDeckItemKind,
        title: String,
        subtitle: String = "",
        symbol: String,
        tintName: String = "blue",
        mapping: CompanionButtonMapping? = nil,
        systemAction: CompanionDashboardAction? = nil,
        requiresConfirmation: Bool = false,
        children: [ControlDeckItem] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tintName = tintName
        self.mapping = mapping
        self.systemAction = systemAction
        self.requiresConfirmation = requiresConfirmation
        self.children = children
    }

    static func companionButton(
        title: String = "New Button",
        symbol: String = "rectangle.and.hand.point.up.left.fill",
        tintName: String = "blue",
        mapping: CompanionButtonMapping = CompanionButtonMapping()
    ) -> ControlDeckItem {
        ControlDeckItem(
            kind: .companionButton,
            title: title,
            subtitle: mapping.locationDescription,
            symbol: symbol,
            tintName: tintName,
            mapping: mapping
        )
    }

    static func folder(title: String = "New Folder") -> ControlDeckItem {
        ControlDeckItem(
            kind: .folder,
            title: title,
            subtitle: "0 buttons",
            symbol: "folder.fill",
            tintName: "purple"
        )
    }

    static func widget(_ kind: ControlDeckItemKind) -> ControlDeckItem {
        switch kind {
        case .pcStatusWidget:
            ControlDeckItem(kind: kind, title: "PC Status", subtitle: "Online state", symbol: "desktopcomputer", tintName: "green")
        case .microphoneWidget:
            ControlDeckItem(kind: kind, title: "Microphone", subtitle: "Audio input", symbol: "mic.fill", tintName: "red")
        case .volumeWidget:
            ControlDeckItem(kind: kind, title: "PC Volume", subtitle: "Audio output", symbol: "speaker.wave.2.fill", tintName: "blue")
        default:
            ControlDeckItem.companionButton()
        }
    }

    static func initialItems(
        launchMapping: CompanionButtonMapping?,
        sleepMapping: CompanionButtonMapping?
    ) -> [ControlDeckItem] {
        var launch = companionButton(
            title: "Launch Game",
            symbol: "gamecontroller.fill",
            tintName: "green",
            mapping: launchMapping ?? CompanionButtonMapping()
        )
        launch.mapping = launchMapping
        launch.systemAction = .launchGame
        launch.subtitle = launchMapping == nil ? "Not mapped" : "Start your game"

        var sleep = companionButton(
            title: "Sleep PC",
            symbol: "powersleep",
            tintName: "orange",
            mapping: sleepMapping ?? CompanionButtonMapping()
        )
        sleep.mapping = sleepMapping
        sleep.systemAction = .sleepPC
        sleep.subtitle = sleepMapping == nil ? "Not mapped" : "Put PC to sleep"
        sleep.requiresConfirmation = true

        return [
            widget(.microphoneWidget),
            widget(.volumeWidget),
            launch,
            sleep
        ]
    }
}

enum ControlDeckTint: String, CaseIterable, Identifiable, Codable, Sendable {
    case blue
    case cyan
    case green
    case purple
    case orange
    case red

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}
