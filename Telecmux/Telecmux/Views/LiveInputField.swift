import SwiftUI
import UIKit

/// A text field that forwards every committed edit to the remote surface as
/// it happens — typing feels like a real terminal instead of type-then-send.
///
/// Why UIKit instead of SwiftUI's TextField: we must know when an IME
/// (Chinese pinyin, Japanese kana, dictation underbar…) is still composing.
/// During composition UIKit exposes `markedTextRange`; only when it becomes
/// nil has the user committed text. SwiftUI offers no access to that, and
/// forwarding raw pinyin keystrokes into the terminal would be garbage.
///
/// Delta protocol: after each committed change we diff the field against the
/// last forwarded snapshot and emit `(deleteCount, insertedText)` — the
/// number of backspaces to send, then the characters to type.
struct LiveInputField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Called with (backspaces, insertion) for every committed delta.
    var onDelta: (Int, String) -> Void
    /// Called when the user taps the keyboard's return key.
    var onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.font = .preferredFont(forTextStyle: .body)
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.spellCheckingType = .no
        tf.returnKeyType = .send
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        // Push external resets (e.g. cleared after enter) into the field,
        // but never fight the user mid-composition.
        if tf.markedTextRange == nil, tf.text != text {
            tf.text = text
            context.coordinator.lastForwarded = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LiveInputField
        /// Snapshot of what has already been forwarded to the remote.
        var lastForwarded: String = ""

        init(_ parent: LiveInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ tf: UITextField) {
            // IME still composing (pinyin underbar etc.) — wait for commit.
            guard tf.markedTextRange == nil else { return }
            let current = tf.text ?? ""
            guard current != lastForwarded else { return }

            let old = Array(lastForwarded)
            let new = Array(current)
            var common = 0
            while common < old.count, common < new.count, old[common] == new[common] {
                common += 1
            }
            let deletes = old.count - common
            let inserts = String(new[common...])

            lastForwarded = current
            parent.text = current
            parent.onDelta(deletes, inserts)
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            // Commit any residual composition first, then signal return.
            editingChanged(tf)
            parent.onReturn()
            return false  // keep keyboard up — terminal flow continues
        }
    }
}
