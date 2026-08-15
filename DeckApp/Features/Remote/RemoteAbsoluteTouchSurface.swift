import SwiftUI
import UIKit

/// Extend mode's touchscreen surface: reports the raw down/move/up location of a single
/// touch, in contrast to `RemoteTouchpadSurface`'s relative-delta gestures. The caller maps
/// each point to a normalized fraction of the extend display and forwards it as an
/// absolute-touch input event.
struct RemoteAbsoluteTouchSurface: UIViewRepresentable {
    let touchChanged: (CGPoint, RemoteTouchPhase) -> Void

    func makeUIView(context: Context) -> TouchTrackingView {
        let view = TouchTrackingView()
        view.backgroundColor = .clear
        view.touchChanged = touchChanged
        view.accessibilityLabel = "Extended display touchscreen"
        view.accessibilityHint = "Tap or drag to control the extended display directly"
        return view
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.touchChanged = touchChanged
    }

    final class TouchTrackingView: UIView {
        var touchChanged: ((CGPoint, RemoteTouchPhase) -> Void)?
        /// Only the first finger drives the touch; extra fingers are ignored rather than
        /// tracked, since a touchscreen surface has no use for a second simultaneous point.
        private weak var activeTouch: UITouch?

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
