import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case lights
    case climate
    case pc
    case remote
    case streaming
    case scenes
    case settings

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .lights: "lightbulb"
        case .climate: "thermometer.medium"
        case .pc: "desktopcomputer"
        case .remote: "rectangle.and.hand.point.up.left.fill"
        case .streaming: "dot.radiowaves.left.and.right"
        case .scenes: "square.3.layers.3d"
        case .settings: "gearshape"
        }
    }
}
