import Foundation

enum SleepTimerTarget: String, CaseIterable, Identifiable, Sendable {
    case pc
    case tv
    case lights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pc: "PC"
        case .tv: "TV"
        case .lights: "Lights"
        }
    }

    var symbol: String {
        switch self {
        case .pc: "desktopcomputer"
        case .tv: "tv"
        case .lights: "lightbulb.fill"
        }
    }
}

enum SleepTimerDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case ninety = 90

    var id: Int { rawValue }
    var seconds: Int { rawValue * 60 }
    var title: String { "\(rawValue) min" }
}
