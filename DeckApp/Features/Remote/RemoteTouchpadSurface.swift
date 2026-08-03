import SwiftUI
import UIKit

struct RemoteTouchpadSurface: UIViewRepresentable {
    let pointerMoved: (Double, Double) -> Void
    let scrolled: (Double, Double) -> Void
    let tapped: () -> Void
    let twoFingerTapped: () -> Void
    let dragChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pointerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pointerPan(_:)))
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1

        let scrollPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.scrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTouchesRequired = 1

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.twoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        // Dragging should require a deliberate stationary hold. A short hold
        // with unlimited movement turns ordinary pointer motion into text
        // selection and accidental drags.
        longPress.minimumPressDuration = 0.7
        longPress.allowableMovement = 14

        tap.require(toFail: pointerPan)
        twoFingerTap.require(toFail: scrollPan)
        pointerPan.delegate = context.coordinator
        longPress.delegate = context.coordinator

        [pointerPan, scrollPan, tap, twoFingerTap, longPress].forEach(view.addGestureRecognizer)
        view.accessibilityLabel = "Windows PC touchpad"
        view.accessibilityHint = "Drag to move the pointer, tap to click, or use two fingers to scroll"
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RemoteTouchpadSurface
        private var previousPointerTranslation = CGPoint.zero
        private var previousScrollTranslation = CGPoint.zero

        init(parent: RemoteTouchpadSurface) {
            self.parent = parent
        }

        @objc func pointerPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            if recognizer.state == .began { previousPointerTranslation = .zero }
            let delta = CGPoint(
                x: translation.x - previousPointerTranslation.x,
                y: translation.y - previousPointerTranslation.y
            )
            previousPointerTranslation = translation
            if delta != .zero { parent.pointerMoved(delta.x, delta.y) }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                previousPointerTranslation = .zero
            }
        }

        @objc func scrollPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            if recognizer.state == .began { previousScrollTranslation = .zero }
            let delta = CGPoint(
                x: translation.x - previousScrollTranslation.x,
                y: translation.y - previousScrollTranslation.y
            )
            previousScrollTranslation = translation
            if delta != .zero { parent.scrolled(delta.x, delta.y) }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                previousScrollTranslation = .zero
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.tapped()
        }

        @objc func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.twoFingerTapped()
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                parent.dragChanged(true)
            case .ended, .cancelled, .failed:
                parent.dragChanged(false)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
