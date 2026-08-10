import SwiftUI
import SwiftData

@main
struct DeckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: DashboardLayoutRecord.self)
        } catch {
            fatalError("Unable to create the dashboard layout store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .modelContainer(modelContainer)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
