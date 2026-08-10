import Foundation

/// A user-picked keyboard shortcut the Windows Agent replays as a one-shot press+release, e.g. to trigger a
/// Vencord plugin's screen-share toggle. `keyCode` is a Windows virtual-key code restricted to
/// `HotkeyKeyAllowList` on the agent (letters, digits, F1-F24, space, common punctuation).
struct HotkeyCombo: Codable, Sendable, Equatable {
    var keyCode: Int
    var modifiers: RemoteModifiers

    static let availableKeys: [(keyCode: Int, label: String)] = {
        var keys: [(Int, String)] = []
        for letter in 0x41...0x5A { keys.append((letter, String(UnicodeScalar(letter)!))) }
        for digit in 0...9 { keys.append((0x30 + digit, "\(digit)")) }
        for function in 1...24 { keys.append((0x70 + function - 1, "F\(function)")) }
        keys.append((0x20, "Space"))
        return keys
    }()

    var keyLabel: String {
        Self.availableKeys.first(where: { $0.keyCode == keyCode })?.label ?? "?"
    }

    var displayString: String {
        let modifierLabels = RemoteModifiers.allCases
            .filter { modifiers.contains($0.modifier) }
            .map(\.title)
        return (modifierLabels + [keyLabel]).joined(separator: " + ")
    }
}
