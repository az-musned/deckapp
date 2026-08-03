import Foundation
import Network

@MainActor
final class NetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "DeckApp.NetworkPath")
    private var started = false

    func start(changed: @escaping @MainActor (Bool) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in changed(satisfied) }
        }
        monitor.start(queue: queue)
    }
}
