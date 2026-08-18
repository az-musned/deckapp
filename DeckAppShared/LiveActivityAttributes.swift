import ActivityKit
import Foundation

/// Shared between the main app target (which starts/updates/ends these via `Activity<T>`)
/// and the DeckAppLiveActivities extension (which renders them). Added to both targets'
/// Sources build phase explicitly -- this file lives outside the main app's synchronized
/// source root specifically so it can be shared without pulling the extension into that
/// root's per-target file membership rules.
///
/// Each activity only exists while its thing is actually happening (see the plan: Discord
/// while in a call, Spotify while playing, TV while playing, PC while playing) -- there is no
/// "idle" ContentState. AppState/DiscordStore/SpotifyStore/LGTVStore start the activity when
/// that condition becomes true and end it when it becomes false.

nonisolated struct DiscordCallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var channelName: String
        var participantCount: Int
        var isMuted: Bool
    }
}

nonisolated struct SpotifyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var trackName: String
        var artistName: String
        var isPlaying: Bool
    }
}

nonisolated struct TVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var volumePercent: Int
        var isMuted: Bool
    }
}

nonisolated struct PCActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var isPlaying: Bool
    }
}
