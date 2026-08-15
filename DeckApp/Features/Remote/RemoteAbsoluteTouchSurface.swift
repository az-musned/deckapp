import SwiftUI
import UIKit

/// Extend mode's touchscreen surface: reports the raw down/move/up location of a single
/// touch, in contrast to `RemoteTouchpadSurface`'s relative-delta gestures. The caller maps
/// each point to a normalized fraction of the extend display and forwards it as an
/// absolute-touch input event.
struct RemoteAbsoluteTouchSurface: UIViewRepresentable {
    /// Regions (in this view's own coordinate space) that should never start a touch here --
    /// e.g. the close button layered on top of this full-screen surface. This view fills the
    /// whole screen and determines what it handles via plain UIKit hit-testing
    /// (`point(inside:)`), which -- like `RemoteTouchpadSurface`'s gesture recognizers -- claims
    /// touches under sibling SwiftUI controls unless explicitly told not to.
    var excludedRegions: [CGRect] = []
    let touchChanged: (CGPoint, RemoteTouchPhase) -> Void

    func makeUIView(context: Context) -> TouchTrackingView {
        let view = TouchTrackingView()
        view.backgroundColor = .clear
        view.touchChanged = touchChanged
        view.excludedRegions = excludedRegions
        view.accessibilityLabel = "Extended display touchscreen"
        view.accessibilityHint = "Tap or drag to control the extended display directly"
        return view
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.touchChanged = touchChanged
        uiView.excludedRegions = excludedRegions
    }

    final class TouchTrackingView: UIView {
        var touchChanged: ((CGPoint, RemoteTouchPhase) -> Void)?
        var excludedRegions: [CGRect] = []
        /// Only the first finger drives the touch; extra fingers are ignored rather than
        /// tracked, since a touchscreen surface has no use for a second simultaneous point.
        private weak var activeTouch: UITouch?

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            return !excludedRegions.contains { $0.contains(point) }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            activeTouch = touch
            touchChanged?(touch.location(in: self), .began)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            touchChanged?(activeTouch.location(in: self), .moved)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            touchChanged?(activeTouch.location(in: self), .ended)
            self.activeTouch = nil
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            touchChanged?(activeTouch.location(in: self), .cancelled)
            self.activeTouch = nil
        }
    }
}
