import Foundation
import UIKit

/// Triggers PC power-on by running a user-defined Apple Shortcut (`shortcuts://run-shortcut`),
/// the same fire-and-forget pattern already used by `performShortcut(_:title:)` for Control Deck
/// actions. Acceptance only means the Shortcuts app agreed to run the shortcut; actual PC
/// availability is confirmed separately by the existing reachability poll in `wakePCAndWait`.
protocol PCPowerShortcutTriggering: Sendable {
    @MainActor func run(shortcutName: String) async throws
}

enum PCPowerShortcutError: LocalizedError {
    case missingShortcutName
    case shortcutsAppUnavailable

    var errorDescription: String? {
        switch self {
        case .missingShortcutName: "Enter the name of a Shortcut in Settings."
        case .shortcutsAppUnavailable: "The Shortcuts app couldn't run the shortcut."
        }
    }
}

@MainActor
struct PCPowerShortcutService: PCPowerShortcutTriggering {
    func run(shortcutName: String) async throws {
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PCPowerShortcutError.missingShortcutName }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]

        guard let url = components.url, await UIApplication.shared.open(url) else {
            throw PCPowerShortcutError.shortcutsAppUnavailable
        }
    }
}
