import SwiftUI
import UIKit

struct NativeKeyboardCaptureView: UIViewRepresentable {
    let sendText: (String) -> Void
    let sendKey: (RemoteVirtualKey) -> Void

    func makeUIView(context: Context) -> KeyboardCaptureTextView {
        let view = KeyboardCaptureTextView()
        view.onText = sendText
        view.onKey = sendKey
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = UIColor(DesignToken.Color.accent)
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .yes
        view.keyboardDismissMode = .interactive
        view.returnKeyType = .default
        view.accessibilityLabel = "PC keyboard text entry"
        view.accessibilityHint = "Opens the native keyboard. Typed content is sent without being stored."
        return view
    }

    func updateUIView(_ uiView: KeyboardCaptureTextView, context: Context) {
        uiView.onText = sendText
        uiView.onKey = sendKey
    }
}

final class KeyboardCaptureTextView: UITextView {
    var onText: ((String) -> Void)?
    var onKey: ((RemoteVirtualKey) -> Void)?

    override func insertText(_ text: String) {
        if text == "\n" {
            onKey?(.enter)
        } else if text == "\t" {
            onKey?(.tab)
        } else {
            onText?(text)
        }
        self.text = ""
    }

    override func deleteBackward() {
        onKey?(.backspace)
        text = ""
    }
}
