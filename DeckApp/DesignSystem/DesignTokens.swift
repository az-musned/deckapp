import SwiftUI

enum DesignToken {
    enum Spacing {
        static let xSmall: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 28
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 18
        static let panel: CGFloat = 24
    }

    enum Color {
        static let accent = SwiftUI.Color(red: 0.08, green: 0.58, blue: 1)
        static let cyan = SwiftUI.Color(red: 0.15, green: 0.78, blue: 1)
        static let positive = SwiftUI.Color(red: 0.2, green: 0.88, blue: 0.52)
        static let warning = SwiftUI.Color.orange
        static let destructive = SwiftUI.Color(red: 1, green: 0.27, blue: 0.3)
        static let card = SwiftUI.Color.white.opacity(0.065)
        static let cardBorder = SwiftUI.Color.white.opacity(0.13)
    }

    enum Animation {
        static let responsive = SwiftUI.Animation.spring(duration: 0.28, bounce: 0.14)
    }
}

extension Color {
    static func sceneTint(named name: String) -> Color {
        switch name {
        case "purple": .purple
        case "green": DesignToken.Color.positive
        case "red": DesignToken.Color.destructive
        default: DesignToken.Color.accent
        }
    }

    static func controlDeckTint(named name: String) -> Color {
        switch name {
        case "cyan": DesignToken.Color.cyan
        case "green": DesignToken.Color.positive
        case "purple": .purple
        case "orange": DesignToken.Color.warning
        case "red": DesignToken.Color.destructive
        default: DesignToken.Color.accent
        }
    }
}
