import WidgetKit
import SwiftUI

@main
struct DeckAppLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

// TEMPORARY: WidgetBundle requires at least one Widget to compile. Replaced by the real
// Live Activities (Discord/Spotify/TV/PC) as each one is built.
private struct PlaceholderWidget: Widget {
    let kind = "PlaceholderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderProvider()) { _ in
            Text("DeckApp")
        }
        .configurationDisplayName("DeckApp")
        .description("Placeholder -- replaced once the Live Activities are built.")
    }
}

private struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

private struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}
