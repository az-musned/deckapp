import UIKit

/// Lets specific screens (currently just extend-display mode) temporarily restrict interface
/// orientation. `Info.plist` sets the app-wide superset of allowed orientations; this narrows
/// it dynamically while `orientationLock` is non-nil, then falls back to that superset.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask?

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock ?? .all
    }
}
